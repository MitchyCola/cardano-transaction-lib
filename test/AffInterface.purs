module Test.AffInterface (suite) where

import Prelude

import Address (addressToOgmiosAddress, ogmiosAddressToAddress)
import Data.BigInt as BigInt
import Data.Either (Either(Left, Right), either)
import Data.Maybe (Maybe(Just, Nothing), fromJust)
import Data.Traversable (traverse_)
import Data.UInt as UInt
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import Mote (group, test)
import QueryM
  ( QueryM
  , getChainTip
  , getDatumByHash
  , getDatumsByHashes
  , runQueryM
  , traceQueryConfig
  )
import QueryM.CurrentEpoch (getCurrentEpoch)
import QueryM.EraSummaries (getEraSummaries)
import QueryM.Ogmios
  ( AbsSlot(AbsSlot)
  , EraSummaries
  , OgmiosAddress
  , SystemStart
  )
import QueryM.SystemStart (getSystemStart)
import QueryM.Utxos (utxosAt)
import Serialization.Address (Slot(Slot))
import Test.Spec.Assertions (shouldEqual)
import TestM (TestPlanM)
import Types.ByteArray (hexToByteArrayUnsafe)
import Types.Interval
  ( PosixTimeToSlotError
      ( CannotConvertAbsSlotToSlot
      , PosixTimeBeforeSystemStart
      )
  , POSIXTime(POSIXTime)
  , posixTimeToSlot
  , slotToPosixTime
  )
import Types.Transaction (DataHash(DataHash))
import Partial.Unsafe (unsafePartial)

testnet_addr1 :: OgmiosAddress
testnet_addr1 =
  "addr_test1qr7g8nrv76fc7k4ueqwecljxx9jfwvsgawhl55hck3n8uwaz26mpcwu58zdkhpdnc6nuq3fa8vylc8ak9qvns7r2dsysp7ll4d"

addr1 :: OgmiosAddress
addr1 =
  "addr1qyc0kwu98x23ufhsxjgs5k3h7gktn8v5682qna5amwh2juguztcrc8hjay66es67ctn0jmr9plfmlw37je2s2px4xdssgvxerq"

-- note: currently this suite relies on Ogmios being open and running against the
-- testnet, and does not directly test outputs, as this suite is intended to
-- help verify that the Aff interface for websockets itself works,
-- not that the data represents expected values, as that would depend on chain
-- state, and ogmios itself.
suite :: TestPlanM Unit
suite = do
  -- Test UtxosAt using internal types.
  group "Aff Int" do
    test "UtxosAt Testnet" $ testUtxosAt testnet_addr1
    test "UtxosAt non-Testnet" $ testUtxosAt addr1
    test "Get ChainTip" testGetChainTip
    test "Get EraSummaries" testGetEraSummaries
    test "Get CurrentEpoch" testGetCurrentEpoch
    test "Get SystemStart" testGetSystemStart
    test "Inverse posixTimeToSlot >>> slotToPosixTime " testPosixTimeToSlot
    test "Inverse slotToPosixTime >>> posixTimeToSlot " testSlotToPosixTime
    test "PosixTimeToSlot errors" testPosixTimeToSlotError
  -- Test inverse in one direction.
  group "Address loop" do
    test "Ogmios Address to Address & back Testnet"
      $ testFromOgmiosAddress testnet_addr1
    test "Ogmios Address to Address & back non-Testnet"
      $ testFromOgmiosAddress addr1
  group "Ogmios datum cache" do
    test "Can process GetDatumByHash" do
      testOgmiosDatumCacheGetDatumByHash
    test "Can process GetDatumsByHashes" do
      testOgmiosDatumCacheGetDatumsByHashes

testOgmiosDatumCacheGetDatumByHash :: Aff Unit
testOgmiosDatumCacheGetDatumByHash =
  traceQueryConfig >>= flip runQueryM do
    -- Use this to trigger block fetching in order to actually get the datum:
    -- ```
    -- curl localhost:9999/control/fetch_blocks -X POST -d '{"slot": 54066900, "id": "6eb2542a85f375d5fd6cbc1c768707b0e9fe8be85b7b1dd42a85017a70d2623d", "datumFilter": {"address": "addr_xyz"}}' -H 'Content-Type: application/json'
    -- ```
    _datum <- getDatumByHash $ DataHash $ hexToByteArrayUnsafe
      "f7c47c65216f7057569111d962a74de807de57e79f7efa86b4e454d42c875e4e"
    pure unit

testOgmiosDatumCacheGetDatumsByHashes :: Aff Unit
testOgmiosDatumCacheGetDatumsByHashes =
  traceQueryConfig >>= flip runQueryM do
    -- Use this to trigger block fetching in order to actually get the datum:
    -- ```
    -- curl localhost:9999/control/fetch_blocks -X POST -d '{"slot": 54066900, "id": "6eb2542a85f375d5fd6cbc1c768707b0e9fe8be85b7b1dd42a85017a70d2623d", "datumFilter": {"address": "addr_xyz"}}' -H 'Content-Type: application/json'
    -- ```
    _datums <- getDatumsByHashes $ pure $ DataHash $ hexToByteArrayUnsafe
      "f7c47c65216f7057569111d962a74de807de57e79f7efa86b4e454d42c875e4e"
    pure unit

