{-# LANGUAGE MultiWayIf #-}

-- | The HTTP front of the viewer server: one event loop that accepts every
-- connection and answers the requests it claims (the open-file and
-- resolve-ref endpoints) itself, the way Node's @http@ server does, and
-- hands every other connection to Warp.
--
-- = Why
--
-- The endpoints do a few microseconds of work, so the fixed cost of an
-- HTTP request decides how they compare with Node. Under Warp a request
-- costs a thread wake-up and a one-shot readiness registration with GHC's
-- I/O manager for every wait; libuv keeps every socket registered and
-- serves whatever is ready from one loop. This loop does what libuv does:
--
-- * the listening sockets and the connections stay registered with one
--   kqueue or epoll set (@cbits/relay_io.c@, @cbits/http_front.c@) for as
--   long as the loop serves them;
-- * a turn waits once for everything that is ready (without blocking when
--   something already is), reads each ready socket once, answers every
--   complete request in its buffer, and writes each answer with one
--   @writev@ (headers and body);
-- * there are no thread hand-offs: the handlers run on the loop's thread,
--   as Node's run on its event loop.
--
-- = What the loop answers
--
-- A request is the loop's when it is HTTP/1.0 or 1.1 with a plain
-- @Content-Length@ body (or none), its method is a common one, its target
-- is claimed by the server, and it is not an upgrade. The answer has
-- Node's bytes: the status line, the handler's headers in order, then
-- @Date@, @Connection@ (and @Keep-Alive: timeout=5@), and
-- @Content-Length@, as @ServerResponse@ writes them; idle connections close
-- after Node's five-second keep-alive timeout. @Expect: 100-continue@ gets
-- Node's interim @100 Continue@.
--
-- Anything else (another target, a chunked body, a malformed request, a
-- handler that has to wait on the network) moves the whole connection to
-- Warp, with the bytes already read, before anything is written for that
-- request. Warp then serves it to the end.
module Petrus.Viewer.HttpFront
  ( Request (..)
  , Answer (..)
  , FrontConfig (..)
  , HandOff
  , withFront
    -- * Parsing and rendering (exposed for tests)
  , Head (..)
  , Parse (..)
  , parseHead
  , renderHead
  ) where

import Control.Concurrent (forkOn)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IM
import Data.Word (Word8)
import Foreign.C.Types (CChar, CInt (..), CLong (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrArray, mallocForeignPtrBytes, touchForeignPtr, withForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (pokeElemOff)
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Types qualified as H
import Network.Socket qualified as S
import Petrus.Viewer.Endpoints (Reply (..))
import Petrus.Viewer.Json (decodeLenient)

-- C side -----------------------------------------------------------------------

foreign import ccall unsafe "prelay_poll_create" c_pollCreate :: IO CInt
foreign import ccall unsafe "prelay_poll_add" c_pollAdd :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_poll_remove" c_pollRemove :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_poll_wait" c_pollNow :: CInt -> Ptr CInt -> Ptr CInt -> CInt -> CInt -> IO CInt
-- the blocking wait releases the capability while it waits
foreign import ccall safe "prelay_poll_wait" c_pollBlock :: CInt -> Ptr CInt -> Ptr CInt -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "prelay_recv" c_recv :: CInt -> Ptr Word8 -> CLong -> IO CLong
foreign import ccall unsafe "prelay_sendv" c_sendv :: CInt -> Ptr (Ptr Word8) -> Ptr CLong -> CInt -> IO CLong
foreign import ccall unsafe "prelay_pipe" c_pipe :: Ptr CInt -> IO CInt
foreign import ccall unsafe "prelay_wake" c_wake :: CInt -> IO ()
foreign import ccall unsafe "prelay_drain" c_drain :: CInt -> IO ()
foreign import ccall unsafe "prelay_close" c_close :: CInt -> IO CInt
foreign import ccall unsafe "pfront_accept" c_accept :: CInt -> IO CInt
foreign import ccall unsafe "pfront_set_nonblocking" c_setNonBlocking :: CInt -> IO CInt
foreign import ccall unsafe "pfront_watch" c_watch :: CInt -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "pfront_http_date" c_httpDate :: Ptr CChar -> IO ()

-- Interface --------------------------------------------------------------------

-- | A request the loop answers: method, target (as sent), and the body
-- (UTF-8 decoded leniently, as @chunk.toString()@ would).
data Request = Request
  { requestMethod :: ByteString
  , requestTarget :: ByteString
  , requestBody :: ByteString
  }

data Answer
  = -- | write this response
    Respond Reply
  | -- | let Warp serve the request (and the rest of the connection)
    PassToWarp

-- | Give a connection to Warp: its socket, its peer, and the bytes already
-- read from it (to be served before anything else on the socket).
type HandOff = S.Socket -> S.SockAddr -> ByteString -> IO ()

data FrontConfig = FrontConfig
  { frontClaims :: ByteString -> ByteString -> Bool
  -- ^ method and target of the requests the loop answers
  , frontHandle :: Request -> IO Answer
  , frontHandOff :: HandOff
  }

-- State ------------------------------------------------------------------------

data Conn = Conn
  { connFd :: CInt
  , connIn :: IORef ByteString
  -- ^ received bytes not yet answered
  , connOut :: IORef [ByteString]
  -- ^ a response the socket did not take yet (reading waits for it)
  , connCloseAfter :: IORef Bool
  -- ^ close once the output is written (@Connection: close@)
  , connContinued :: IORef Bool
  -- ^ @100 Continue@ already sent for the request in progress
  , connDeadline :: IORef Double
  }

data Front = Front
  { config :: FrontConfig
  , pollFd :: CInt
  , wakeRead :: CInt
  , wakeWrite :: CInt
  , listenFds :: [CInt]
  , conns :: IORef (IntMap Conn)
  , paused :: IORef [(CInt, Double)]
  -- ^ listeners taken out of the set after an accept error, and when to
  -- put them back
  , nextSweep :: IORef Double
  , stopRequested :: IORef Bool
  , stopped :: TVar Bool
  , scratch :: ForeignPtr Word8
  , readyFds :: ForeignPtr CInt
  , readyFlags :: ForeignPtr CInt
  }

scratchSize, maxReady, maxHead, maxBody :: Int
scratchSize = 64 * 1024
maxReady = 256
-- Node's default maxHeaderSize
maxHead = 16 * 1024
-- larger bodies go to Warp rather than being buffered in the loop
maxBody = 1024 * 1024

-- | Node's @server.keepAliveTimeout@, and a bound for a request to arrive.
keepAliveTimeout, requestTimeout :: Double
keepAliveTimeout = 5
requestTimeout = 60

-- the readiness flags of prelay_poll_wait
writable :: CInt
writable = 2

-- | Serve the listening sockets for the duration of the action. On exit
-- the loop closes every connection it still holds (not the listeners).
withFront :: [S.Socket] -> FrontConfig -> IO a -> IO a
withFront listeners cfg action = bracket (startFront listeners cfg) stopFront (const action)

startFront :: [S.Socket] -> FrontConfig -> IO Front
startFront listeners cfg = do
  pfd <- c_pollCreate
  when (pfd < 0) (ioError (userError "http front: cannot create the readiness poller"))
  (wr, ww) <- allocaArray 2 $ \p -> do
    r <- c_pipe p
    when (r < 0) (ioError (userError "http front: cannot create the wake-up pipe"))
    [a, b] <- peekArray 2 p
    pure (a, b)
  _ <- c_pollAdd pfd wr
  lfds <- mapM S.unsafeFdSocket listeners
  forM_ lfds $ \fd -> do
    _ <- c_setNonBlocking fd
    r <- c_pollAdd pfd fd
    when (r < 0) (ioError (userError "http front: cannot watch a listening socket"))
  front <-
    Front cfg pfd wr ww lfds
      <$> newIORef IM.empty
      <*> newIORef []
      <*> newIORef 0
      <*> newIORef False
      <*> newTVarIO False
      <*> mallocForeignPtrBytes scratchSize
      <*> mallocForeignPtrArray maxReady
      <*> mallocForeignPtrArray maxReady
  _ <- forkOn 0 (runLoop front `finally` shutdown front)
  pure front

stopFront :: Front -> IO ()
stopFront front = do
  writeIORef (stopRequested front) True
  c_wake (wakeWrite front)
  atomically (readTVar (stopped front) >>= check)

shutdown :: Front -> IO ()
shutdown front = do
  cs <- readIORef (conns front)
  forM_ cs $ \c -> c_close (connFd c)
  writeIORef (conns front) IM.empty
  forM_ (listenFds front) $ \fd -> c_pollRemove (pollFd front) fd
  _ <- c_close (pollFd front)
  _ <- c_close (wakeRead front)
  _ <- c_close (wakeWrite front)
  atomically (writeTVar (stopped front) True)

-- The loop ---------------------------------------------------------------------

runLoop :: Front -> IO ()
runLoop front = go
  where
    pfd = pollFd front
    go = do
      idle <- IM.null <$> readIORef (conns front)
      waiting <- null <$> readIORef (paused front)
      let timeoutMs
            | not waiting = 100
            | idle = -1
            | otherwise = 1000
      ready <- withForeignPtr (readyFds front) $ \fds -> withForeignPtr (readyFlags front) $ \fls -> do
        -- block (releasing the capability) only when nothing is ready
        n0 <- c_pollNow pfd fds fls (fromIntegral maxReady) 0
        n <- if n0 == 0 then c_pollBlock pfd fds fls (fromIntegral maxReady) timeoutMs else pure n0
        if n <= 0 then pure [] else zip <$> peekArray (fromIntegral n) fds <*> peekArray (fromIntegral n) fls
      mapM_ dispatch ready
      sweep front
      stop <- readIORef (stopRequested front)
      unless stop go
    dispatch (fd, fl)
      | fd == wakeRead front = c_drain fd
      | fd `elem` listenFds front = acceptAll front fd
      | otherwise = do
          m <- IM.lookup (fromIntegral fd) <$> readIORef (conns front)
          forM_ m $ \c -> do
            r <- try @SomeException $
              if
                | fl == writable -> flushConn front c
                | otherwise -> do
                    out <- readIORef (connOut c)
                    if null out then readConn front c else flushConn front c
            either (const (closeConn front c)) pure r

acceptAll :: Front -> CInt -> IO ()
acceptAll front lfd = go (0 :: Int)
  where
    go n
      | n >= 64 = pure ()
      | otherwise = do
          fd <- c_accept lfd
          if
            | fd >= 0 -> addConn front fd >> go (n + 1)
            | fd == -2 -> pure ()
            | otherwise -> do
                -- out of descriptors or the like: stop watching the listener
                -- for a moment instead of spinning on it
                _ <- c_pollRemove (pollFd front) lfd
                now <- getMonotonicTime
                modifyIORef' (paused front) ((lfd, now + 0.1) :)

addConn :: Front -> CInt -> IO ()
addConn front fd = do
  r <- c_pollAdd (pollFd front) fd
  if r < 0
    then () <$ c_close fd
    else do
      now <- getMonotonicTime
      c <- Conn fd <$> newIORef B.empty <*> newIORef [] <*> newIORef False <*> newIORef False <*> newIORef (now + requestTimeout)
      modifyIORef' (conns front) (IM.insert (fromIntegral fd) c)

forget :: Front -> Conn -> IO ()
forget front c = modifyIORef' (conns front) (IM.delete (fromIntegral (connFd c)))

closeConn :: Front -> Conn -> IO ()
closeConn front c = do
  present <- IM.member (fromIntegral (connFd c)) <$> readIORef (conns front)
  when present $ do
    forget front c
    () <$ c_close (connFd c)

-- | Close idle connections past their deadline; put paused listeners back.
sweep :: Front -> IO ()
sweep front = do
  now <- getMonotonicTime
  next <- readIORef (nextSweep front)
  when (now >= next) $ do
    writeIORef (nextSweep front) (now + 0.25)
    cs <- readIORef (conns front)
    forM_ cs $ \c -> do
      d <- readIORef (connDeadline c)
      when (now >= d) (closeConn front c)
    ps <- readIORef (paused front)
    let (due, later) = span' (\(_, t) -> now >= t) ps
    writeIORef (paused front) later
    forM_ due $ \(fd, _) -> c_pollAdd (pollFd front) fd
  where
    span' p xs = (filter p xs, filter (not . p) xs)

-- | Give the connection to Warp, with what it has sent so far.
handOff :: Front -> Conn -> ByteString -> IO ()
handOff front c buf = do
  forget front c
  _ <- c_pollRemove (pollFd front) (connFd c)
  r <- try @SomeException $ do
    sock <- S.mkSocket (connFd c)
    peer <- S.getPeerName sock `onErr` S.close sock
    frontHandOff (config front) sock peer buf
  either (const (pure ())) pure r
  where
    onErr act cleanup = try @SomeException act >>= either (\e -> cleanup >> ioError (userError (show e))) pure

-- Input ------------------------------------------------------------------------

readConn :: Front -> Conn -> IO ()
readConn front c = do
  r <- withForeignPtr (scratch front) $ \p -> c_recv (connFd c) p (fromIntegral scratchSize)
  if
    | r == -2 -> pure ()
    | r <= 0 -> closeConn front c
    | otherwise -> do
        let n = fromIntegral r
        fresh <- withForeignPtr (scratch front) $ \p -> BI.create n (\d -> copyBytes d p n)
        pend <- readIORef (connIn c)
        when (B.null pend) $ do
          now <- getMonotonicTime
          writeIORef (connDeadline c) (now + requestTimeout)
        serveBuffer front c (if B.null pend then fresh else pend <> fresh)

-- | Answer the complete requests at the start of the buffer.
serveBuffer :: Front -> Conn -> ByteString -> IO ()
serveBuffer front c buf
  | B.null buf = do
      writeIORef (connIn c) B.empty
      now <- getMonotonicTime
      writeIORef (connDeadline c) (now + keepAliveTimeout)
  | otherwise = case parseHead (frontClaims (config front)) buf of
      NeedMore -> writeIORef (connIn c) buf
      Unclaimed -> handOff front c buf
      Parsed h
        | B.length buf < headLength h + bodyLength h -> do
            writeIORef (connIn c) buf
            continued <- readIORef (connContinued c)
            when (headContinue h && not continued) $ do
              writeIORef (connContinued c) True
              writeOut front c ["HTTP/1.1 100 Continue\r\n\r\n"]
        | otherwise -> do
            let body = B.take (bodyLength h) (BU.unsafeDrop (headLength h) buf)
                rest = BU.unsafeDrop (headLength h + bodyLength h) buf
            answer <- frontHandle (config front) (Request (headMethod h) (headTarget h) (decodeLenient body))
            case answer of
              PassToWarp -> handOff front c buf
              Respond reply -> do
                continued <- readIORef (connContinued c)
                writeIORef (connContinued c) False
                date <- BI.create 29 (c_httpDate . castPtr)
                let interim = ["HTTP/1.1 100 Continue\r\n\r\n" | headContinue h, not continued]
                    bodyOut = [replyBody reply | headMethod h /= "HEAD", not (B.null (replyBody reply))]
                writeOut front c (interim ++ renderHead h date reply : bodyOut)
                if not (headKeepAlive h)
                  then do
                    writeIORef (connIn c) B.empty
                    out <- readIORef (connOut c)
                    if null out then closeConn front c else writeIORef (connCloseAfter c) True
                  else do
                    out <- readIORef (connOut c)
                    -- a response still waiting for the socket holds back the
                    -- next request (served once it is written)
                    if null out then serveBuffer front c rest else writeIORef (connIn c) rest

-- Output -----------------------------------------------------------------------

-- | Write now what the socket takes; keep the rest and wait for the socket.
writeOut :: Front -> Conn -> [ByteString] -> IO ()
writeOut front c chunks = do
  pending <- readIORef (connOut c)
  if not (null pending)
    then writeIORef (connOut c) (pending ++ chunks)
    else do
      (rest, failed) <- writeChunks (connFd c) chunks
      if
        | failed -> closeConn front c
        | null rest -> pure ()
        | otherwise -> do
            writeIORef (connOut c) rest
            () <$ c_watch (pollFd front) (connFd c) 1

-- | The socket can take more: write what is pending; once it is all out,
-- read again (and serve what was held back), or close.
flushConn :: Front -> Conn -> IO ()
flushConn front c = do
  pending <- readIORef (connOut c)
  (rest, failed) <- writeChunks (connFd c) pending
  writeIORef (connOut c) rest
  if
    | failed -> closeConn front c
    | not (null rest) -> pure ()
    | otherwise -> do
        closeAfter <- readIORef (connCloseAfter c)
        if closeAfter
          then closeConn front c
          else do
            _ <- c_watch (pollFd front) (connFd c) 0
            readIORef (connIn c) >>= serveBuffer front c

-- | writev until done or the socket is full: the unwritten rest, and
-- whether the socket failed.
writeChunks :: CInt -> [ByteString] -> IO ([ByteString], Bool)
writeChunks _ [] = pure ([], False)
writeChunks fd chunks = do
  let batch = take 64 chunks
      count = length batch
  r <- allocaArray count $ \ptrs -> allocaArray count $ \lens -> do
    forM_ (zip [0 ..] batch) $ \(i, BI.BS fp len) -> do
      pokeElemOff ptrs i (unsafeForeignPtrToPtr fp)
      pokeElemOff lens i (fromIntegral len)
    w <- c_sendv fd ptrs lens (fromIntegral count)
    mapM_ (\(BI.BS fp _) -> touchForeignPtr fp) batch
    pure (fromIntegral w :: Int)
  if
    | r == -2 -> pure (chunks, False)
    | r < 0 -> pure ([], True)
    | otherwise ->
        let rest = dropBytes r chunks
         in if
              | null rest -> pure ([], False)
              | r < sum (map B.length batch) -> pure (rest, False)
              | otherwise -> writeChunks fd rest
  where
    dropBytes :: Int -> [ByteString] -> [ByteString]
    dropBytes 0 xs = xs
    dropBytes _ [] = []
    dropBytes k (x : xs)
      | k >= B.length x = dropBytes (k - B.length x) xs
      | otherwise = BU.unsafeDrop k x : xs

-- Parsing ----------------------------------------------------------------------

-- | The head of a request the loop answers.
data Head = Head
  { headMethod :: ByteString
  , headTarget :: ByteString
  , headKeepAlive :: Bool
  -- ^ HTTP/1.1 without @Connection: close@ (Node answers every HTTP/1.0
  -- request with @Connection: close@)
  , headHttp11 :: Bool
  , headContinue :: Bool
  -- ^ @Expect: 100-continue@
  , headLength :: Int
  -- ^ through the blank line
  , bodyLength :: Int
  }
  deriving stock (Eq, Show)

data Parse
  = NeedMore
  | -- | not the loop's: another target or method, or anything this parser
    -- does not take on (Warp gets the connection)
    Unclaimed
  | Parsed Head
  deriving stock (Eq, Show)

-- | Parse the request at the start of the buffer, as far as it has come.
-- Only plain requests are taken: everything unusual is 'Unclaimed', so
-- that the loop never answers a request Node would answer differently.
parseHead :: (ByteString -> ByteString -> Bool) -> ByteString -> Parse
parseHead claims buf = case B.elemIndex 10 buf of
  Nothing
    | B.length buf > maxHead -> Unclaimed
    | otherwise -> NeedMore
  Just lf -> case requestLine (B.take lf buf) of
    Nothing -> Unclaimed
    Just (method, target, http11)
      | not (claims method target) -> Unclaimed
      | otherwise -> case B.breakSubstring "\r\n\r\n" buf of
          (headBytes, rest)
            | B.null rest -> if B.length buf > maxHead then Unclaimed else NeedMore
            | B.length headBytes + 4 > maxHead -> Unclaimed
            | otherwise ->
                let fieldLines = splitCrlf (BU.unsafeDrop (lf + 1) headBytes)
                 in case foldr fieldLine (Just noFields) fieldLines of
                      Just fs
                        | fieldsUnusual fs -> Unclaimed
                        | fieldsLength fs > maxBody -> Unclaimed
                        | otherwise ->
                            Parsed
                              Head
                                { headMethod = method
                                , headTarget = target
                                , headKeepAlive = http11 && not (fieldsClose fs)
                                , headHttp11 = http11
                                , headContinue = fieldsContinue fs
                                , headLength = B.length headBytes + 4
                                , bodyLength = max 0 (fieldsLength fs)
                                }
                      Nothing -> Unclaimed
  where
    -- the request line, CR included
    requestLine line
      | B.null line || BU.unsafeLast line /= 13 = Nothing
      | otherwise = case BC.split ' ' (BU.unsafeInit line) of
          [m, t, v]
            | m `elem` methods
            , not (B.null t)
            , B.all (\w -> w > 32 && w < 127) t
            , v == "HTTP/1.1" || v == "HTTP/1.0" ->
                Just (m, t, v == "HTTP/1.1")
          _ -> Nothing
    methods = ["GET", "POST", "OPTIONS", "HEAD", "PUT", "DELETE", "PATCH"] :: [ByteString]

-- | What the loop needs from the header fields.
data Fields = Fields
  { fieldsLength :: Int
  -- ^ -1: no @Content-Length@
  , fieldsClose :: Bool
  , fieldsContinue :: Bool
  , fieldsUnusual :: Bool
  }

noFields :: Fields
noFields = Fields (-1) False False False

-- | One field line into the summary; Nothing when it is malformed.
fieldLine :: ByteString -> Maybe Fields -> Maybe Fields
fieldLine _ Nothing = Nothing
fieldLine line (Just fs) = case B.elemIndex 58 line of
  Nothing -> Nothing
  Just colon ->
    let name = B.take colon line
        value = trimOws (BU.unsafeDrop (colon + 1) line)
     in if
          | B.null name || not (B.all tchar name) -> Nothing
          | not (B.all fieldByte value) -> Nothing
          | named "content-length" name ->
              if fieldsLength fs >= 0 || B.null value || B.length value > 9 || not (BC.all (\ch -> ch >= '0' && ch <= '9') value)
                then Nothing
                else Just fs {fieldsLength = B.foldl' (\a w -> a * 10 + fromIntegral (w - 48)) 0 value}
          | named "connection" name ->
              let tokens = map (lower . trimOws) (BC.split ',' value)
               in Just
                    fs
                      { fieldsClose = fieldsClose fs || "close" `elem` tokens
                      , fieldsUnusual = fieldsUnusual fs || "upgrade" `elem` tokens
                      }
          | named "expect" name ->
              if lower value == "100-continue" && not (fieldsContinue fs)
                then Just fs {fieldsContinue = True}
                else Just fs {fieldsUnusual = True}
          | named "transfer-encoding" name || named "upgrade" name -> Just fs {fieldsUnusual = True}
          | otherwise -> Just fs
  where
    named lowerName n = B.length n == B.length lowerName && lower n == lowerName
    lower = B.map (\w -> if w >= 65 && w <= 90 then w + 32 else w)
    -- field-vchar, obs-text, SP and HTAB
    fieldByte w = w == 9 || (w >= 32 && w /= 127)

tchar :: Word8 -> Bool
tchar w =
  (w >= 97 && w <= 122)
    || (w >= 65 && w <= 90)
    || (w >= 48 && w <= 57)
    || w `B.elem` "!#$%&'*+-.^_`|~"

trimOws :: ByteString -> ByteString
trimOws = B.dropWhileEnd ows . B.dropWhile ows
  where
    ows w = w == 32 || w == 9

-- | Lines separated by CRLF; a lone CR or LF makes the head malformed (the
-- line then fails 'fieldLine', which takes no CR or LF).
splitCrlf :: ByteString -> [ByteString]
splitCrlf b
  | B.null b = []
  | otherwise = case B.breakSubstring "\r\n" b of
      (line, rest)
        | B.null rest -> [line]
        | otherwise -> line : splitCrlf (BU.unsafeDrop 2 rest)

-- Rendering --------------------------------------------------------------------

-- | The status line and headers of a response, as Node's @ServerResponse@
-- writes them for @res.end(body)@: the handler's headers in the order it
-- set them, @Date@, the connection headers, and @Content-Length@ when the
-- response has a body (HTTP/1.0 responses close the connection instead).
renderHead :: Head -> ByteString -> Reply -> ByteString
renderHead h date (Reply st hs body) =
  B.concat $
    [ "HTTP/1.1 "
    , BC.pack (show code)
    , " "
    , reason
    , "\r\n"
    ]
      ++ concat [[CI.original k, ": ", v, "\r\n"] | (k, v) <- hs]
      ++ ["Date: ", date, "\r\n"]
      ++ ( if headKeepAlive h
             then ["Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n"]
             else ["Connection: close\r\n"]
         )
      ++ ( if hasBody && headHttp11 h
             then ["Content-Length: ", BC.pack (show (B.length body)), "\r\n"]
             else []
         )
      ++ ["\r\n"]
  where
    code = H.statusCode st
    -- Node's STATUS_CODES for the statuses the endpoints use
    reason = case code of
      200 -> "OK"
      204 -> "No Content"
      400 -> "Bad Request"
      405 -> "Method Not Allowed"
      500 -> "Internal Server Error"
      _ -> H.statusMessage st
    hasBody = code /= 204 && code /= 304 && headMethod h /= "HEAD"
