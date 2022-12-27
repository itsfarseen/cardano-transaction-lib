module Ctl.Internal.QueryM.ServerConfig
  ( Host
  , ServerConfig
  , blockfrostPublicPreviewServerConfig
  , defaultKupoServerConfig
  , defaultOgmiosWsConfig
  , mkHttpUrl
  , mkServerUrl
  , mkWsUrl
  ) where

import Prelude

import Ctl.Internal.Helpers ((<</>>))
import Ctl.Internal.JsWebSocket (Url)
import Data.Maybe (Maybe(Just, Nothing), fromMaybe)
import Data.UInt (UInt)
import Data.UInt as UInt

type Host = String

type ServerConfig =
  { port :: UInt
  , host :: Host
  , secure :: Boolean
  , path :: Maybe String
  }

defaultOgmiosWsConfig :: ServerConfig
defaultOgmiosWsConfig =
  { port: UInt.fromInt 1337
  , host: "localhost"
  , secure: false
  , path: Nothing
  }

defaultKupoServerConfig :: ServerConfig
defaultKupoServerConfig =
  { port: UInt.fromInt 4008
  , host: "localhost"
  , secure: false
  , path: Just "kupo"
  }

blockfrostPublicPreviewServerConfig :: ServerConfig
blockfrostPublicPreviewServerConfig =
  { port: UInt.fromInt 443
  , host: "cardano-preview.blockfrost.io"
  , secure: true
  , path: Just "/api/v0"
  }

mkHttpUrl :: ServerConfig -> Url
mkHttpUrl = mkServerUrl "http"

mkWsUrl :: ServerConfig -> Url
mkWsUrl = mkServerUrl "ws"

mkServerUrl :: String -> ServerConfig -> Url
mkServerUrl protocol cfg =
  (if cfg.secure then (protocol <> "s") else protocol)
    <> "://"
    <> cfg.host
    <> ":"
    <> UInt.toString cfg.port
      <</>> fromMaybe "" cfg.path
