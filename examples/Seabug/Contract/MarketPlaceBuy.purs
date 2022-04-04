module Seabug.Contract.MarketPlaceBuy
  ( marketplaceBuy
  , mkMarketplaceTx
  ) where

import Contract.Prelude
import Contract.Address
  ( getNetworkId
  , ownPaymentPubKeyHash
  , payPubKeyHashBaseAddress
  )
import Contract.ScriptLookups
  ( mintingPolicy
  , otherScript
  , ownPaymentPubKeyHash
  , typedValidatorLookups
  , unspentOutputs
  ) as ScriptLookups
import Contract.Monad
  ( Contract
  , liftContractM
  , liftContractE'
  , liftedE'
  , liftedM
  )
import Contract.Numeric.Natural (toBigInt)
import Contract.PlutusData
  ( Datum(Datum)
  , Redeemer(Redeemer)
  , toData
  , unitRedeemer
  )
import Contract.Prim.ByteArray (byteArrayToHex)
import Contract.ProtocolParameters.Alonzo (minAdaTxOut)
import Contract.Scripts (typedValidatorEnterpriseAddress)
import Contract.Transaction
  ( TxOut
  , UnbalancedTx
  , balanceTx
  , finalizeTx
  )
import Contract.TxConstraints
  ( TxConstraints
  , mustMintValueWithRedeemer
  , mustPayToOtherScript
  , mustPayWithDatumToPubKey
  , mustSpendScriptOutput
  )
import Contract.Utxos (utxosAt)
import Contract.Value
  ( CurrencySymbol
  , TokenName
  , Value
  , coinToValue
  , lovelaceValueOf
  , mkSingletonValue'
  , scriptCurrencySymbol
  , valueOf
  )
import Data.Array (find) as Array
import Data.BigInt (BigInt, fromInt)
import Data.Map (insert, toUnfoldable)
import QueryM (FinalizedTransaction(FinalizedTransaction), datumHash)
import QueryM.Submit (submit)
import Seabug.MarketPlace (marketplaceValidator)
import Seabug.MintingPolicy (mintingPolicy)
import Seabug.Token (mkTokenName)
import Seabug.Types
  ( MarketplaceDatum(MarketplaceDatum)
  , MintAct(ChangeOwner)
  , NftData(NftData)
  , NftId(NftId)
  )
