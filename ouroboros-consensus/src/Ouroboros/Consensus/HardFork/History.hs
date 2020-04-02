{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveAnyClass            #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE DerivingStrategies        #-}
{-# LANGUAGE DerivingVia               #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeOperators             #-}

-- | Intended for qualified import
--
-- > import qualified Ouroboros.Consensus.HardFork.History as HardFork
module Ouroboros.Consensus.HardFork.History (
    -- * History
    -- ** Params
    EraParams(..)
  , SafeZone(..)
  , SafeBeforeEpoch(..)
  , defaultEraParams
    -- ** Shape
  , Shape(..)
  , singletonShape
    -- ** Transitions
  , Transitions(..)
  , transitionsUnknown
    -- * Summary
  , Summary(..)    -- Non-opaque only for the benefit of tests
  , SystemStart(..)
  , summarize
    -- * Conversions
  , PastHorizonException(..)
  , wallclockToSlot
  , slotToWallclock
  , slotToEpoch
  , epochToSlot
    -- * Support for 'EpochInfo'
  , summaryToEpochInfo
  , snapshotEpochInfo
    -- * Exported only for the benefit of tests
    -- ** Bounds
    --
    -- TODO: Document expected relation between 'boundSlot' and 'boundEpoch',
    -- and test that 'initBound' and 'mkUpperBound' both establish it.
  , Bound -- Still opaque, even for tests. Has internal invariants.
  , boundEpoch
  , boundSlot
  , boundTime
  , initBound
  , mkUpperBound
    -- ** Summary
  , EraSummary(..)
    -- ** Summary translations
  , ShiftTime(..)
    -- ** Invariants
  , invariantSummary
  , invariantShape
    -- ** Auxiliary
  , addEpochs
  , addSlots
  , countEpochs
  , countSlots
  ) where

import           Control.Exception (Exception (..), assert, throw)
import           Control.Monad.Except
import           Data.Bifunctor
import           Data.Fixed (divMod')
import           Data.Foldable (toList)
import           Data.Functor.Identity
import qualified Data.List as List
import           Data.Time
import           Data.Word
import           GHC.Generics (Generic)

import           Cardano.Prelude (NoUnexpectedThunks, OnlyCheckIsWHNF (..))
import           Cardano.Slotting.EpochInfo.API
import           Cardano.Slotting.Slot

import           Ouroboros.Consensus.BlockchainTime.SlotLength
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Util.Counting
import           Ouroboros.Consensus.Util.IOLike

{-------------------------------------------------------------------------------
  OVERVIEW

  The overall chain consists of various /era/s. Each era has its own set of era
  parameters such as the slot length and epoch size, as well as its own block
  format, ledger format, ledger rules, etc. It is assumed that the overall
  /shape/ of the chain is known. In other words, we statically know which eras
  we expect and what their parameters are; adding an additional era would
  require a code update. What we /don't/ know precisely is /when/ we transition
  from one era to the next, i.e., the hard fork transition points.

  When we are at genesis, the chain therefore looks something like this:

  > *-------------------?--------------------?--------------------
  > ^
  > \-- tip

  where we have (in this example) three eras (say, Byron, Shelley and Goguen)
  and therefore two hard fork transitions. Hard forks happen at epoch
  boundaries; the exact 'EpochNo' of each hard fork is determined by the era
  preceding it. Naturally, the exact 'EpochNo' of /past/ hard forks is known:

  > ---------------A--------------*----------?--------------------
  >                               ^
  >                               \-- tip

  where A is a known hard fork transition, and the next hard fork transition
  is still unknown.

  SAFE ZONES

  Future hard fork points may be known or unknown, where "known" means
  "certain"; i.e., for Byron, it would mean an update proposal has been voted
  on, confirmed, endorsed, and that endorsement is at least @k@ blocks deep into
  the chain; for Shelley it means an update proposal is voted on and accepted,
  and that acceptance is at least @k@ blocks deep into the chain.

  When a hard fork point is still unknown, we assume that each era determines a
  "safe zone": a number of slots from the tip of the ledger in which it is
  guaranteed that the hard fork will not happen.

  > CASE (i)
  >
  > ---------------A--------------*----------?--------------------
  >                               \..../
  >                                safe
  >                                zone

  Since the hard fork will not happen in the safe zone, we can extend the use of
  the current set of era parameters past the tip into the safe zone, giving us a
  limited ability to make predictions for the future (such as converting between
  slot numbers and wallclock time).

  We assume that once a transition point is known (and no longer subject to
  roll-back), this is guaranteed not to change anymore and we can use the era's
  parameters up to the transition point:

  > CASE (ii)
  >
  > ---------------A--------------*----------------B--------------
  >                               \.............../
  >                                implicitly safe

  Moreover, we assume that we can extend B's safe zone from the point of the
  hard fork transition:

  > CASE (iii)
  >
  > ---------------A--------------*----------------B--------------
  >                               \.............../\..../
  >                                implicitly safe  safe
  >                                                 zone

  This is justified because the safe zones arise from stability requirements
  for the transactions that establish the transition point. The earliest point
  such a transaction could be included in the chain is after the hard fork
  transition, since it must be a transaction from the /new/ era.
-------------------------------------------------------------------------------}

-- | Parameters that can vary across hard forks
data EraParams = EraParams {
      eraEpochSize  :: !EpochSize
    , eraSlotLength :: !SlotLength
    , eraSafeZone   :: !SafeZone
    }
  deriving stock    (Show, Generic)
  deriving anyclass (NoUnexpectedThunks)

-- | Default 'EraParams'
--
-- We set the epoch size to @10k@ slots and the safe zone to @2k@ slots.
defaultEraParams :: SecurityParam -> SlotLength -> EraParams
defaultEraParams (SecurityParam k) slotLength = EraParams {
      eraEpochSize  = EpochSize (k * 10)
    , eraSlotLength = slotLength
    , eraSafeZone   = SafeZone (k * 2) NoLowerBound
    }

-- | Zone in which it is guaranteed that no hard fork can take place
data SafeZone = SafeZone {
      -- | Number of slots from the tip of the ledger
      safeFromTip     :: !Word64

      -- | Optionally, an 'EpochNo' before which no hard fork can take place
    , safeBeforeEpoch :: !SafeBeforeEpoch
    }
  deriving stock    (Show, Generic)
  deriving anyclass (NoUnexpectedThunks)

-- | Lower bound on when a transition can take place
data SafeBeforeEpoch =
    -- | No such lower bound is known
    NoLowerBound

    -- | 'EpochNo' before which a transition is guaranteed not to take place
    --
    -- Often such a value is available, since a new era is planned only after
    -- the current era has already been running for a while. For example, at
    -- the time of writing, we know the Byron to Shelley transition cannot
    -- happen before epoch 180, since we are currently already in epoch 179.
    --
    -- Moreover, for epoch transitions that have /already/ taken place, the
    -- exact 'EpochNo' of the transition can be used.
    --
    -- Providing this value is strictly an optimization; for example, it will
    -- reduce the frequency with which 'summaryToEpochInfo' must update its
    -- summary of the hard fork history.
  | LowerBound !EpochNo
  deriving stock    (Show, Generic)
  deriving anyclass (NoUnexpectedThunks)

-- | The shape of the chain
--
-- The shape determines how many hard forks we expect as well as the parameters
-- for each era. The type argument is a type-level list containing one entry
-- per era, emphasizing that this information is statically known.
--
-- The indices are currently not yet used, but the idea is that they look
-- something like @'[Byron, Shelley, Goguen]@ and are then also used by the
-- hard fork combinator (most likely this will be a list of block types, since
-- most of consensus is indexed by block types).
newtype Shape xs = Shape (Exactly xs EraParams)
  deriving (Show)

-- | There is only one era
singletonShape :: EraParams -> Shape '[x]
singletonShape params = Shape (exactlyOne params)

-- | The exact point of each confirmed hard fork transition
--
-- Unlike the 'Shape' of the chain, which is statically known, the 'Transitions'
-- are derived from the state of the ledger (hard fork transition points only
-- become known after a voting procedure).
--
-- Any transition listed here must be "certain". How certainty is established is
-- ledger dependent, but it should imply that this is no longer subject to
-- rollback.
data Transitions :: [*] -> * where
  -- | If the indices are, say, @'[Byron, Shelley, Goguen]@, then we can have
  -- have at most two transitions: one to Shelley, and one to Goguen. There
  -- cannot be a transition /to/ the initial ledger.
  Transitions :: AtMost xs EpochNo -> Transitions (x ': xs)

deriving instance Show (Transitions xs)

-- | No known transitions yet
transitionsUnknown :: Transitions (x ': xs)
transitionsUnknown = Transitions AtMostNil

{-------------------------------------------------------------------------------
  Bounds
-------------------------------------------------------------------------------}

-- | Detailed information about the time bounds of an era
--
-- TODO: Document expected relation between 'boundSlot' and 'boundEpoch',
-- and test that 'initBound' and 'mkUpperBound' both establish it.
data Bound = Bound {
      boundTime  :: !UTCTime
    , boundSlot  :: !SlotNo
    , boundEpoch :: !EpochNo
    }
  deriving (Show, Eq)

initBound :: SystemStart -> Bound
initBound (SystemStart start) = Bound {
      boundTime  = start
    , boundSlot  = SlotNo 0
    , boundEpoch = EpochNo 0
    }

-- | Compute upper bound given just the epoch number and era parameters
mkUpperBound :: EraParams -> Bound -> EpochNo -> Bound
mkUpperBound EraParams{..} lo hiEpoch = Bound {
      boundTime  = addUTCTime inEraTime  $ boundTime lo
    , boundSlot  = addSlots   inEraSlots $ boundSlot lo
    , boundEpoch = hiEpoch
    }
  where
    inEraEpochs, inEraSlots :: Word64
    inEraEpochs = countEpochs hiEpoch (boundEpoch lo)
    inEraSlots  = inEraEpochs * unEpochSize eraEpochSize

    inEraTime :: NominalDiffTime
    inEraTime = fromIntegral inEraSlots * getSlotLength eraSlotLength

{-------------------------------------------------------------------------------
  Internal: summary

  This is what we use internally for all translations.
-------------------------------------------------------------------------------}

-- | Information about a specific era
--
-- The 'eraEnd' of the final era in the summary will be determined by the
-- safe zone considerations discussed above.
data EraSummary = EraSummary {
      eraStart  :: !Bound     -- ^ Inclusive lower bound
    , eraEnd    :: !Bound     -- ^ Exclusive upper bound
    , eraParams :: !EraParams -- ^ Active parameters
    }
  deriving (Show)

-- | Summary of the /confirmed/ part of the ledger
--
-- The summary zips 'Shape' with 'Forks', and provides detailed information
-- about the start and end of each era.
newtype Summary xs = Summary (AtMost xs EraSummary)

deriving instance Show (Summary xs)
deriving via OnlyCheckIsWHNF "Summary" (Summary xs)
         instance NoUnexpectedThunks (Summary xs)

summaryToList :: Summary xs -> [EraSummary]
summaryToList (Summary summary) = toList summary

{-------------------------------------------------------------------------------
  Translations (primarily for the benefit of tests)
-------------------------------------------------------------------------------}

class ShiftTime a where
  shiftTime :: NominalDiffTime -> a -> a

instance ShiftTime SystemStart where
  shiftTime delta (SystemStart start) = SystemStart $ shiftTime delta start

instance ShiftTime a => ShiftTime [a] where
  shiftTime = map . shiftTime

instance ShiftTime (Summary xs) where
  shiftTime delta (Summary summary) = Summary $ shiftTime delta <$> summary

instance ShiftTime EraSummary where
  shiftTime delta EraSummary{..} = EraSummary{
      eraStart  = shiftTime delta eraStart
    , eraEnd    = shiftTime delta eraEnd
    , eraParams = eraParams
    }

instance ShiftTime Bound where
  shiftTime delta Bound{..} = Bound {
      boundTime  = shiftTime delta boundTime
    , boundSlot  = boundSlot
    , boundEpoch = boundEpoch
    }

instance ShiftTime UTCTime where
  shiftTime = addUTCTime

{-------------------------------------------------------------------------------
  Invariants
-------------------------------------------------------------------------------}

-- | Check 'Shape' invariants
--
-- The only part of the 'Shape' that must make sense is the 'safeBeforeEpoch'
-- values (they must be strictly increasing).
invariantShape :: Shape xs -> Except String ()
invariantShape = \(Shape shape) ->
    go (EpochNo 0) shape
  where
    go :: EpochNo -- ^ Lower bound on the start of the era
       -> Exactly xs EraParams -> Except String ()
    go _           ExactlyNil                    = return ()
    go lowerBound (ExactlyCons curParams shape') = do
        nextLowerBound <-
          case safeBeforeEpoch (eraSafeZone curParams) of
            NoLowerBound -> do
              return $ addEpochs 1 lowerBound
            LowerBound e -> do
              unless (e > lowerBound) $
                throwError $ mconcat [
                    "Invalid safeBeforeEpoch in "
                  , show curParams
                  , " (should be greater than "
                  , show lowerBound
                  ,  ")"
                  ]
              return $ e

        go nextLowerBound shape'

-- | Check 'Summary' invariants
invariantSummary :: Summary xs -> Except String ()
invariantSummary = \(Summary summary) ->
    -- Pretend the start of the first era is the "end of the previous" one
    case summary of
      AtMostNil             -> return ()
      AtMostCons firstEra _ -> go (eraStart firstEra) summary
  where
    go :: Bound   -- ^ End of the previous era
       -> AtMost xs EraSummary -> Except String ()
    go _        AtMostNil                   = return ()
    go prevEnd (AtMostCons curSummary next) = do
        unless (curStart == prevEnd) $
          throwError $ mconcat [
              "Bounds don't line up: "
            , show prevEnd
            , " /= "
            , show curStart
            ]

        unless (boundEpoch curEnd > boundEpoch curStart) $
          throwError "Empty era"

        case safeBeforeEpoch (eraSafeZone curParams) of
          NoLowerBound -> return ()
          LowerBound e ->
              unless (boundEpoch curEnd >= e) $
                throwError $ mconcat [
                    "Invalid upper epoch bound "
                  , show (boundEpoch curStart)
                  , " (should be greater than "
                  , show e
                  , ")"
                  ]

        unless (boundSlot curEnd == addSlots slotsInEra (boundSlot curStart)) $
          throwError $ mconcat [
              "Invalid final boundSlot in "
            , show curSummary
            ]

        unless (boundTime curEnd == addUTCTime timeInEra (boundTime curStart)) $
          throwError $ mconcat [
              "Invalid final boundTime in "
            , show curSummary
            ]

        go curEnd next
      where
        curStart, curEnd :: Bound
        curParams        :: EraParams
        EraSummary curStart curEnd curParams = curSummary

        epochsInEra, slotsInEra :: Word64
        epochsInEra = countEpochs (boundEpoch curEnd) (boundEpoch curStart)
        slotsInEra  = epochsInEra * unEpochSize (eraEpochSize curParams)

        timeInEra :: NominalDiffTime
        timeInEra = fromIntegral slotsInEra
                  * getSlotLength (eraSlotLength curParams)

{-------------------------------------------------------------------------------
  Constructing the summary
-------------------------------------------------------------------------------}

newtype SystemStart = SystemStart { getSystemStart :: UTCTime }
  deriving (Show)

-- | Construct hard fork 'Summary'
--
-- NOTE (on epoch to slot translation). In order to translate 'SlotNo' to
-- 'EpochNo', we simply "line up" all slots. For example, suppose we have
-- an initial 'EpochSize' of 10, and then an 'EpochSize' of 20 from 'EpochNo'
-- 3 onwards. We end up with something like
--
-- > Epoch | 0      | 1        | 2        | 3        | 4        | ..
-- > Slot  | 0 .. 9 | 10 .. 19 | 20 .. 29 | 30 .. 49 | 50 .. 69 | ..
--
-- We do this translation /independent/ from the 'minimumPossibleSlotNo'
-- for a particular ledger. This means that for ledgers where the
-- 'minimumPossibleSlotNo' is not zero (e.g., Shelley sets it to 1), the maximum
-- number of blocks (aka filled slots) in an epoch is just 1 (or more) less
-- than the other epochs.
summarize :: SystemStart
          -> WithOrigin SlotNo -- ^ Slot at the tip of the ledger
          -> Shape       xs
          -> Transitions xs
          -> Summary     xs
summarize systemStart ledgerTip = \(Shape shape) (Transitions transitions) ->
    Summary $ go (initBound systemStart) shape transitions
  where
    go :: Bound
       -> Exactly (x ': xs) EraParams   -- params for all eras
       -> AtMost        xs  EpochNo     -- transitions
       -> AtMost  (x ': xs) EraSummary
    -- CASE (ii)
    -- NOTE: Ledger tip might be close to the end of this era (or indeed past
    -- it) but this doesn't matter for the summary of /this/ era.
    go lo (ExactlyCons params ss) (AtMostCons epoch fs) =
        AtMostCons (EraSummary lo hi params) $ go hi ss fs
      where
        hi = mkUpperBound params lo epoch
    -- CASE (i) or (iii)
    go lo (ExactlyCons params@EraParams{..} _) AtMostNil =
        atMostOne $ EraSummary lo hi params
      where
        hi :: Bound
        hi = mkUpperBound params lo
           . maxMaybeEpoch (safeBeforeEpoch eraSafeZone)
           . slotToEpochBound params lo
           . addSlots (safeFromTip eraSafeZone)
             -- If the tip is already in this era, safe zone applies from the
             -- ledger tip (CASE (i)). If the ledger tip is in the /previous/
             -- era, but the transition to /this/ era is already known, the safe
             -- zone applies from the start of this era (CASE (iii)).
           $ maxMaybeSlot ledgerTip (boundSlot lo)

    -- Given the 'SlotNo' of the first /slot/ in which a transition could take
    -- place, compute the first /epoch/ in which this could happen (since
    -- transitions only take place at epoch boundaries). If the 'SlotNo' happens
    -- to be the first slot in an epoch, it will be that 'EpochNo'; if it isn't,
    -- however, it will be the /next/ epoch.
    slotToEpochBound :: EraParams -> Bound -> SlotNo -> EpochNo
    slotToEpochBound EraParams{eraEpochSize = EpochSize epochSize} lo hiSlot =
        addEpochs
          (if inEpoch == 0 then epochs else epochs + 1)
          (boundEpoch lo)
      where
        slots             = countSlots hiSlot (boundSlot lo)
        (epochs, inEpoch) = slots `divMod` epochSize

    maxMaybeEpoch :: SafeBeforeEpoch -> EpochNo -> EpochNo
    maxMaybeEpoch NoLowerBound   = id
    maxMaybeEpoch (LowerBound e) = max e

    maxMaybeSlot :: WithOrigin SlotNo -> SlotNo -> SlotNo
    maxMaybeSlot Origin = id
    maxMaybeSlot (At s) = max s

{-------------------------------------------------------------------------------
  Internal: looking up values in the history
-------------------------------------------------------------------------------}

data Condition =
    ContainsTime  UTCTime
  | ContainsSlot  SlotNo
  | ContainsEpoch EpochNo
  deriving (Show)

eval :: Condition -> EraSummary -> Bool
eval condition EraSummary{..} =
    case condition of
      ContainsTime  x -> boundTime  `contains` x
      ContainsSlot  x -> boundSlot  `contains` x
      ContainsEpoch x -> boundEpoch `contains` x
  where
    contains :: Ord a => (Bound -> a) -> a -> Bool
    f `contains` x = f eraStart <= x && x < f eraEnd

find :: Summary xs -> Condition -> Except PastHorizonException EraSummary
find summary condition =
    case List.find (eval condition) (summaryToList summary) of
      Nothing -> throwError $ PastHorizon summary condition
      Just s  -> return s

data PastHorizonException =
    -- | We tried to convert something that is past the horizon
    --
    -- That is, we tried to convert something that is past the point in time
    -- beyond which we lack information due to uncertainty about the next
    -- hard fork.
    --
    -- We record both the hard fork summary and the thing that we are looking
    -- for. Although both of these are internal types that can strictly speaking
    -- leak out of the API through this exception, they are provided here
    -- merely for debugging: if this exception is ever raised, it indicates
    -- a bug somewhere.
    forall xs. PastHorizon (Summary xs) Condition

deriving instance Show PastHorizonException
instance Exception PastHorizonException

{-------------------------------------------------------------------------------
  Conversion between wallclock and slots
-------------------------------------------------------------------------------}

-- | Translate 'UTCTime' to 'SlotNo'
--
-- Additionally returns the time spent in this slot.
wallclockToSlot :: Summary xs
                -> UTCTime
                -> Except PastHorizonException (SlotNo, NominalDiffTime)
wallclockToSlot summary time =
    go <$> find summary (ContainsTime time)
  where
    go :: EraSummary -> (SlotNo, NominalDiffTime)
    go EraSummary{..} = first toAbsSlot $ relTime `divMod'` slotLen
      where
        EraParams{..} = eraParams

        toAbsSlot :: Word64 -> SlotNo
        toAbsSlot relSlot = SlotNo $ unSlotNo (boundSlot eraStart) + relSlot

        relTime, slotLen :: NominalDiffTime
        relTime = time `diffUTCTime` (boundTime eraStart)
        slotLen = getSlotLength eraSlotLength

-- | Translate 'SlotNo' to the 'UTCTime' at the start of that slot
--
-- Additionally returns the length of the slot.
slotToWallclock :: Summary xs
                -> SlotNo
                -> Except PastHorizonException (UTCTime, SlotLength)
slotToWallclock summary slot =
    go <$> find summary (ContainsSlot slot)
  where
    go :: EraSummary -> (UTCTime, SlotLength)
    go EraSummary{..} = (
          addUTCTime (fromIntegral relSlot * slotLen) (boundTime eraStart)
        , eraSlotLength
        )
      where
        EraParams{..} = eraParams

        relSlot :: Word64
        relSlot = unSlotNo slot - unSlotNo (boundSlot eraStart)

        slotLen :: NominalDiffTime
        slotLen = getSlotLength eraSlotLength

{-------------------------------------------------------------------------------
  Conversion between slots and epochs
-------------------------------------------------------------------------------}

-- | Translate 'SlotNo' to its corresponding 'EpochNo'
--
-- Additionally returns the relative slot within this epoch
slotToEpoch :: Summary xs
            -> SlotNo
            -> Except PastHorizonException (EpochNo, Word64)
slotToEpoch summary slot =
    go <$> find summary (ContainsSlot slot)
  where
    go :: EraSummary -> (EpochNo, Word64)
    go EraSummary{..} = first toAbsEpoch $ relSlot `divMod` epochSize
      where
        EraParams{..} = eraParams

        toAbsEpoch :: Word64 -> EpochNo
        toAbsEpoch relEpoch = EpochNo $ unEpochNo (boundEpoch eraStart) + relEpoch

        relSlot, epochSize :: Word64
        relSlot   = unSlotNo slot - unSlotNo (boundSlot eraStart)
        epochSize = unEpochSize eraEpochSize

-- | Translate 'EpochNo' to the 'SlotNo' of the first slot in that epoch
--
-- Additionally returns the size of the epoch.
epochToSlot :: Summary xs
            -> EpochNo
            -> Except PastHorizonException (SlotNo, EpochSize)
epochToSlot summary epoch =
    go <$> find summary (ContainsEpoch epoch)
  where
    go :: EraSummary -> (SlotNo, EpochSize)
    go EraSummary{..} = (
          SlotNo $ unSlotNo (boundSlot eraStart) + relEpoch * epochSize
        , eraEpochSize
        )
      where
        EraParams{..} = eraParams

        relEpoch, epochSize :: Word64
        relEpoch  = unEpochNo epoch - unEpochNo (boundEpoch eraStart)
        epochSize = unEpochSize eraEpochSize

{-------------------------------------------------------------------------------
  Translation to EpochInfo
-------------------------------------------------------------------------------}

-- | Construct 'EpochInfo' from a function that returns the hard fork summary
--
-- When a particular request fails with a 'PastHorizon' error, we ask for an
-- updated summary, in the hope that the ledger state has advanced. If the query
-- /still/ fails with that updated summary, the error is thrown as an exception.
summaryToEpochInfo :: forall m xs. (MonadSTM m, MonadThrow m)
                   => STM m (Summary xs) -> m (EpochInfo m)
summaryToEpochInfo getSummary = do
    initSummary <- atomically getSummary
    var <- newTVarM initSummary
    return $ mkInfo var
  where
    mkInfo :: StrictTVar m (Summary xs) -> EpochInfo m
    mkInfo var = EpochInfo {
          epochInfoSize  = withSummary var snd . flip epochToSlot
        , epochInfoFirst = withSummary var fst . flip epochToSlot
        , epochInfoEpoch = withSummary var fst . flip slotToEpoch
        }

    withSummary :: StrictTVar m (Summary xs)
                -> (a -> b)
                -> (Summary xs -> Except PastHorizonException a)
                -> m b
    withSummary var g f = do
        summary <- atomically $ readTVar var
        case runExcept $ f summary of
          Right a -> return (g a)
          Left  _ -> do
            -- Perhaps the ledger has advanced. Ask for a new summary
            summary' <- atomically $ getSummary
            atomically $ writeTVar var summary'
            case runExcept $ f summary' of
              Right a -> return (g a)
              Left  e -> throwM e

-- | Construct an 'EpochInfo' for a /snapshot/ of the ledger state
--
-- When a particular request fails with a 'PastHorizon' error, we throw the
-- error as a /pure/ exception. Such an exception would indicate a bug.
snapshotEpochInfo :: forall xs. Summary xs -> EpochInfo Identity
snapshotEpochInfo summary = EpochInfo {
      epochInfoSize  = throwPastHorizon snd . flip epochToSlot
    , epochInfoFirst = throwPastHorizon fst . flip epochToSlot
    , epochInfoEpoch = throwPastHorizon fst . flip slotToEpoch
    }
  where
    throwPastHorizon :: (a -> b)
                     -> (Summary xs -> Except PastHorizonException a)
                     -> Identity b
    throwPastHorizon g f =
        case runExcept $ f summary of
          Right a -> Identity $ g a
          Left  e -> throw e

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

addSlots  :: Word64 -> SlotNo  -> SlotNo
addEpochs :: Word64 -> EpochNo -> EpochNo

addSlots  n (SlotNo  x) = SlotNo  (x + n)
addEpochs n (EpochNo x) = EpochNo (x + n)

countSlots  :: SlotNo  -> SlotNo  -> Word64
countEpochs :: EpochNo -> EpochNo -> Word64

countSlots  (SlotNo  to) (SlotNo  fr) = assert (to >= fr) $ to - fr
countEpochs (EpochNo to) (EpochNo fr) = assert (to >= fr) $ to - fr