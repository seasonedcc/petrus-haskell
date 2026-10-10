-- | The GitHub App JSON Web Token, as GitHubKit mints it through PyJWT:
-- RS256 (RSASSA-PKCS1-v1_5 with SHA-256) over
-- @{"alg":"RS256","typ":"JWT"}@ and @{"iss":…,"iat":…,"exp":…}@, issued a
-- minute in the past and valid for ten minutes.
module Hamsterdan.GitHub.Jwt
  ( SigningKey
  , loadSigningKey
  , appJwt
  , jwtPayload
  ) where

import Crypto.Hash.Algorithms (SHA256 (..))
import Crypto.PubKey.RSA qualified as RSA
import Crypto.PubKey.RSA.PKCS15 qualified as PKCS15
import Data.ByteString (ByteString)
import Data.ByteString.Base64.URL qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.X509 qualified as X509
import Data.X509.Memory (readKeyFileFromMemory)

-- | A parsed RSA App private key.
newtype SigningKey = SigningKey RSA.PrivateKey

-- | PyJWT's @RSAAlgorithm.prepare_key@ for a PEM private key (PKCS#1
-- @RSA PRIVATE KEY@ or PKCS#8 @PRIVATE KEY@). 'Left' is the message of the
-- @InvalidKeyError@ PyJWT raises for anything else.
loadSigningKey :: Text -> Either Text SigningKey
loadSigningKey pem = case reverse (readKeyFileFromMemory (TE.encodeUtf8 pem)) of
  X509.PrivKeyRSA key : _ -> Right (SigningKey key)
  _ -> Left "Could not parse the provided public key."

-- | The compact payload: @iat@ is a minute before the floored clock and
-- @exp@ nine minutes after it.
jwtPayload :: Text -> Integer -> ByteString
jwtPayload issuer now =
  TE.encodeUtf8 ("{\"iss\":" <> quoted issuer <> ",\"iat\":" <> T.pack (show (now - 60)) <> ",\"exp\":" <> T.pack (show (now + 540)) <> "}")
  where
    -- The issuer is the decimal App id, which needs no escaping.
    quoted value = "\"" <> value <> "\""

-- | Sign the App JWT for an issuer at a POSIX time (whole seconds).
appJwt :: SigningKey -> Text -> Integer -> Either Text Text
appJwt (SigningKey key) issuer now = do
  let signingInput = header <> "." <> B64.encodeUnpadded (jwtPayload issuer now)
  signature <- either (Left . T.pack . show) Right (PKCS15.sign Nothing (Just SHA256) key signingInput)
  Right (TE.decodeLatin1 (signingInput <> "." <> B64.encodeUnpadded signature))
  where
    header = B64.encodeUnpadded "{\"alg\":\"RS256\",\"typ\":\"JWT\"}"