import Types.ScriptLookups (mkUnbalancedTx')
import Types.Transaction (Redeemer) as T

marketplaceBuy :: NftData -> Contract Unit
marketplaceBuy nftData = do
  { unbalancedTx, datums, redeemers } /\ curr /\ newName <-
    mkMarketplaceTx nftData
  -- Balance unbalanced tx:
  balancedTx <- liftedE' $ balanceTx unbalancedTx
  log "marketplaceBuy: Transaction successfully balanced"
  log $ show balancedTx
  -- Reattach datums and redeemer:
  FinalizedTransaction txCbor <-
    liftedM "marketplaceBuy: Cannot attach datums and redeemer"
      (finalizeTx balancedTx datums redeemers)
  log "marketplaceBuy: Datums and redeemer attached"
  -- Submit transaction:
  transactionHash <- wrap $ submit txCbor
  -- -- Submit balanced tx:
  log $ "marketplaceBuy: Transaction successfully submitted with hash: "
    <> show transactionHash
  log $ "marketplaceBuy: Buy successful: " <> show (curr /\ newName)

-- https://github.com/mlabs-haskell/plutus-use-cases/blob/927eade6aa9ad37bf2e9acaf8a14ae2fc304b5ba/mlabs/src/Mlabs/EfficientNFT/Contract/MarketplaceBuy.hs
-- rev: 2c9ce295ccef4af3f3cb785982dfe554f8781541
-- The `MintingPolicy` may be decoded as Json, although I'm not sure as we don't
-- have `mkMintingPolicyScript`. Otherwise, it's an policy that hasn't been
-- applied to arguments. See `Seabug.Token.policy`
mkMarketplaceTx
  :: NftData
  -> Contract
       ( { unbalancedTx :: UnbalancedTx
         , datums :: Array Datum
         , redeemers :: Array T.Redeemer
         } /\ CurrencySymbol /\ TokenName
       )
mkMarketplaceTx (NftData nftData) = do
  pkh <- liftedM "marketplaceBuy: Cannot get PaymentPubKeyHash"
    ownPaymentPubKeyHash
  policy <- liftedE' $ pure mintingPolicy
  curr <- liftedM "marketplaceBuy: Cannot get CurrencySymbol"
    (scriptCurrencySymbol policy)
  -- Read in the typed validator:
  marketplaceValidator' <- unwrap <$> liftContractE' marketplaceValidator
  networkId <- getNetworkId
  let
    nft = nftData.nftId
    nft' = unwrap nft
    newNft = NftId nft' { owner = pkh }
    scriptAddr =
      typedValidatorEnterpriseAddress networkId $ wrap marketplaceValidator'
  oldName <- liftedM "marketplaceBuy: Cannot hash old token" (mkTokenName nft)
  newName <- liftedM "marketplaceBuy: Cannot hash new token" (mkTokenName newNft)
  -- Eventually we'll have a non-CSL-Plutus-style `Value` so this will likely
  -- change:
  oldNftValue <- liftContractM "marketplaceBuy: Cannot create old NFT Value"
    (mkSingletonValue' curr oldName $ negate one)
  newNftValue <- liftContractM "marketplaceBuy: Cannot create new NFT Value"
    (mkSingletonValue' curr newName one)
  let
    nftPrice = nft'.price
    valHash = marketplaceValidator'.validatorHash
    mintRedeemer = Redeemer $ toData $ ChangeOwner nft pkh
    nftCollection = unwrap nftData.nftCollection

    containsNft :: forall (a :: Type). (a /\ TxOut) -> Boolean
    containsNft (_ /\ tx) = valueOf (unwrap tx).amount curr oldName == one

    getShare :: BigInt -> BigInt
    getShare share = (toBigInt nftPrice * share) `div` fromInt 10_000

    shareToSubtract :: BigInt -> BigInt
    shareToSubtract v
      | v < unwrap minAdaTxOut = zero
      | otherwise = v

    filterLowValue
      :: BigInt
      -> (Value -> TxConstraints Unit Unit)
      -> TxConstraints Unit Unit
    filterLowValue v t
      | v < unwrap minAdaTxOut = mempty
      | otherwise = t (lovelaceValueOf v)

    authorShare = getShare $ toBigInt nftCollection.authorShare
    daoShare = getShare $ toBigInt nftCollection.daoShare
    ownerShare = lovelaceValueOf
      $ toBigInt nftPrice
      - shareToSubtract authorShare
      - shareToSubtract daoShare
    datum = Datum $ toData $ curr /\ oldName
    userAddr = payPubKeyHashBaseAddress networkId pkh
  userUtxos <-
    liftedM "marketplaceBuy: Cannot get user Utxos" (utxosAt userAddr)
  scriptUtxos <-
    liftedM "marketplaceBuy: Cannot get script Utxos" (utxosAt scriptAddr)
  let utxo' = Array.find containsNft $ toUnfoldable (unwrap scriptUtxos)
  utxo /\ utxoIndex <-
    liftContractM "marketplaceBuy: NFT not found on marketplace" utxo'
  log "datumHashes"
  log =<< map (show <<< map (byteArrayToHex <<< unwrap)) (wrap $ datumHash datum)
  log =<< map (show <<< map (byteArrayToHex <<< unwrap)) (wrap $ datumHash $ ( Datum $ toData $
                  MarketplaceDatum { getMarketplaceDatum: curr /\ oldName }
              ))
  log =<< map (show <<< map (byteArrayToHex <<< unwrap)) (wrap $ datumHash $ ( Datum $ toData $
                  MarketplaceDatum { getMarketplaceDatum: curr /\ newName }
              ))
  let
    lookup = mconcat
      [ ScriptLookups.mintingPolicy policy
      , ScriptLookups.typedValidatorLookups $ wrap marketplaceValidator'
      , ScriptLookups.otherScript marketplaceValidator'.validator
      , ScriptLookups.unspentOutputs $ insert utxo utxoIndex (unwrap userUtxos)
      , ScriptLookups.ownPaymentPubKeyHash pkh
      ]
    constraints =
      filterLowValue
        daoShare
        (mustPayToOtherScript nftCollection.daoScript datum)
        <> filterLowValue
          authorShare
          (mustPayWithDatumToPubKey nftCollection.author datum)
        <> mconcat
          [ mustMintValueWithRedeemer mintRedeemer (newNftValue <> oldNftValue)
          , mustSpendScriptOutput utxo unitRedeemer
          , mustPayWithDatumToPubKey nft'.owner datum ownerShare
          , mustPayToOtherScript
              valHash
              ( Datum $ toData $
                  MarketplaceDatum { getMarketplaceDatum: curr /\ newName }
              )
              (newNftValue <> coinToValue minAdaTxOut)
          ]
  -- Created unbalanced tx which stripped datums and redeemers:
  txDatumsRedeemer <- liftedE' $ wrap (mkUnbalancedTx' lookup constraints)
  pure $ txDatumsRedeemer /\ curr /\ newName


-- (Transaction
--   { auxiliary_data: Nothing
--   , body:
--     (TxBody {
--       auxiliary_data_hash: Nothing,
--       certs: Nothing,
--       collateral: (Just [(TransactionInput
--         { index: 0u,
--           transaction_id: (TransactionHash (byteArrayFromIntArrayUnsafe
--             [180,118,245,6,211,153,203,40,137,14,84,193,134,206,114,200,197,202,79,101,208,187,247,156,184,125,64,75,98,49,68,156])) })]),
--       fee: (Coin fromString "1000517"),
--       inputs:
--         (TransactionInput {
--           index: 0u,
--           transaction_id:
--             (TransactionHash (byteArrayFromIntArrayUnsafe
--               [43,20,8,213,33,172,202,93,146,22,213,184,241,51,69,65,212,59,43,141,213,84,239,252,231,34,3,193,119,199,30,6])) }),
--         (TransactionInput {
--           index: 1u,
--           transaction_id: (TransactionHash (byteArrayFromIntArrayUnsafe
--             [25,239,161,222,238,219,30,111,72,190,245,138,170,170,65,197,120,116,169,65,206,255,108,69,224,120,154,24,181,223,156,26])) })],
--       mint: (Just (Mint (NonAdaAsset(fromFoldable [(Tuple
--         (CurrencySymbol(byteArrayFromIntArrayUnsafe
--           [112,64,99,103,48,231,58,234,5,76,11,45,208,183,52,190,195,236,170,202,30,60,190,72,180,130,202,20]))
--             (fromFoldable
--               [(Tuple (TokenName(byteArrayFromIntArrayUnsafe
--                 [65,162,33,93,139,129,115,44,40,195,210,64,108,84,6,20,181,35,64,20,213,93,161,7,113,45,189,216,12,228,122,146])) fromString "1"),
--                (Tuple (TokenName(byteArrayFromIntArrayUnsafe
--                 [216,80,215,167,15,213,255,151,171,16,75,18,125,76,150,48,198,77,138,193,88,161,76,220,196,246,81,87,183,154,240,186])) fromString "-1")]))])))), 
--       network_id: (Just TestnetId),
--       outputs: [
--         (TransactionOutput {
--           address: (Address addr_test1qpkl55y6av6lvu9gfjkqr0cmtkxn7qcezgg0q3vr0m2huda6qh8x3elu6qa9t48ymn0dluh805ws2we38uxwxcnzyygq5jl946),
--           amount: (Value
--             (Coin fromString "1889915275")
--             (NonAdaAsset(fromFoldable [(Tuple
--               (CurrencySymbol(byteArrayFromIntArrayUnsafe
--                 [112,64,99,103,48,231,58,234,5,76,11,45,208,183,52,190,195,236,170,202,30,60,190,72,180,130,202,20]))
--                   (fromFoldable [(Tuple (TokenName(byteArrayFromIntArrayUnsafe
--                     [216,80,215,167,15,213,255,151,171,16,75,18,125,76,150,48,198,77,138,193,88,161,76,220,196,246,81,87,183,154,240,186])) fromString "0")]))]))),
--           data_hash: Nothing }),
--         (TransactionOutput {
--           address: (Address addr_test1wr05mmuhd3nvyjan9u4a7c76gj756am40qg7vuz90vnkjzczfulda),
--           amount:
--             (Value (Coin fromString "2000000")
--             (NonAdaAsset(fromFoldable [(Tuple (CurrencySymbol(byteArrayFromIntArrayUnsafe
--               [112,64,99,103,48,231,58,234,5,76,11,45,208,183,52,190,195,236,170,202,30,60,190,72,180,130,202,20]))
--                 (fromFoldable [(Tuple (TokenName(byteArrayFromIntArrayUnsafe
--                   [65,162,33,93,139,129,115,44,40,195,210,64,108,84,6,20,181,35,64,20,213,93,161,7,113,45,189,216,12,228,122,146])) fromString "1")]))]))),
--           data_hash: (Just (DataHash (byteArrayFromIntArrayUnsafe
--             [88,32,110,42,33,197,28,183,133,40,23,24,167,223,164,5,59,149,56,178,233,123,217,61,52,139,40,75,0,143,223,27,171,0]))) }),
--         (TransactionOutput {
--           address: (Address addr_test1vqlnger9p044xfxsu337h6qlhc0a2xdkgwzjr6tdp56m6agyumjux),
--           amount:
--             (Value (Coin fromString "85000000")
--             (NonAdaAsset(fromFoldable []))),
--           data_hash: (Just (DataHash (byteArrayFromIntArrayUnsafe
--             [88,32,150,29,126,189,56,59,239,17,110,249,188,181,39,241,188,26,69,135,248,25,212,236,14,114,63,239,90,178,40,173,29,143]))) }),
--         (TransactionOutput {
--           address: (Address addr_test1vqlnger9p044xfxsu337h6qlhc0a2xdkgwzjr6tdp56m6agyumjux),
--           amount:
--             (Value (Coin fromString "10000000")
--             (NonAdaAsset(fromFoldable []))),
--           data_hash:
--             (Just (DataHash (byteArrayFromIntArrayUnsafe
--               [88,32,150,29,126,189,56,59,239,17,110,249,188,181,39,241,188,26,69,135,248,25,212,236,14,114,63,239,90,178,40,173,29,143]))) }),
--         (TransactionOutput {
--           address: (Address addr_test1wzw637nk52s02249mug0k7uplxh7fvswjp5t872l4hr5w7se4c6r0),
--           amount:
--             (Value (Coin fromString "5000000")
--             (NonAdaAsset(fromFoldable []))),
--           data_hash:
--             (Just (DataHash (byteArrayFromIntArrayUnsafe
--               [88,32,150,29,126,189,56,59,239,17,110,249,188,181,39,241,188,26,69,135,248,25,212,236,14,114,63,239,90,178,40,173,29,143]))) })],
--       required_signers: Nothing,
--       script_data_hash: Nothing,
--       ttl: Nothing,
--       update: Nothing,
--       validity_start_interval: Nothing,
--       withdrawals: Nothing }),
--   is_valid: true,
--   witness_set:
--     (TransactionWitnessSet {
--       bootstraps: Nothing,
--       native_scripts: Nothing,
--       plutus_data: Nothing,
--       plutus_scripts:
--         (Just
--         [(PlutusScript (byteArrayFromIntArrayUnsafe
--           [89,19,96,1,0,0,51,51,51,50,50,51,50,34,50,50,50,50,51,34,50,51,34,50,50,51,34,50,50,50,51,50,34,51,50,34,51,50,34,51,34,50,51,50,34,50,50,50,50,51,34,50,51,51,50,34,34,50,50,51,51,51,51,34,34,34,34,51,51,34,34,51,34,51,34,51,34,51,34,51,34,51,34,51,34,51,34,50,50,50,50,50,50,50,50,50,50,50,50,50,50,50,51,51,50,34,34,51,34,34,34,34,35,35,35,35,35,34,50,50,83,53,48,111,51,34,50,50,50,50,50,50,50,53,48,47,53,48,25,0,130,32,2,34,34,34,34,34,50,51,51,83,5,128,20,37,51,83,8,64,21,51,83,8,64,19,51,83,6,65,32,1,34,53,53,80,67,0,34,35,83,85,4,80,3,34,83,53,48,138,1,51,7,176,4,0,33,51,7,160,3,0,17,8,176,19,53,6,99,53,80,66,48,97,0,19,55,2,16,32,41,0,18,131,58,153,169,168,53,152,7,128,17,8,0,137,147,26,152,61,153,171,156,73,1,11,117,110,114,101,97,99,104,97,98,108,101,0,7,192,122,16,134,1,19,53,115,137,33,18,78,70,84,32,109,117,115,116,32,98,101,32,98,117,114,110,101,100,0,8,80,17,83,53,48,132,1,83,53,48,132,1,51,3,165,1,19,83,7,224,1,34,32,1,16,134,1,19,53,115,137,33,31,79,119,110,101,114,32,109,117,115,116,32,115,105,103,110,32,116,104,101,32,116,114,97,110,115,97,99,116,105,111,110,0,8,80,17,83,53,48,132,1,51,53,83,5,129,32,1,53,5,229,7,98,83,53,48,133,1,83,53,48,133,1,51,6,147,83,4,0,1,34,32,3,51,6,179,7,48,36,80,109,16,134,1,16,135,1,19,51,87,52,102,225,204,204,14,141,76,16,0,4,136,128,8,9,77,76,31,192,8,136,128,13,32,2,8,112,16,134,1,16,134,1,53,48,59,80,17,34,34,34,34,34,0,145,8,96,17,51,87,56,146,1,31,85,110,100,101,114,108,121,105,110,103,32,78,70,84,32,109,117,115,116,32,98,101,32,117,110,108,111,99,107,101,100,0,8,80,17,8,80,17,8,80,18,50,50,50,50,50,37,51,83,8,160,21,51,83,8,160,19,51,1,48,7,53,48,132,1,0,114,34,0,32,1,16,140,1,19,53,115,137,33,62,69,120,97,99,116,108,121,32,111,110,101,32,110,101,119,32,116,111,107,101,110,32,109,117,115,116,32,98,101,32,109,105,110,116,101,100,32,97,110,100,32,101,120,97,99,116,108,121,32,111,110,101,32,111,108,100,32,98,117,114,110,116,0,8,176,17,83,53,48,138,1,83,53,48,138,1,51,0,85,0,51,48,112,48,120,2,101,7,33,83,53,48,138,1,51,0,85,0,35,48,112,48,121,2,133,7,33,51,53,83,5,225,32,1,53,6,69,7,195,48,6,51,7,3,7,147,83,8,64,16,7,34,32,1,80,114,51,112,38,110,5,64,16,194,36,5,64,8,194,36,5,64,13,64,88,66,44,4,66,44,4,66,48,4,76,213,206,36,129,19,82,111,121,97,108,105,116,105,101,115,32,110,111,116,32,112,97,105,100,0,8,176,17,8,176,17,51,112,102,110,9,64,8,9,82,10,9,192,17,51,112,102,110,9,64,4,8,146,10,9,192,17,53,48,128,1,0,50,34,0,34,37,51,83,8,112,19,51,87,52,102,226,0,8,34,128,66,36,4,34,0,68,34,64,68,204,213,76,22,196,128,4,212,24,84,30,76,192,12,0,64,9,64,76,136,141,76,16,128,4,136,148,205,76,34,128,76,193,184,1,128,12,84,205,76,34,128,76,205,92,209,155,135,0,83,51,3,240,2,6,128,104,8,192,16,139,1,21,51,83,80,113,83,53,53,7,16,1,33,50,53,48,67,0,18,34,34,34,34,37,51,83,80,125,51,53,83,6,161,32,1,80,105,35,83,85,5,64,1,34,83,53,48,153,1,51,53,115,70,110,60,0,128,60,38,192,66,104,4,77,66,8,4,0,197,66,4,4,0,136,77,66,0,4,212,213,65,80,0,72,128,4,84,31,148,6,5,65,200,132,200,204,213,205,25,186,240,2,0,16,142,1,8,208,19,35,83,85,4,144,1,34,51,116,169,0,1,154,186,3,117,32,4,102,174,128,221,72,0,155,177,8,64,19,53,80,73,80,26,48,104,0,129,8,176,17,8,176,17,8,176,18,37,51,83,8,80,21,51,83,8,80,19,51,0,224,2,0,19,83,7,240,2,34,32,1,16,135,1,19,53,115,137,33,62,69,120,97,99,116,108,121,32,111,110,101,32,110,101,119,32,116,111,107,101,110,32,109,117,115,116,32,98,101,32,109,105,110,116,101,100,32,97,110,100,32,101,120,97,99,116,108,121,32,111,110,101,32,111,108,100,32,98,117,114,110,116,0,8,96,17,83,53,48,133,1,51,3,181,1,35,83,7,240,2,34,32,1,16,135,1,19,53,115,137,33,31,79,119,110,101,114,32,109,117,115,116,32,115,105,103,110,32,116,104,101,32,116,114,97,110,115,97,99,116,105,111,110,0,8,96,17,8,96,18,83,53,48,132,1,83,53,48,132,1,83,53,53,6,85,51,83,80,107,48,18,0,34,16,1,19,38,53,48,123,51,87,56,146,1,11,117,110,114,101,97,99,104,97,98,108,101,0,7,192,122,16,133,1,34,19,83,85,4,48,2,34,83,53,53,6,144,3,21,51,83,8,128,19,51,87,52,102,227,192,8,193,148,1,66,40,4,34,64,68,204,213,205,25,184,112,1,72,0,130,40,4,34,64,68,34,64,72,132,34,192,68,33,128,68,205,92,226,73,30,69,120,97,99,116,108,121,32,111,110,101,32,78,70,84,32,109,117,115,116,32,98,101,32,109,105,110,116,101,100,0,8,80,17,83,53,48,132,1,51,53,83,5,129,32,1,53,5,229,7,98,83,53,48,133,1,51,6,147,83,4,0,1,34,32,3,51,6,179,7,48,36,80,109,19,51,87,52,102,225,204,204,14,141,76,16,0,4,136,128,8,9,77,76,31,192,8,136,128,13,32,2,8,112,16,134,1,16,134,1,53,48,59,80,17,34,34,34,34,34,0,145,8,96,17,51,87,56,146,1,29,85,110,100,101,114,108,121,105,110,103,32,78,70,84,32,109,117,115,116,32,98,101,32,108,111,99,107,101,100,0,8,80,17,8,80,19,83,3,149,0,242,34,34,34,34,32,7,35,34,35,37,51,83,80,99,83,53,53,6,51,0,99,83,3,53,0,146,34,34,34,34,32,7,33,53,6,96,1,21,6,66,21,51,83,80,94,0,17,7,226,33,53,53,80,60,0,34,37,51,83,80,98,0,49,8,32,18,33,53,53,80,64,0,34,37,51,83,80,102,0,49,83,53,48,133,1,83,53,48,133,1,51,7,96,6,80,13,19,48,118,0,37,0,161,8,96,17,83,53,48,133,1,51,53,115,70,110,28,1,82,0,16,135,1,8,96,17,51,53,115,70,110,28,0,82,0,32,135,1,8,96,17,8,96,17,83,53,48,133,1,83,53,48,133,1,51,7,96,2,80,13,19,48,118,0,101,0,161,8,96,17,83,53,48,133,1,51,53,115,70,110,28,0,82,0,16,135,1,8,96,17,51,53,115,70,110,28,1,82,0,32,135,1,8,96,17,8,96,17,8,96,18,33,8,128,17,7,209,48,88,53,48,117,0,66,34,51,48,121,0,48,5,0,65,48,85,0,19,32,1,53,80,122,34,83,53,53,5,144,1,21,6,2,33,53,53,80,55,0,34,37,51,83,7,195,48,109,0,37,0,177,53,6,80,1,19,0,96,3,50,0,19,85,7,146,37,51,83,80,88,0,17,80,95,34,19,83,85,3,96,2,34,83,53,48,123,51,6,192,2,80,10,19,80,100,0,17,48,6,0,49,53,48,43,80,1,34,34,34,34,34,0,145,53,48,20,0,50,32,2,50,0,19,85,7,98,37,51,83,80,85,0,17,80,92,34,19,83,85,3,48,2,34,83,53,48,120,51,6,144,2,80,7,19,80,97,0,17,48,6,0,49,53,48,18,0,18,35,51,53,48,22,0,18,50,99,83,6,179,53,115,137,33,2,76,104,0,6,192,106,32,1,35,38,53,48,107,51,87,56,146,1,2,76,104,0,6,192,106,35,38,53,48,107,51,87,56,146,1,2,76,104,0,6,192,106,51,51,87,52,102,225,212,1,18,0,2,48,70,48,101,80,6,35,51,53,115,70,110,29,64,21,32,6,35,4,163,6,101,0,114,51,51,87,52,102,225,212,1,146,0,34,51,4,147,6,117,0,131,6,229,0,146,51,51,87,52,102,225,212,1,210,0,66,51,4,179,6,133,0,147,117,202,1,68,100,198,166,13,70,106,231,1,176,26,193,164,26,1,156,25,129,148,204,205,92,209,155,135,53,87,58,160,4,144,0,17,152,9,25,25,25,25,25,25,25,25,25,25,25,25,153,171,154,51,112,230,170,231,84,2,146,0,2,51,51,51,51,51,3,67,53,2,66,50,50,51,51,87,52,102,225,205,85,206,168,1,36,0,4,102,7,70,5,166,174,133,64,8,192,164,213,208,154,186,37,0,34,50,99,83,7,115,53,115,128,242,15,0,236,14,162,106,174,121,64,4,77,213,0,9,171,161,80,10,51,80,36,2,83,87,66,160,18,102,106,160,78,235,148,9,141,93,10,128,65,153,170,129,59,174,80,38,53,116,42,0,230,106,4,128,90,106,232,84,1,140,212,9,12,213,64,192,11,157,105,171,161,80,5,50,50,50,51,51,87,52,102,225,205,85,206,168,1,36,0,4,102,160,132,100,100,100,102,102,174,104,205,195,154,171,157,80,2,72,0,8,205,65,40,205,64,205,214,154,186,21,0,35,3,67,87,66,106,232,148,0,136,201,141,76,30,204,213,206,3,232,62,3,208,60,137,170,185,229,0,17,55,84,0,38,174,133,64,8,200,200,200,204,205,92,209,155,135,53,87,58,160,4,144,0,17,154,130,65,154,129,155,173,53,116,42,0,70,6,134,174,132,213,209,40,1,17,147,26,152,61,153,171,156,7,208,124,7,160,121,19,85,115,202,0,34,110,168,0,77,93,9,171,162,80,2,35,38,53,48,119,51,87,56,15,32,240,14,192,234,38,170,231,148,0,68,221,80,0,154,186,21,0,67,53,2,71,92,106,232,84,0,204,212,9,12,213,64,193,215,16,0,154,186,21,0,35,2,163,87,66,106,232,148,0,136,201,141,76,28,204,213,206,3,168,58,3,144,56,137,171,162,80,1,19,87,68,160,2,38,174,137,64,4,77,93,18,128,8,154,186,37,0,17,53,116,74,0,34,106,232,148,0,68,213,209,40,0,137,170,185,229,0,17,55,84,0,38,174,133,64,8,200,200,200,204,205,92,209,155,135,80,1,72,1,136,192,108,192,148,213,208,154,171,158,80,3,35,51,53,115,70,110,29,64,9,32,4,35,1,163,2,115,87,66,106,174,121,64,16,140,204,213,205,25,184,117,0,52,128,8,140,6,140,8,205,93,9,170,185,229,0,82,51,51,87,52,102,225,212,1,18,0,2,48,29,55,92,106,232,77,85,207,40,3,17,147,26,152,55,25,171,156,7,0,111,6,208,108,6,176,106,6,145,53,87,58,160,2,38,234,128,4,213,208,154,186,37,0,34,50,99,83,6,115,53,115,128,210,13,0,204,12,162,12,226,100,198,166,12,198,106,231,18,65,3,80,84,53,0,6,112,101,19,85,115,202,0,34,110,168,0,68,213,92,234,128,32,154,186,21,0,33,53,116,38,174,137,64,4,77,85,207,40,0,137,186,160,1,34,18,51,0,16,3,0,34,0,18,18,34,35,0,64,5,33,34,34,48,3,0,82,18,34,35,0,32,5,33,34,34,48,1,0,82,0,17,35,34,48,2,55,88,0,38,64,2,106,160,186,68,102,102,170,231,192,4,148,15,200,205,64,248,192,16,213,208,128,17,128,25,171,162,0,32,83,35,35,35,35,51,53,115,70,110,28,213,92,234,128,26,64,0,70,102,3,6,70,70,70,102,106,230,140,220,57,170,185,213,0,36,128,0,140,193,24,192,76,213,208,168,1,25,168,6,0,145,171,161,53,116,74,0,68,100,198,166,10,230,106,231,1,100,22,1,88,21,68,213,92,242,128,8,155,170,0,19,87,66,160,6,102,106,160,14,235,148,1,141,93,10,128,17,154,128,67,174,53,116,38,174,137,64,8,140,152,212,193,76,205,92,224,42,130,160,41,2,136,154,186,37,0,17,53,87,60,160,2,38,234,128,4,76,213,64,5,215,58,209,18,35,34,48,2,55,86,0,38,64,2,106,160,182,68,100,102,102,170,231,192,8,148,15,136,205,64,244,205,84,6,76,1,141,85,206,168,1,24,2,154,171,158,80,2,48,4,53,116,64,6,10,66,106,232,64,4,72,140,140,140,204,213,205,25,184,117,0,20,128,0,141,65,8,192,20,213,208,154,171,158,80,3,35,51,53,115,70,110,29,64,9,32,2,37,4,34,50,99,83,5,19,53,115,128,166,10,64,160,9,224,156,38,170,231,84,0,68,221,80,0,145,145,145,153,154,185,163,55,14,106,174,117,64,9,32,0,35,48,23,48,5,53,116,42,0,70,235,77,93,9,171,162,80,2,35,38,53,48,78,51,87,56,10,0,158,9,160,152,38,170,231,148,0,68,221,80,0,145,145,153,154,185,163,55,14,106,174,117,64,5,32,0,35,117,198,174,132,213,92,242,128,17,25,49,169,130,97,154,185,192,78,4,208,75,4,161,55,84,0,34,68,100,100,102,102,174,104,205,195,168,0,164,0,132,160,60,70,102,106,230,140,220,58,128,18,64,4,70,160,66,96,12,106,232,77,85,207,40,2,17,153,154,185,163,55,14,160,6,144,0,18,129,9,25,49,169,130,121,154,185,192,81,5,0,78,4,208,76,4,177,53,87,58,160,2,38,234,128,4,140,140,204,213,205,25,184,117,0,20,128,8,129,84,140,204,213,205,25,184,117,0,36,128,0,129,84,140,152,212,193,44,205,92,224,38,130,96,37,2,72,36,9,170,185,211,117,64,2,70,70,70,70,70,70,102,106,230,140,220,58,128,10,64,24,64,72,70,102,106,230,140,220,58,128,18,64,20,64,76,70,102,106,230,140,220,58,128,26,64,16,70,96,72,110,184,213,208,168,2,155,173,53,116,38,174,137,64,20,140,204,213,205,25,184,117,0,68,128,24,140,192,152,221,113,171,161,80,7,55,92,106,232,77,93,18,128,57,25,153,171,154,51,112,234,0,169,0,33,25,129,89,128,97,171,161,80,9,55,92,106,232,77,93,18,128,73,25,153,171,154,51,112,234,0,201,0,17,24,22,152,6,154,186,19,85,115,202,1,100,102,102,174,104,205,195,168,3,164,0,4,96,88,96,28,106,232,77,85,207,40,6,17,147,26,152,41,153,171,156,5,80,84,5,32,81,5,0,79,4,224,77,4,192,75,19,85,115,170,0,130,106,174,121,64,12,77,85,207,40,1,9,170,185,229,0,17,55,84,0,36,100,100,100,100,102,102,174,104,205,195,168,0,164,0,68,102,96,126,110,180,213,208,168,2,27,173,53,116,42,0,102,235,77,93,9,171,162,80,3,35,51,53,115,70,110,29,64,9,32,0,35,4,19,0,131,87,66,106,174,121,64,24,140,152,212,193,48,205,92,224,39,2,104,37,130,80,36,137,170,185,213,0,49,53,116,74,0,34,106,174,121,64,4,77,213,0,9,25,25,25,153,171,154,51,112,234,0,41,0,17,24,31,155,174,53,116,38,170,231,148,0,200,204,205,92,209,155,135,80,2,72,0,8,193,4,221,113,171,161,53,87,60,160,8,70,76,106,96,146,102,174,112,18,193,40,18,1,28,17,132,213,92,234,128,8,155,170,0,17,18,34,50,50,51,51,87,52,102,225,205,85,206,168,1,36,0,4,102,170,2,6,0,198,174,133,64,8,192,20,213,208,154,186,37,0,34,50,99,83,4,147,53,115,128,150,9,64,144,8,226,106,174,121,64,4,77,213,0,9,17,25,25,24,0,128,41,144,0,154,168,41,145,25,169,168,25,0,10,64,0,68,106,106,160,32,0,68,74,102,166,10,166,102,174,104,205,199,128,16,4,130,184,43,9,128,56,0,137,128,48,1,153,0,9,170,130,145,17,154,154,129,136,0,164,0,4,70,166,170,1,224,4,68,166,106,96,168,102,106,230,140,220,120,1,0,56,43,2,168,128,8,152,3,0,25,17,169,128,24,1,17,17,17,17,17,41,154,154,129,233,153,170,152,21,9,0,10,129,73,41,154,152,43,153,154,185,163,55,30,1,128,2,11,32,176,38,160,128,0,34,160,126,0,100,32,178,32,174,68,68,68,68,68,36,102,102,102,102,102,0,32,22,1,64,18,1,0,14,0,192,10,0,128,6,0,68,0,36,66,70,96,2,0,96,4,64,2,68,66,70,102,0,32,8,0,96,4,64,2,34,68,36,102,0,32,6,0,66,36,0,36,66,70,96,2,0,96,4,64,2,36,66,70,96,2,0,96,4,36,0,34,68,36,102,0,32,6,0,66,64,2,36,66,70,96,2,0,96,4,36,0,34,66,68,70,0,96,8,34,68,64,4,34,68,64,2,36,0,36,36,68,68,68,96,14,1,4,66,68,68,68,70,96,12,1,32,16,66,68,68,68,70,0,160,16,36,68,68,68,0,130,68,68,68,64,6,68,36,68,68,68,102,0,64,18,1,4,66,68,68,68,70,96,2,1,32,16,64,2,38,106,1,36,74,102,166,160,44,0,68,32,6,32,2,160,42,100,0,38,170,6,4,66,36,68,166,106,106,2,64,2,38,166,160,24,0,100,64,2,68,38,102,166,160,28,0,164,64,4,96,8,0,70,102,170,96,14,36,0,32,10,0,128,2,66,68,68,96,8,0,164,66,68,68,102,0,96,12,0,164,66,68,68,102,0,64,12,0,164,36,68,70,0,32,10,64,2,36,102,160,6,68,102,106,106,3,128,6,68,0,64,4,0,38,166,160,52,0,36,64,2,36,66,70,96,2,0,96,4,36,0,36,110,80,204,213,76,0,196,128,5,197,0,17,153,17,152,1,25,27,148,51,2,80,1,0,83,83,2,0,3,34,32,2,51,0,35,114,134,166,4,0,6,68,64,2,102,0,70,229,13,76,8,0,12,136,128,12,0,84,1,148,1,210,33,0,50,0,19,85,2,82,33,18,34,83,53,53,0,112,1,16,2,34,19,48,5,0,35,51,85,48,7,18,0,16,5,0,64,1,50,0,19,85,2,66,33,34,37,51,83,80,6,0,33,83,53,53,0,96,1,16,39,34,16,40,34,21,51,83,80,8,0,49,2,130,33,83,53,48,41,51,0,112,4,0,33,51,53,48,9,18,0,16,7,0,48,1,16,42,17,34,0,33,34,18,35,48,1,0,64,3,18,0,18,35,83,0,48,2,34,53,48,5,0,50,35,35,53,48,16,0,82,51,83,1,16,4,37,51,83,2,83,51,87,52,102,227,192,8,0,64,156,9,133,64,12,64,152,128,152,140,212,192,68,1,8,9,137,76,212,192,148,204,213,205,25,184,240,2,0,16,39,2,97,80,3,16,38,21,51,83,80,9,0,50,21,51,83,80,10,0,34,19,53,48,14,0,34,51,83,0,240,2,35,53,48,19,0,34,51,83,1,64,2,35,48,25,0,32,1,32,41,35,53,48,20,0,34,2,146,51,1,144,2,0,18,34,2,146,34,51,83,1,16,4,32,41,34,37,51,83,2,163,51,87,52,102,225,192,24,0,192,176,10,197,76,212,192,168,204,213,205,25,184,112,5,0,32,44,2,177,51,1,160,4,0,17,2,177,2,177,2,65,83,53,53,0,144,1,33,2,65,2,66,33,35,48,1,0,48,2,32,1,18,18,35,0,32,3,17,34,0,17,32,1,33,34,48,2,0,50,34,18,35,51,0,16,5,0,64,3,32,1,33,34,48,2,0,50,18,35,0,16,3,32,1,34,51,53,115,70,110,28,0,128,4,5,0,76,136,204,213,205,25,184,240,2,0,16,19,1,33,51,80,2,34,83,53,48,16,0,33,1,33,0,16,15,18,33,35,48,1,0,48,2,18,0,18,50,50,50,51,51,87,52,102,225,205,85,206,168,1,164,0,4,102,96,22,110,184,213,208,168,1,152,6,26,186,21,0,35,117,198,174,132,213,209,40,1,17,147,26,152,3,153,171,156,0,144,8,0,96,5,19,87,68,160,2,38,170,231,148,0,68,221,80,0,164,194,64,2,64,2,146,1,3,80,84,49,0,34,33,35,51,0,16,4,0,48,2,32,1,35,37,51,83,0,99,51,87,52,102,226,20,0,64,12,2,0,28,88,84,0,68,221,104,0,164,0,6,64,2,106,160,12,68,74,102,166,0,166,102,174,104,205,196,0,18,65,0,8,0,224,12,38,110,44,0,128,4,76,192,12,205,193,128,18,65,0,8,102,226,204,220,48,1,36,16,0,128,2,74,102,166,0,70,102,174,104,205,196,0,8,2,128,32,1,138,64,0,32,2,36,64,4,36,64,2,64,2,144,64,73,122,0,136,145,145,128,8,0,145,25,128,25,128,16,1,0,10,69,28,207,12,28,191,71,83,127,35,143,117,111,193,190,25,26,191,118,0,158,25,136,145,0,146,24,76,75,127,0,72,129,28,108,16,57,182,151,59,176,231,173,66,222,91,22,166,145,237,227,224,38,92,213,140,175,7,15,241,94,243,0,72,129,28,63,52,100,101,11,235,83,36,208,228,99,235,232,31,190,31,213,25,182,67,133,33,233,109,13,53,189,117,0,72,52,3,210,33,28,157,168,250,118,162,160,245,42,165,223,16,251,123,129,249,175,228,178,14,144,104,179,249,95,173,199,71,122,0,72,58,1,193])),
--         (PlutusScript (byteArrayFromIntArrayUnsafe
--           [89,8,248,1,0,0,51,35,35,50,35,50,35,35,35,51,34,35,35,51,34,35,35,51,51,51,50,34,34,34,35,35,51,34,35,35,51,50,34,35,35,35,50,35,35,51,34,35,35,51,34,35,35,35,50,35,50,35,35,35,51,51,34,34,35,50,35,50,35,50,35,50,35,50,35,50,35,50,34,34,35,35,37,51,83,3,51,51,0,99,0,128,5,48,7,0,67,51,53,115,70,110,28,213,92,234,128,18,64,0,70,96,22,100,100,100,100,100,100,100,100,100,100,100,102,102,174,104,205,195,154,171,157,80,10,72,0,8,204,204,204,204,204,6,76,212,9,200,200,200,204,205,92,209,155,135,53,87,58,160,4,144,0,17,152,15,152,29,26,186,21,0,35,2,195,87,66,106,232,148,0,136,201,141,76,22,140,213,206,2,240,45,130,200,44,9,170,185,229,0,17,55,84,0,38,174,133,64,40,205,64,156,10,13,93,10,128,73,153,170,129,115,174,80,45,53,116,42,1,6,102,170,5,206,185,64,180,213,208,168,3,153,168,19,130,25,171,161,80,6,51,80,39,51,85,5,64,76,117,166,174,133,64,20,200,200,200,204,205,92,209,155,135,53,87,58,160,4,144,0,17,154,129,9,145,145,145,153,154,185,163,55,14,106,174,117,64,9,32,0,35,53,2,147,53,4,39,90,106,232,84,0,140,17,205,93,9,171,162,80,2,35,38,53,48,94,51,87,56,12,64,190,11,160,184,38,170,231,148,0,68,221,80,0,154,186,21,0,35,35,35,35,51,53,115,70,110,28,213,92,234,128,18,64,0,70,106,4,230,106,8,78,180,213,208,168,1,24,35,154,186,19,87,68,160,4,70,76,106,96,188,102,174,112,24,129,124,23,65,112,77,85,207,40,0,137,186,160,1,53,116,38,174,137,64,8,140,152,212,193,104,205,92,224,47,2,216,44,130,192,154,171,158,80,1,19,117,64,2,106,232,84,1,12,212,9,221,113,171,161,80,3,51,80,39,51,85,5,71,92,64,2,106,232,84,0,140,14,77,93,9,171,162,80,2,35,38,53,48,86,51,87,56,11,64,174,10,160,168,38,174,137,64,4,77,93,18,128,8,154,186,37,0,17,53,116,74,0,34,106,232,148,0,68,213,209,40,0,137,171,162,80,1,19,87,68,160,2,38,170,231,148,0,68,221,80,0,154,186,21,0,35,35,35,35,51,53,115,70,110,29,64,5,32,6,35,1,227,3,179,87,66,106,174,121,64,12,140,204,213,205,25,184,117,0,36,128,16,140,7,76,17,77,93,9,170,185,229,0,66,51,51,87,52,102,225,212,0,210,0,34,48,29,48,48,53,116,38,170,231,148,1,72,204,205,92,209,155,135,80,4,72,0,8,192,128,221,113,171,161,53,87,60,160,12,70,76,106,96,162,102,174,112,21,65,72,20,1,60,19,129,52,19,4,213,92,234,128,8,155,170,0,19,87,66,106,232,148,0,136,201,141,76,18,140,213,206,2,112,37,130,72,36,8,37,9,147,26,152,36,153,171,156,73,1,3,80,84,53,0,4,160,72,19,85,115,202,0,34,110,168,0,76,213,64,253,215,58,226,0,18,33,35,48,1,0,48,2,32,1,34,34,34,34,34,18,51,51,51,51,51,0,16,11,0,160,9,0,128,7,0,96,5,0,64,3,0,34,0,18,33,35,48,1,0,48,2,32,1,18,33,35,48,1,0,48,2,18,0,17,34,18,51,0,16,3,0,33,32,1,18,33,35,48,1,0,48,2,18,0,18,18,34,35,0,64,5,33,34,34,48,3,0,82,18,34,35,0,32,5,33,34,34,48,1,0,82,0,17,35,34,48,2,55,88,0,38,64,2,106,160,106,68,102,102,170,231,192,4,148,3,136,205,64,52,192,16,213,208,128,17,128,25,171,162,0,32,51,35,35,35,35,51,53,115,70,110,28,213,92,234,128,26,64,0,70,102,0,230,70,70,70,102,106,230,140,220,57,170,185,213,0,36,128,0,140,192,52,192,196,213,208,168,1,25,168,9,129,105,171,161,53,116,74,0,68,100,198,166,6,230,106,231,0,236,14,0,216,13,68,213,92,242,128,8,155,170,0,19,87,66,160,6,102,106,160,22,235,148,2,141,93,10,128,17,154,128,123,174,53,116,38,174,137,64,8,140,152,212,192,204,205,92,224,27,129,160,25,1,136,154,186,37,0,17,53,87,60,160,2,38,234,128,4,136,132,140,204,0,64,16,0,192,8,128,4,136,72,204,0,64,12,0,136,0,68,205,84,0,93,115,173,17,34,50,35,0,35,117,96,2,100,0,38,170,5,228,70,70,102,106,174,124,0,137,64,36,140,212,2,12,213,64,196,192,24,213,92,234,128,17,128,41,170,185,229,0,35,0,67,87,68,0,96,92,38,174,132,0,68,72,128,8,72,132,136,204,0,64,16,0,196,128,4,72,140,140,140,204,213,205,25,184,117,0,20,128,0,141,64,32,192,20,213,208,154,171,158,80,3,35,51,53,115,70,110,29,64,9,32,2,37,0,130,50,99,83,2,163,53,115,128,92,5,96,82,5,0,78,38,170,231,84,0,68,221,80,0,137,9,17,128,16,1,136,145,0,8,144,0,145,145,145,153,154,185,163,55,14,106,174,117,64,9,32,0,35,48,6,48,7,53,116,42,0,70,235,77,93,9,171,162,80,2,35,38,53,48,36,51,87,56,5,0,74,4,96,68,38,170,231,148,0,68,221,80,0,145,9,25,128,8,1,128,17,0,9,25,25,153,171,154,51,112,230,170,231,84,0,82,0,2,55,92,106,232,77,85,207,40,1,17,147,26,152,16,25,171,156,2,64,33,1,240,30,19,117,64,2,36,70,70,70,102,106,230,140,220,58,128,10,64,8,74,0,228,102,102,174,104,205,195,168,1,36,0,68,106,1,70,0,198,174,132,213,92,242,128,33,25,153,171,154,51,112,234,0,105,0,1,40,5,17,147,26,152,17,153,171,156,2,112,36,2,32,33,2,0,31,19,85,115,170,0,34,110,168,0,68,132,136,140,0,192,16,68,136,128,8,68,136,128,4,72,0,72,200,204,205,92,209,155,135,80,1,72,0,136,1,136,204,205,92,209,155,135,80,2,72,0,8,1,136,201,141,76,6,204,213,206,0,248,14,0,208,12,128,192,154,171,157,55,84,0,34,68,0,66,68,0,36,0,36,100,100,100,100,100,102,102,174,104,205,195,168,0,164,1,132,1,100,102,102,174,104,205,195,168,1,36,1,68,1,164,102,102,174,104,205,195,168,1,164,1,4,102,1,102,235,141,93,10,128,41,186,211,87,66,106,232,148,1,72,204,205,92,209,155,135,80,4,72,1,136,204,3,77,215,26,186,21,0,115,117,198,174,132,213,209,40,3,145,153,154,185,163,55,14,160,10,144,2,17,152,9,24,10,26,186,21,0,147,117,198,174,132,213,209,40,4,145,153,154,185,163,55,14,160,12,144,1,17,128,161,128,169,171,161,53,87,60,160,22,70,102,106,230,140,220,58,128,58,64,0,70,2,102,2,198,174,132,213,92,242,128,97,25,49,169,129,1,154,185,192,36,2,16,31,1,224,29,1,192,27,1,160,25,1,129,53,87,58,160,8,38,170,231,148,0,196,213,92,242,128,16,154,171,158,80,1,19,117,64,2,66,68,68,68,70,0,224,16,68,36,68,68,68,102,0,192,18,1,4,36,68,68,68,96,10,1,2,68,68,68,64,8,36,68,68,68,0,100,66,68,68,68,70,96,4,1,32,16,68,36,68,68,68,102,0,32,18,1,4,0,36,100,100,100,100,102,102,174,104,205,195,168,0,164,0,68,102,96,16,110,180,213,208,168,2,27,173,53,116,42,0,102,235,77,93,9,171,162,80,3,35,51,53,115,70,110,29,64,9,32,0,35,0,163,0,179,87,66,106,174,121,64,24,140,152,212,192,68,205,92,224,10,128,144,8,0,120,7,9,170,185,213,0,49,53,116,74,0,34,106,174,121,64,4,77,213,0,9,9,17,128,16,1,145,16,145,25,152,0,128,40,2,0,25,0,9,25,25,25,153,171,154,51,112,234,0,41,0,17,24,3,27,174,53,116,38,170,231,148,0,200,204,205,92,209,155,135,80,2,72,0,8,192,32,221,113,171,161,53,87,60,160,8,70,76,106,96,22,102,174,112,3,192,48,2,128,36,2,4,213,92,234,128,8,155,170,0,18,18,35,0,32,3,33,34,48,1,0,50,0,17,18,34,50,50,51,51,87,52,102,225,205,85,206,168,1,36,0,4,102,170,1,102,0,198,174,133,64,8,192,20,213,208,154,186,37,0,34,50,99,83,0,131,53,115,128,24,1,32,14,0,194,106,174,121,64,4,77,213,0,10,76,36,0,36,0,34,36,66,70,96,2,0,96,4,34,64,2,146,1,3,80,84,49,0,17,35,35,0,16,1,34,51,0,51,0,32,2,0,19,35,50,35,51,34,35,50,35,50,35,51,34,34,34,83,53,48,4,51,53,115,70,110,28,212,213,64,56,0,200,140,204,136,140,140,140,0,64,20,200,0,77,84,5,136,140,212,212,4,192,5,32,0,34,53,53,80,24,0,34,37,51,83,1,3,51,87,52,102,227,192,8,2,64,72,4,68,192,28,0,68,192,24,0,204,128,4,213,64,84,136,205,77,64,72,0,82,0,2,35,83,85,1,112,2,34,83,53,48,15,51,53,115,70,110,60,0,128,28,4,64,64,64,4,76,1,128,12,212,192,44,212,192,36,0,200,128,8,136,136,136,136,136,1,192,8,0,82,0,16,6,0,81,0,97,51,87,56,146,1,33,65,108,108,32,115,112,101,110,116,32,116,111,107,101,110,115,32,109,117,115,116,32,98,101,32,114,101,109,105,110,116,101,100,0,0,81,34,0,33,34,0,18,0,18,33,35,48,1,0,48,2,32,1,34,34,34,34,34,18,51,51,51,51,51,0,16,11,0,160,9,0,128,7,0,96,5,0,64,3,0,34,0,17,18,32,2,18,33,34,51,0,16,4,0,49,32,1,17,34,18,51,0,16,3,0,33,18,0,17,18,50,48,1,0,18,35,48,3,48,2,0,32,1,1]))]),
--         redeemers: Nothing,
--         vkeys: (Just [(Vkeywitness (Tuple (Vkey (PublicKey "ed25519_pk13hef55hmu0w39663gtf3yc56yyy7ln4ztcjhgndclzr39rcu0nmqw0swny")) (Ed25519Signature "ed25519_sig1yxa8sjlmr4z706a6p3uapy8f5e6lcr45pg9kfxe8yxhk62ad5q07kupexa0j88gg2f9wmzsf8d2njej5jys7ye64qy82wnhjpw44uqqs7k9jq")))]) }) })


-- ValidatedTx 
--   {body =
--     TxBodyConstr TxBodyRaw
--       {_inputs = fromList [
--         TxInCompact (TxId {_unTxId = SafeHash "19efa1deeedb1e6f48bef58aaaaa41c57874a941ceff6c45e0789a18b5df9c1a"}) 1,
--         TxInCompact (TxId {_unTxId = SafeHash "2b1408d521acca5d9216d5b8f1334541d43b2b8dd554effce72203c177c71e06"}) 0],
--       _collateral = fromList [TxInCompact (TxId {_unTxId = SafeHash "b476f506d399cb28890e54c186ce72c8c5ca4f65d0bbf79cb87d404b6231449c"}) 0],
--       _outputs = StrictSeq {fromStrict = fromList [
--           (Addr Testnet (KeyHashObj (KeyHash "6dfa509aeb35f670a84cac01bf1b5d8d3f03191210f045837ed57e37"))
--           (StakeRefBase (KeyHashObj (KeyHash "ba05ce68e7fcd03a55d4e4dcdedff2e77d1d053b313f0ce362622110"))),
--           Value 1889915275 (fromList []),
--           SNothing),

--           (Addr Testnet (ScriptHashObj (ScriptHash "df4def976c66c24bb32f2bdf63da44bd4d77757811e670457b27690b"))
--           StakeRefNull,
--           Value 2000000 (fromList [(PolicyID {policyID = ScriptHash "7040636730e73aea054c0b2dd0b734bec3ecaaca1e3cbe48b482ca14"},
--               fromList [("A\162!]\139\129s,(\195\210@lT\ACK\DC4\181#@\DC4\213]\161\aq-\189\216\f\228z\146",1)])]),
--           SNothing),

--           (Addr Testnet (KeyHashObj (KeyHash "3f3464650beb5324d0e463ebe81fbe1fd519b6438521e96d0d35bd75")) StakeRefNull
--           ,Value 85000000 (fromList []),SNothing),

--           (Addr Testnet (KeyHashObj (KeyHash "3f3464650beb5324d0e463ebe81fbe1fd519b6438521e96d0d35bd75")) StakeRefNull,
--           Value 10000000 (fromList []),SNothing),

--           (Addr Testnet (ScriptHashObj (ScriptHash "9da8fa76a2a0f52aa5df10fb7b81f9afe4b20e9068b3f95fadc7477a")) StakeRefNull,
--           Value 5000000 (fromList []),SNothing)]},
--       _certs = StrictSeq {fromStrict = fromList []},
--       _wdrls = Wdrl {unWdrl = fromList []},
--       _txfee = Coin 1000517,
--       _vldt = ValidityInterval {invalidBefore = SNothing, invalidHereafter = SNothing},
--       _update = SNothing,
--       _reqSignerHashes = fromList [],
--       _mint = Value 0
--         (fromList [(PolicyID {policyID = ScriptHash "7040636730e73aea054c0b2dd0b734bec3ecaaca1e3cbe48b482ca14"},
--         fromList [("A\162!]\139\129s,(\195\210@lT\ACK\DC4\181#@\DC4\213]\161\aq-\189\216\f\228z\146",1),
--         ("\216P\215\167\SI\213\255\151\171\DLEK\DC2}L\150\&0\198M\138\193X\161L\220\196\246QW\183\154\240\186",-1)])]),
--       _scriptIntegrityHash = SNothing,
--       _adHash = SNothing,
--       _txnetworkid = SJust Testnet},
--   wits = TxWitnessRaw {_txwitsVKey =
--     fromList [WitVKey' {wvkKey' = VKey (VerKeyEd25519DSIGN "8df29a52fbe3dd12eb5142d312629a2109efcea25e25744db8f887128f1c7cf6"), 
--     wvkSig' = SignedDSIGN (SigEd25519DSIGN "21ba784bfb1d45e7ebba0c79d090e9a675fc0eb40a0b649b2721af6d2bada01feb7039375f239d08524aed8a093b553966549121e26755010ea74ef20bab5e00"),
--     wvkKeyHash = KeyHash "6dfa509aeb35f670a84cac01bf1b5d8d3f03191210f045837ed57e37",
--     wvkBytes = "\130X \141\242\154R\251\227\221\DC2\235QB\211\DC2b\154!\t\239\206\162^%tM\184\248\135\DC2\143\FS|\246X@!\186xK\251\GSE\231\235\186\fy\208\144\233\166u\252\SO\180\n\vd\155'!\175m+\173\160\US\235p97_#\157\bRJ\237\138\t;U9fT\145!\226gU\SOH\SO\167N\242\v\171^\NUL"}],
--     _txwitsBoot = fromList [],
--     _txscripts = fromList
--       [(ScriptHash "7040636730e73aea054c0b2dd0b734bec3ecaaca1e3cbe48b482ca14",
--       PlutusScript PlutusV1 ScriptHash "7040636730e73aea054c0b2dd0b734bec3ecaaca1e3cbe48b482ca14"),
--       (ScriptHash "df4def976c66c24bb32f2bdf63da44bd4d77757811e670457b27690b",
--       PlutusScript PlutusV1 ScriptHash "df4def976c66c24bb32f2bdf63da44bd4d77757811e670457b27690b")],
--     _txdats = TxDatsRaw (fromList []),
--     _txrdmrs = RedeemersRaw (fromList [])},
--     isValid = IsValid True,
--     auxiliaryData = SNothing}
