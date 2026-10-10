-- | A loaded net as the Haskell kernel's types ("Petrus.Impetus.Petrinet.Schema").
--
-- petrus-engine runs a file by projecting the resolved net to its
-- executable 'FlatSchema' (@FlatNet.to_schema@) and building a
-- @PetriNetRuntime@ from it. 'toKernel' takes the same 'FlatSchema' to a
-- validated kernel 'Net' and the initial marking
-- (@FlatSchema.initial_marking@):
--
-- * every place, transition and arc keeps its absolute, net-prefixed path
--   (@m.p@, @m.sub.q@), in the schema's order;
-- * an arc from a place to a transition is an input arc; its kind gives the
--   mode (@normal@ 'Consume', @read@ 'Read', @inhibitor@ 'Inhibit') and its
--   weight the weight;
-- * any other arc is an output arc and must be @normal@: the kernel's modes
--   are input inscriptions, so a @read@ or @inhibitor@ output arc is refused
--   with the kernel's message (petrus-engine ignores the kind there);
-- * @handler@ and @guard@ names become 'HandlerSymbol' and 'GuardSymbol';
-- * @delay@ becomes a 'Delay' of its seconds (an integer 'Number' when it is
--   whole, else @total_seconds()@);
-- * labels, interfaces, metadata and view state have no kernel slot and are
--   dropped.
--
-- Anything 'mkNet' refuses (an arc between two places, an undeclared node,
-- a handlerless read-only transition, ...) is refused with its message; see
-- DIVERGENCES.md for the nets petrus-engine runs that the kernel does not.
module Petrus.EngineFile.Kernel
  ( KernelNet (..)
  , KernelError (..)
  , toKernel
  , loadKernelFile
  , kernelPath
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.EngineFile.Duration (Timedelta (..), totalSeconds)
import Petrus.EngineFile.Loader (Source (..), mountedSources, resolve, toSchema)
import Petrus.EngineFile.Types
import Petrus.EngineFile.Validate (PyException (..))
import Petrus.Impetus.Petrinet.Schema qualified as K

-- | A kernel net and its initial token counts (places with tokens only, in
-- place order).
data KernelNet = KernelNet
  { net :: K.Net
  , marking :: [(K.NetPath, Integer)]
  }

-- | Why a file did not become a kernel net: petrus-engine refused it, or
-- the kernel refused the net it describes.
data KernelError
  = LoadError PyException
  | KernelError Text
  deriving stock (Eq, Show)

-- | @FlatNet.from_filename(path).to_schema()@, then 'toKernel'.
loadKernelFile :: Text -> IO (Either KernelError KernelNet)
loadKernelFile path = do
  loaded <- (>>= resolve False) <$> mountedSources (FileSource path)
  pure $ case loaded >>= toSchema of
    Left e -> Left (LoadError e)
    Right schema -> either (Left . KernelError) Right (toKernel schema)

-- | The kernel spelling of a schema path.
kernelPath :: NetPath -> Either Text K.NetPath
kernelPath path = case netPathText path of
  Just text -> K.netPath text
  Nothing -> Left ("NetPath segments must be strings, got " <> T.pack (show path))

toKernel :: FlatSchema -> Either Text KernelNet
toKernel schema = do
  places <- traverse (\(p, _) -> K.place <$> kernelPath p) schema.places
  transitions <- traverse transition schema.transitions
  arcs <- traverse (arc . snd) schema.arcs
  marking <- traverse (\(p, d) -> (,d.initial) <$> kernelPath p) [(p, d) | (p, d) <- schema.places, d.initial > 0]
  net <-
    K.mkNet
      K.NetSpec
        { places
        , transitions
        , arcs
        , completion = Nothing
        , name = if T.null schema.name then Nothing else Just schema.name
        }
  Right KernelNet {net, marking}
  where
    transition (p, d) = do
      at <- kernelPath p
      Right
        K.Transition
          { path = at
          , handler = K.HandlerSymbol <$> d.handler
          , guards = maybe [] (pure . K.GuardSymbol) d.guard
          , timers = maybe [] (pure . K.Delay . seconds) d.delay
          }
    -- Direction is the kernel's to decide (place to transition is input);
    -- it refuses a non-consume mode on an output arc.
    arc a = do
      source <- kernelPath a.source
      target <- kernelPath a.target
      weight <-
        if a.weight > toInteger (maxBound :: Int) || a.weight < toInteger (minBound :: Int)
          then Left ("arc weight " <> T.pack (show a.weight) <> " does not fit the kernel's Int: " <> K.netPathText source <> " -> " <> K.netPathText target)
          else Right (fromInteger a.weight)
      Right
        K.Arc
          { source
          , target
          , mode = case a.kind of
              Normal -> K.Consume
              Read -> K.Read
              Inhibitor -> K.Inhibit
          , weight
          , color = Nothing
          , filter = Nothing
          }

-- | A delay as kernel seconds.
seconds :: Timedelta -> K.Duration
seconds t
  | t.microseconds == 0 = K.IntNumber (t.days * 86400 + t.seconds)
  | otherwise = K.FloatNumber (totalSeconds t)
