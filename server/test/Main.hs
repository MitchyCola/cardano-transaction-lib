module Main (main) where

import Api (app, applyArgs, estimateTxFees)
import Cardano.Api qualified as C
import Cardano.Api.Shelley (
  ExecutionUnitPrices (
    ExecutionUnitPrices,
    priceExecutionMemory,
    priceExecutionSteps
  ),
  ExecutionUnits (ExecutionUnits, executionMemory, executionSteps),
  Lovelace (Lovelace),
  ProtocolParameters (
    ProtocolParameters,
    protocolParamCollateralPercent,
    protocolParamCostModels,
    protocolParamDecentralization,
    protocolParamExtraPraosEntropy,
    protocolParamMaxBlockBodySize,
    protocolParamMaxBlockExUnits,
    protocolParamMaxBlockHeaderSize,
    protocolParamMaxCollateralInputs,
    protocolParamMaxTxExUnits,
    protocolParamMaxTxSize,
    protocolParamMaxValueSize,
    protocolParamMinPoolCost,
    protocolParamMinUTxOValue,
    protocolParamMonetaryExpansion,
    protocolParamPoolPledgeInfluence,
    protocolParamPoolRetireMaxEpoch,
    protocolParamPrices,
    protocolParamProtocolVersion,
    protocolParamStakeAddressDeposit,
    protocolParamStakePoolDeposit,
    protocolParamStakePoolTargetNum,
    protocolParamTreasuryCut,
    protocolParamTxFeeFixed,
    protocolParamTxFeePerByte,
    protocolParamUTxOCostPerWord
  ),
 )
import Data.Bifunctor (second)
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LC8
import Data.Functor ((<&>))
import Data.Kind (Type)
import Data.Map.Strict qualified as Map.Strict
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (Status (Status))
import Network.Wai.Handler.Warp (Port)
import Network.Wai.Handler.Warp qualified as Warp
import Ogmios.Parser (decodeProtocolParameters)
import Plutus.V1.Ledger.Api qualified as Ledger
import Servant.Client (
  BaseUrl (baseUrlPort),
  ClientEnv,
  ClientError (FailureResponse),
  ClientM,
  ResponseF (Response),
  mkClientEnv,
  parseBaseUrl,
  runClientM,
 )
import Test.Hspec (
  ActionWith,
  Spec,
  around,
  context,
  describe,
  hspec,
  it,
  runIO,
  shouldBe,
  shouldSatisfy,
 )
import Test.Hspec.Core.Spec (SpecM)
import Types (
  AppliedScript (AppliedScript),
  ApplyArgsRequest (ApplyArgsRequest, args, script),
  Cbor (Cbor),
  Env (Env),
  Fee (Fee),
  FeesRequest (FeesRequest),
  ServerOptions (
    ServerOptions,
    networkId,
    nodeSocket,
    ogmiosHost,
    ogmiosPort,
    port
  ),
  WitnessCount (WitnessCount),
  unsafeDecode,
 )

main :: IO ()
main = hspec serverSpec

serverSpec :: Spec
serverSpec = do
  describe "Api.Handlers.applyArgs" applyArgsSpec
  describe "Api.Handlers.estimateTxFees" feeEstimateSpec
  describe "Ogmios.Parser " testParser

applyArgsSpec :: Spec
applyArgsSpec = around withTestApp $ do
  clientEnv <- setupClientEnv

  context "POST apply-args" $ do
    it "returns the same script when called without args" $ \port -> do
      result <-
        runClientM' (clientEnv port) $
          applyArgs unappliedRequestFixture
      result `shouldBe` Right (AppliedScript unappliedScript)

    it "returns the correct partially applied Plutus script" $ \port -> do
      result <-
        runClientM' (clientEnv port) $
          applyArgs partiallyAppliedRequestFixture
      result `shouldBe` Right (AppliedScript partiallyAppliedScript)

    it "returns the correct fully applied Plutus script" $ \port -> do
      result <-
        runClientM' (clientEnv port) $
          applyArgs fullyAppliedRequestFixture
      result `shouldBe` Right (AppliedScript fullyAppliedScript)

