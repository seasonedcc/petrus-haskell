-- | Values a test builds from literals through a validating smart
-- constructor.
module Petrus.TestSupport.Valid (valid) where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Stack (HasCallStack)

-- | The value a smart constructor accepted. A refusal is a mistake in the
-- test's own literals, so it fails the test with the constructor's message.
valid :: (HasCallStack) => Either Text a -> a
valid = either (error . T.unpack) id
