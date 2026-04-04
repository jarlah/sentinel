{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Types
  ( ProbeConfig(..)
  , ProbeResult(..)
  , ProbeStatus(..)
  , AppConfig(..)
  ) where

import Data.Aeson (ToJSON(..), FromJSON(..), (.=), (.:), (.:?), (.!=), object, withObject, withText)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)

data AppConfig = AppConfig
  { configPort   :: !Int
  , configProbes :: ![ProbeConfig]
  } deriving (Show, Generic)

instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \v -> AppConfig
    <$> v .:? "port" .!= 8080
    <*> v .: "probes"

data ProbeConfig = ProbeConfig
  { probeName     :: !Text
  , probeUrl      :: !Text
  , probeInterval :: !Int    -- seconds
  , probeTimeout  :: !Int    -- milliseconds
  , probeRetries  :: !Int
  } deriving (Show, Generic)

instance FromJSON ProbeConfig where
  parseJSON = withObject "ProbeConfig" $ \v -> ProbeConfig
    <$> v .: "name"
    <*> v .: "url"
    <*> v .:? "interval_seconds" .!= 30
    <*> v .:? "timeout_ms" .!= 5000
    <*> v .:? "retries" .!= 2

data ProbeStatus = Up | Down
  deriving (Show, Eq, Generic)

instance ToJSON ProbeStatus where
  toJSON Up   = "up"
  toJSON Down = "down"

data ProbeResult = ProbeResult
  { resultName      :: !Text
  , resultStatus    :: !ProbeStatus
  , resultLatencyMs :: !Double
  , resultError     :: !(Maybe Text)
  , resultCheckedAt :: !UTCTime
  } deriving (Show, Generic)

instance ToJSON ProbeResult where
  toJSON r = object
    [ "name"       .= resultName r
    , "status"     .= resultStatus r
    , "latency_ms" .= resultLatencyMs r
    , "error"      .= resultError r
    , "checked_at" .= resultCheckedAt r
    ]
