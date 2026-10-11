-- | CURVE for the TCP transport: pyzmq's certificate files, the client and
-- server security checks, and a ZAP handler equivalent to pyzmq's
-- @ThreadAuthenticator@ configured with @configure_curve@.
module Petrus.Motus.Transport.ZeroMQ.Curve
  ( -- * Certificate files
    loadCertificate
  , createCertificates
    -- * Security checks
  , ClientKeys (..)
  , clientSecurity
  , ServerKeys (..)
  , serverSecurity
    -- * ZAP
  , Authenticator
  , startAuthenticator
  , stopAuthenticator
  , zapReply
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (forM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (isSuffixOf, sort)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Petrus.Motus.Transport.ZeroMQ.Errors
import Petrus.Motus.Transport.ZeroMQ.Native qualified as Z
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Certificate files

-- | @zmq.auth.load_certificate(path)@: the Z85 public key and, when
-- present, the Z85 secret key.
loadCertificate :: FilePath -> IO (ByteString, Maybe ByteString)
loadCertificate path = do
  exists <- (||) <$> doesFileExist path <*> doesDirectoryExist path
  unless exists $ throwIO (OSError ("Invalid certificate file: " <> T.pack path))
  contents <- BS.readFile path
  let scan public secret = \case
        [] -> (public, secret)
        line : rest
          | Just _ <- public, Just _ <- secret -> (public, secret)
          | otherwise ->
              let stripped = BC.strip line
                  quote c = c `elem` (" \t'\"" :: String)
                  valueOf = BC.dropWhileEnd quote . BC.dropWhile quote . BS.drop 1 . BC.dropWhile (/= '=')
               in if "#" `BS.isPrefixOf` stripped
                    then scan public secret rest
                    else
                      let public' = if "public-key" `BS.isPrefixOf` stripped then Just (valueOf stripped) else public
                          secret' = if "secret-key" `BS.isPrefixOf` stripped then Just (valueOf stripped) else secret
                       in scan public' secret' rest
      (publicKey, secretKey) = scan Nothing Nothing (splitLines contents)
  case publicKey of
    Nothing -> throwIO (ValueError ("No public key found in " <> T.pack path))
    Just public -> pure (public, secretKey)
  where
    -- Python's binary line iteration: lines end after each newline.
    splitLines bytes
      | BS.null bytes = []
      | otherwise = let (line, rest) = BC.break (== '\n') bytes in line : splitLines (BS.drop 1 rest)

-- | @zmq.auth.create_certificates(directory, name)@: write @name.key@
-- (public) and @name.key_secret@ in pyzmq's format; answers both paths.
createCertificates :: FilePath -> Text -> IO (FilePath, FilePath)
createCertificates directory label = do
  (public, secret) <- Z.curveKeypair
  now <- getZonedTime
  let stamp = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" now <> microseconds (formatTime defaultTimeLocale "%q" now)
      microseconds picos = let micros = take 6 picos in if all (== '0') micros then "" else '.' : micros
      publicPath = directory </> (T.unpack label <> ".key")
      secretPath = directory </> (T.unpack label <> ".key_secret")
      publicBanner =
        "#   ****  Generated on " <> stamp <> " by pyzmq  ****\n\
        \#   ZeroMQ CURVE Public Certificate\n\
        \#   Exchange securely, or use a secure mechanism to verify the contents\n\
        \#   of this file after exchange. Store public certificates in your home\n\
        \#   directory, in the .curve subdirectory.\n\n"
      secretBanner =
        "#   ****  Generated on " <> stamp <> " by pyzmq  ****\n\
        \#   ZeroMQ CURVE **Secret** Certificate\n\
        \#   DO NOT PROVIDE THIS FILE TO OTHER USERS nor change its permissions.\n\n"
      body includeSecret =
        "metadata\ncurve\n    public-key = \""
          <> BC.unpack public
          <> "\"\n"
          <> (if includeSecret then "    secret-key = \"" <> BC.unpack secret <> "\"\n" else "")
  BS.writeFile publicPath (TE.encodeUtf8 (T.pack (publicBanner <> body False)))
  BS.writeFile secretPath (TE.encodeUtf8 (T.pack (secretBanner <> body True)))
  pure (publicPath, secretPath)

-- ---------------------------------------------------------------------------
-- Security checks

-- | A TCP client's Z85 keys: its own pair and the pinned server key.
data ClientKeys = ClientKeys
  { clientPublic :: ByteString
  , clientSecret :: ByteString
  , serverPublic :: ByteString
  }
  deriving stock (Eq, Show)

-- | A TCP server's Z85 key pair.
data ServerKeys = ServerKeys
  { serverPublicKey :: ByteString
  , serverSecretKey :: ByteString
  }
  deriving stock (Eq, Show)

isTcp, isIpc :: Text -> Bool
isTcp = T.isPrefixOf "tcp://"
isIpc = T.isPrefixOf "ipc://"

present :: Maybe FilePath -> Maybe FilePath
present = \case
  Just "" -> Nothing
  other -> other

-- | @_client_security(endpoint, client, server)@: TCP requires a client
-- secret certificate and a public-only server certificate; IPC refuses
-- both.
clientSecurity :: Text -> Maybe FilePath -> Maybe FilePath -> IO (Maybe ClientKeys)
clientSecurity endpoint client' server' = do
  let client = present client'
      server = present server'
  when (isTcp endpoint && (null client || null server)) $
    throwIO (ValueError "ZeroMQ TCP Worker requires client secret and server public certificates")
  when (isIpc endpoint && (not (null client) || not (null server))) $
    throwIO (ValueError "ZeroMQ IPC Worker rejects TCP CURVE certificates")
  case (isTcp endpoint, client, server) of
    (True, Just clientPath, Just serverPath) -> do
      (public, secret) <- loadCertificate clientPath
      (pinned, pinnedSecret) <- loadCertificate serverPath
      secretKey <- case secret of
        Just s | not (BS.null public) -> pure s
        _ -> throwIO (ValueError "ZeroMQ client certificate must contain a public and secret key")
      when (BS.null pinned || pinnedSecret /= Nothing) $
        throwIO (ValueError "ZeroMQ trusted server certificate must be public-only")
      pure (Just (ClientKeys public secretKey pinned))
    _ -> pure Nothing

-- | @_server_security(endpoint, server, clients)@.
serverSecurity :: Text -> Maybe FilePath -> Maybe FilePath -> IO (Maybe ServerKeys)
serverSecurity endpoint server' clients' = do
  let server = present server'
      clients = present clients'
  if isTcp endpoint
    then case (server, clients) of
      (Just serverPath, Just clientsPath) -> do
        isDirectory <- doesDirectoryExist clientsPath
        candidates <- if isDirectory then keyFiles True clientsPath else pure []
        when (null candidates) $
          throwIO (ValueError "ZeroMQ TCP server allowed-client directory must contain at least one public .key")
        (public, secret) <- loadCertificate serverPath
        secretKey <- case secret of
          Just s | not (BS.null public) -> pure s
          _ -> throwIO (ValueError "ZeroMQ server certificate must contain a public and secret key")
        mapM_
          ( \certificate -> do
              (clientPublic', clientSecret') <- loadCertificate certificate
              when (BS.null clientPublic' || clientSecret' /= Nothing) $
                throwIO (ValueError ("allowed-client certificate must be public-only: " <> T.pack certificate))
          )
          candidates
        pure (Just (ServerKeys public secretKey))
      _ -> throwIO (ValueError "ZeroMQ TCP server requires a server secret certificate and allowed-client key directory")
    else do
      unless (null server && null clients) $ throwIO (ValueError "ZeroMQ IPC server rejects TCP CURVE configuration")
      pure Nothing

-- | The @*.key@ entries of a directory: @pathlib.Path.glob@ (hidden files
-- included) or @glob.glob@ (hidden files excluded).
keyFiles :: Bool -> FilePath -> IO [FilePath]
keyFiles includeHidden directory = do
  entries <- sort <$> listDirectory directory
  pure [directory </> entry | entry <- entries, ".key" `isSuffixOf` entry, includeHidden || take 1 entry /= "."]

-- ---------------------------------------------------------------------------
-- ZAP

-- | A running ZAP handler.
data Authenticator = Authenticator
  { stopping :: IORef Bool
  , finished :: MVar ()
  }

-- | Start a ZAP handler on @inproc://zeromq.zap.01@ in the context, as
-- pyzmq's @ThreadAuthenticator(context).start()@ followed by
-- @configure_curve(domain=domain, location=directory)@: the allowed keys
-- are the public keys of the directory's @*.key@ files, read once now (a
-- directory that cannot be read leaves the domain unknown, as pyzmq logs
-- and continues).
startAuthenticator :: Z.Context -> Text -> FilePath -> IO Authenticator
startAuthenticator context domain directory = do
  socket <- Z.newSocket context Z.Rep
  Z.setIntOption socket Z.Linger 1
  Z.bind socket "inproc://zeromq.zap.01" `onError` Z.closeSocket socket
  loaded <- try @SomeException $ do
    files <- keyFiles False directory
    keys <- forM files $ \file -> do
      (public, _) <- loadCertificate file
      pure (if BS.null public then Nothing else Just public)
    pure (Set.fromList (catMaybes keys))
  let domains = either (const []) (\keys -> [(domain, keys)]) loaded
  stopping <- newIORef False
  finished <- newEmptyMVar
  let loop = do
        stop <- readIORef stopping
        unless stop $ do
          Z.receiveFrames socket (Just 100000) >>= \case
            Nothing -> pure ()
            Just frames -> case zapReply domains frames of
              Nothing -> pure ()
              Just reply -> () <$ Z.sendFrames socket reply (Just 1000)
          loop
  _ <- forkIO (loop `finally` (Z.closeSocket socket >> putMVar finished ()))
  pure (Authenticator stopping finished)
  where
    onError action cleanup = do
      result <- try @SomeException action
      either (\e -> cleanup >> throwIO e) pure result

-- | Stop the handler and wait until its socket is closed.
stopAuthenticator :: Authenticator -> IO ()
stopAuthenticator a = do
  writeIORef a.stopping True
  readMVar a.finished

-- | pyzmq's @Authenticator.handle_zap_message@ for a CURVE-only
-- configuration: the reply frames, or 'Nothing' when there is too little
-- to reply to.
zapReply :: [(Text, Set ByteString)] -> [ByteString] -> Maybe [ByteString]
zapReply domains = \case
  frames | length frames < 2 -> Nothing
  (_ : requestId : rest) | length rest < 4 -> reply requestId "400" "Not enough frames" ""
  (version : requestId : domain : _address : _identity : mechanism : credentials)
    | version /= "1.0" -> reply requestId "400" "Invalid version" ""
    | mechanism == "NULL" -> reply requestId "200" "OK" "anonymous"
    | mechanism == "PLAIN" ->
        if length credentials /= 2
          then reply requestId "400" "Invalid credentials" ""
          else reply requestId "400" "No passwords defined" ""
    | mechanism == "CURVE" -> case credentials of
        [key] ->
          let named = TE.decodeUtf8Lenient domain
              lookupDomain = if T.null named then "*" else named
           in case lookup lookupDomain domains of
                Nothing -> reply requestId "400" "Unknown domain" ""
                Just keys ->
                  let z85 = fromMaybe "" (Z.z85Encode key)
                   in if Set.member z85 keys
                        then reply requestId "200" "OK" z85
                        else reply requestId "400" "Unknown key" ""
        _ -> reply requestId "400" "Invalid credentials" ""
    | otherwise -> reply requestId "400" "NO ACCESS" ""
  _ -> Nothing
  where
    reply requestId code text user = Just ["1.0", requestId, code, text, user, ""]
