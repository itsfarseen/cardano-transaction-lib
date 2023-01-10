module Test.Ctl.Blockfrost.GenerateFixtures.Helpers
  ( blockfrostBackend
  , contractParams
  , lookupEnv'
  , md5
  , storeBlockfrostFixture
  ) where

import Contract.Prelude

import Contract.Config
  ( ContractParams
  , PrivatePaymentKeySource(PrivatePaymentKeyFile)
  , WalletSpec(UseKeys)
  , blockfrostPublicPreviewServerConfig
  , testnetConfig
  )
import Ctl.Internal.Contract.QueryBackend
  ( BlockfrostBackend
  , mkBlockfrostBackendParams
  )
import Data.Maybe (Maybe(Just, Nothing), maybe)
import Effect.Exception (throw)
import Node.Encoding (Encoding(UTF8))
import Node.FS.Aff (exists, writeTextFile)
import Node.Path (concat)
import Node.Process (lookupEnv)

foreign import md5 :: String -> String

blockfrostBackend :: Effect BlockfrostBackend
blockfrostBackend =
  getBlockfrostApiKeyFromEnv <#> \blockfrostApiKey ->
    { blockfrostConfig: blockfrostPublicPreviewServerConfig
    , blockfrostApiKey: Just blockfrostApiKey
    }

contractParams :: Effect ContractParams
contractParams = do
  blockfrostApiKey <- getBlockfrostApiKeyFromEnv
  skeyFilepath <- getSkeyFilepathFromEnv
  pure $ testnetConfig
    { backendParams =
        mkBlockfrostBackendParams
          { blockfrostConfig: blockfrostPublicPreviewServerConfig
          , blockfrostApiKey: Just blockfrostApiKey
          }
    , logLevel = Info
    , walletSpec = Just $ UseKeys (PrivatePaymentKeyFile skeyFilepath) Nothing
    }

getBlockfrostApiKeyFromEnv :: Effect String
getBlockfrostApiKeyFromEnv = lookupEnv' "BLOCKFROST_API_KEY"

getSkeyFilepathFromEnv :: Effect String
getSkeyFilepathFromEnv = lookupEnv' "SKEY_FILEPATH"

lookupEnv' :: String -> Effect String
lookupEnv' var =
  lookupEnv var >>=
    maybe (throw $ var <> " environment variable not set") pure

storeBlockfrostFixture :: Int -> String -> String -> Aff Unit
storeBlockfrostFixture i query resp =
  let
    respHash = md5 resp
    filename = query <> "-" <> respHash <> ".json"
    fp = concat [ "fixtures", "test", "blockfrost", query, filename ]
  in
    exists fp >>= flip unless
      ( writeTextFile UTF8 fp resp
          *> log ("Successfully saved fixture #" <> show i <> " to: " <> fp)
      )