feeEstimateSpec :: Spec
feeEstimateSpec = around withTestApp $ do
  clientEnv <- setupClientEnv

  context "GET fees" $ do
    it "estimates the correct fee" $ \port -> do
      result <-
        runClientM' (clientEnv port) . estimateTxFees $
          FeesRequest (WitnessCount 1) cborTxFixture
      result `shouldBe` Right (Fee 168625)

    it "catches invalid hex strings" $ \port -> do
      result <-
        runClientM' (clientEnv port)
          . estimateTxFees
          . FeesRequest (WitnessCount 1)
          $ Cbor "deadbeefq"
      result `shouldSatisfy` expectError 400 "invalid bytestring size"

    it "catches invalid CBOR-encoded transactions" $ \port -> do
      result <-
        runClientM' (clientEnv port)
          . estimateTxFees
          . FeesRequest (WitnessCount 1)
          $ Cbor "deadbeef"
      result
        `shouldSatisfy` expectError
          400
          "DecoderErrorDeserialiseFailure \"Shelley Tx\" \
          \(DeserialiseFailure 0 \"expected list len or indef\")"
  where
    expectError :: Int -> LC8.ByteString -> Either ClientError Fee -> Bool
    expectError code body = \case
      Left (FailureResponse _ (Response (Status scode _) _ _ sbody))
        | scode == code && sbody == body -> True
      _ -> False

setupClientEnv :: SpecM Port (Port -> ClientEnv)
setupClientEnv = do
  baseUrl <- runIO $ parseBaseUrl "http://localhost"
  manager <- runIO $ newManager defaultManagerSettings
  pure $
    let clientEnv port = mkClientEnv manager $ baseUrl {baseUrlPort = port}
     in clientEnv

withTestApp :: ActionWith (Port -> IO ())
withTestApp =
  Warp.testWithApplication $
    pure . app $
      Env serverOptions fixedProtocolParameters
  where
    serverOptions =
      ServerOptions
        { port = 8081
        , nodeSocket = "./.node/socket/node.socket"
        , networkId = C.Testnet (C.NetworkMagic 1097911063)
        , ogmiosHost = "localhost"
        , ogmiosPort = 1337
        }

runClientM' ::
  forall (a :: Type).
  ClientEnv ->
  ClientM a ->
  IO (Either ClientError a)
runClientM' = flip runClientM

-- This is a known-good 'Tx AlonzoEra'
cborTxFixture :: Cbor
cborTxFixture =
  Cbor $
    mconcat
      [ "84a500818258205d677265fa5bb21ce6d8c7502aca70b9316d10e958611f3c6b758f65a"
      , "d959996000d818258205d677265fa5bb21ce6d8c7502aca70b9316d10e958611f3c6b75"
      , "8f65ad95999600018282581d600f45aaf1b2959db6e5ff94dbb1f823bf257680c3c723a"
      , "c2d49f975461a0023e8fa82581d60981fc565bcf0c95c0cfa6ee6693875b60d529d87ed"
      , "7082e9bf03c6a41a000f4240021a0002b5690e81581c0f45aaf1b2959db6e5ff94dbb1f"
      , "823bf257680c3c723ac2d49f97546a10081825820096092b8515d75c2a2f75d6aa7c519"
      , "1996755840e81deaa403dba5b690f091b6584063721fd9360d569968defac287e76cfaa"
      , "767366ecf6709b8354e02e2df6c35d78453adb04ec76f8a3d1287468b8c244ff051dcd0"
      , "f29dbcac1f7baf3e2d06ce06f5f6"
      ]

unappliedRequestFixture :: ApplyArgsRequest
unappliedRequestFixture =
  ApplyArgsRequest
    { script = unappliedScript
    , args = []
    }

partiallyAppliedRequestFixture :: ApplyArgsRequest
partiallyAppliedRequestFixture = unappliedRequestFixture {args = [Ledger.I 32]}

fullyAppliedRequestFixture :: ApplyArgsRequest
fullyAppliedRequestFixture =
  unappliedRequestFixture
    { args =
        [ Ledger.I 32
        , Ledger.B "test"
        ]
    }

-- mkTestValidator :: Integer -> CurrencySymbol -> BuiltinData -> BuiltinData -> BuiltinData -> ()
-- mkTestValidator i (CurrencySymbol cs) _ _ _ =
--   if i P.== 1 && cs P.== "" then () else P.error ()

-- mkTestValidatorUntyped :: BuiltinData -> BuiltinData -> BuiltinData -> BuiltinData -> BuiltinData -> ()
-- mkTestValidatorUntyped p1 p2 =
--   mkTestValidator
--     (unsafeFromBuiltinData p1)
--     (unsafeFromBuiltinData p2)

-- unappliedScript :: Script
-- unappliedScript =
--   fromCompiledCode
--     $$(PlutusTx.compile [||mkTestValidatorUntyped||])
unappliedScript :: Ledger.Script
unappliedScript =
  unsafeDecode
    "Script"
    "\"586f010000333222323233222233222225335300c33225335300e0021001100f333500b\
    \22333573466e1c00800404003c0152002333500b22333573466e3c00800404003c0112201\
    \0010091326353008009498cd4015d680119a802bae0011200120011200112001122002122\
    \001200101\""