testUtxosAt :: OgmiosAddress -> Aff Unit
testUtxosAt testAddr = case ogmiosAddressToAddress testAddr of
  Nothing -> liftEffect $ throw "Failed UtxosAt"
  Just addr -> flip runQueryM (void $ utxosAt addr) =<< traceQueryConfig

testGetChainTip :: Aff Unit
testGetChainTip = do
  flip runQueryM (void getChainTip) =<< traceQueryConfig

testFromOgmiosAddress :: OgmiosAddress -> Aff Unit
testFromOgmiosAddress testAddr = do
  liftEffect case ogmiosAddressToAddress testAddr of
    Nothing -> throw "Failed Address loop"
    Just addr -> addressToOgmiosAddress addr `shouldEqual` testAddr

testGetEraSummaries :: Aff Unit
testGetEraSummaries = do
  flip runQueryM (void getEraSummaries) =<< traceQueryConfig

testGetCurrentEpoch :: Aff Unit
testGetCurrentEpoch = do
  flip runQueryM (void getCurrentEpoch) =<< traceQueryConfig

testGetSystemStart :: Aff Unit
testGetSystemStart = do
  flip runQueryM (void getSystemStart) =<< traceQueryConfig

testPosixTimeToSlot :: Aff Unit
testPosixTimeToSlot = do
  traceQueryConfig >>= flip runQueryM do
    eraSummaries <- getEraSummaries
    sysStart <- getSystemStart
    let
      -- Tests currently pass "exactly" for seconds precision, which makes sense
      -- given converting to a Slot will round down to the near slot length
      -- (mostly 1s). If it rounds down and is the end slot, then a check is in
      -- place that any "extra" time is zero.
      -- We can allow for Millseconds as (off chain) input if we assume
      -- the seconds provided by Ogmios are exact, which seems to be the case
      -- here https://cardano.stackexchange.com/questions/7034/how-to-convert-posixtime-to-slot-number-on-cardano-testnet/7035#7035
      -- `timeWhenSlotChangedTo1Sec = POSIXTime 1595967616000` - exactly
      -- divisible by 1 second.
      posixTimes = mkPosixTime <$>
        [ "1603636353000"
        , "1613636755000"
        , "1753645721000"
        ]
    traverse_ (idTest eraSummaries sysStart identity) posixTimes
    -- With Milliseconds, we generally round down, provided the aren't at the
    -- end  with non-zero excess:
    idTest eraSummaries sysStart
      (const $ mkPosixTime "1613636754000")
      (mkPosixTime "1613636754999")
    idTest eraSummaries sysStart
      (const $ mkPosixTime "1613636754000")
      (mkPosixTime "1613636754500")
    idTest eraSummaries sysStart
      (const $ mkPosixTime "1613636754000")
      (mkPosixTime "1613636754499")
  where
  idTest
    :: EraSummaries
    -> SystemStart
    -> (POSIXTime -> POSIXTime)
    -> POSIXTime
    -> QueryM Unit
  idTest es ss transf posixTime = liftEffect do
    posixTimeToSlot es ss posixTime >>= case _ of
      Left err -> throw $ show err
      Right slot -> do
        ePosixTime <- slotToPosixTime es ss slot
        either (throw <<< show) (shouldEqual $ transf posixTime) ePosixTime

mkPosixTime :: String -> POSIXTime
mkPosixTime = POSIXTime <<< unsafePartial fromJust <<< BigInt.fromString

testSlotToPosixTime :: Aff Unit
testSlotToPosixTime = do
  traceQueryConfig >>= flip runQueryM do
    eraSummaries <- getEraSummaries
    sysStart <- getSystemStart
    let
      slots = mkSlot <$>
        [ 395930213
        , 58278567
        , 48272312
        , 39270783
        , 957323
        , 34952
        , 7532
        , 232
        , 1
        ]
    traverse_ (idTest eraSummaries sysStart) slots
  where
  idTest :: EraSummaries -> SystemStart -> Slot -> QueryM Unit
  idTest es ss slot = liftEffect do
    slotToPosixTime es ss slot >>= case _ of
      Left err -> throw $ show err
      Right posixTime -> do
        eSlot <- posixTimeToSlot es ss posixTime
        either (throw <<< show) (shouldEqual slot) eSlot

  mkSlot :: Int -> Slot
  mkSlot = Slot <<< UInt.fromInt

testPosixTimeToSlotError :: Aff Unit
testPosixTimeToSlotError = do
  traceQueryConfig >>= flip runQueryM do
    eraSummaries <- getEraSummaries
    sysStart <- getSystemStart
    let
      posixTime = mkPosixTime "1000"
      badPosixTime = mkPosixTime "99999999999999999999999999999999999999"
      badAbsSlot = AbsSlot
        $ unsafePartial fromJust
        $ BigInt.fromString "99999999999999999999999998405630783"
    -- Some difficulty reproducing all the errors
    errTest eraSummaries sysStart
      posixTime
      (PosixTimeBeforeSystemStart posixTime)
    errTest eraSummaries sysStart
      badPosixTime
      (CannotConvertAbsSlotToSlot badAbsSlot)
  where
  errTest
    :: forall (err :: Type)
     . EraSummaries
    -> SystemStart
    -> POSIXTime
    -> PosixTimeToSlotError
    -> QueryM Unit
  errTest es ss posixTime expectedErr = liftEffect do
    posixTimeToSlot es ss posixTime >>= case _ of
      Left err -> err `shouldEqual` expectedErr
      Right _ ->
        throw $ "Test should have failed giving: " <> show expectedErr