-- partiallyAppliedScript :: Integer -> Script
-- partiallyAppliedScript i =
--   fromCompiledCode
--     ( $$(PlutusTx.compile [||mkTestValidatorUntyped||])
--         `PlutusTx.applyCode` PlutusTx.liftCode (PlutusTx.toBuiltinData i)
--     )
-- Script applied with (I 32)
partiallyAppliedScript :: Ledger.Script
partiallyAppliedScript =
  unsafeDecode
    "Script"
    "\"58750100003333222323233222233222225335300c33225335300e0021001100f333500\
    \b22333573466e1c00800404003c0152002333500b22333573466e3c00800404003c011221\
    \0010091326353008009498cd4015d680119a802bae0011200120011200112001122002122\
    \00120014c010218200001\""

-- fullyAppliedScript :: Integer -> CurrencySymbol -> Script
-- fullyAppliedScript i b =
--   getValidator $
--     mkValidatorScript
--       ( $$(PlutusTx.compile [||mkTestValidatorUntyped||])
--           `PlutusTx.applyCode` PlutusTx.liftCode (PlutusTx.toBuiltinData i)
--           `PlutusTx.applyCode` PlutusTx.liftCode (PlutusTx.toBuiltinData b)
--       )
-- Script applied with (I 32) (B "test")
fullyAppliedScript :: Ledger.Script
fullyAppliedScript =
  unsafeDecode
    "Script"
    "\"587f01000033333222323233222233222225335300c33225335300e0021001100f33350\
    \0b22333573466e1c00800404003c0152002333500b22333573466e3c00800404003c01122\
    \010010091326353008009498cd4015d680119a802bae00112001200112001120011220021\
    \2200120014c01021820004c010544746573740001\""

fixedProtocolParameters :: ProtocolParameters
fixedProtocolParameters =
  ProtocolParameters
    { protocolParamProtocolVersion = (6, 0)
    , protocolParamDecentralization = 0
    , protocolParamExtraPraosEntropy = Nothing
    , protocolParamMaxBlockHeaderSize = 1100
    , protocolParamMaxBlockBodySize = 98304
    , protocolParamMaxTxSize = 16384
    , protocolParamTxFeeFixed = 155381
    , protocolParamTxFeePerByte = 44
    , protocolParamMinUTxOValue = Nothing
    , protocolParamStakeAddressDeposit = 2000000
    , protocolParamStakePoolDeposit = 500000000
    , protocolParamMinPoolCost = 340000000
    , protocolParamPoolRetireMaxEpoch = 18
    , protocolParamStakePoolTargetNum = 500
    , protocolParamPoolPledgeInfluence = 3 / 10
    , protocolParamMonetaryExpansion = 3 / 1000
    , protocolParamTreasuryCut = 1 / 5
    , protocolParamUTxOCostPerWord = Just $ Lovelace 34482
    , protocolParamCostModels = mempty
    , protocolParamPrices =
        Just $
          ExecutionUnitPrices
            { priceExecutionSteps = 721 / 10000000
            , priceExecutionMemory = 577 / 10000
            }
    , protocolParamMaxTxExUnits =
        Just $
          ExecutionUnits
            { executionSteps = 10000000000
            , executionMemory = 16000000
            }
    , protocolParamMaxBlockExUnits =
        Just $
          ExecutionUnits
            { executionSteps = 40000000000
            , executionMemory = 80000000
            }
    , protocolParamMaxValueSize = Just 5000
    , protocolParamCollateralPercent = Just 150
    , protocolParamMaxCollateralInputs = Just 3
    }

loadParametersFile :: IO (Either String ProtocolParameters)
loadParametersFile =
  LBS.readFile "test/ogmios.json"
    <&> decodeProtocolParameters

testParser :: Spec
testParser =
  it "Testing parser of ogmios parameters" $ do
    value <- loadParametersFile
    makeNullCostModels value `shouldBe` Right fixedProtocolParameters
    value `shouldSatisfy` isNotNullCostModels
  where
    makeNullCostModels ::
      Either String ProtocolParameters -> Either String ProtocolParameters
    makeNullCostModels =
      second
        (\v -> v {protocolParamCostModels = mempty})

    isNotNullCostModels ::
      Either String ProtocolParameters -> Bool
    isNotNullCostModels (Right parameters) =
      not . Map.Strict.null . protocolParamCostModels $ parameters
    isNotNullCostModels _ = False
