{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Types
  ( ProbeConfig(..)
  , ProbeResult(..)
  , ProbeStatus(..)
  , AppConfig(..)
  , CircuitBreakerSettings(..)
  ) where

import Data.Aeson (ToJSON(..), FromJSON(..), (.=), (.:), (.:?), (.!=), object, withObject)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)

data AppConfig = AppConfig
  { configPort    :: !Int
  , configProbes  :: ![ProbeConfig]
  , configTracing :: !Bool
  } deriving (Show, Generic)

instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \v -> AppConfig
    <$> v .:? "port" .!= 8080
    <*> v .: "probes"
    <*> v .:? "tracing" .!= False

data CircuitBreakerSettings = CircuitBreakerSettings
  { cbsFailureThreshold :: !Int
  , cbsCooldownSeconds  :: !Int
  } deriving (Show, Generic)

instance FromJSON CircuitBreakerSettings where
  parseJSON = withObject "CircuitBreakerSettings" $ \v -> CircuitBreakerSettings
    <$> v .:? "failure_threshold" .!= 5
    <*> v .:? "cooldown_seconds" .!= 30

data ProbeConfig = ProbeConfig
  { probeName            :: !Text
  , probeUrl             :: !Text
  , probeInterval        :: !Int               -- seconds
  , probeTimeout         :: !(Maybe Int)       -- milliseconds, Nothing = no timeout
  , probeRetries         :: !(Maybe Int)       -- Nothing = no retry
  , probeFollowRedirects :: !(Maybe Int)       -- max hops, Nothing = disabled
  , probeExpectedStatus  :: !(Maybe (Int, Int)) -- min, max (inclusive), Nothing = accept any
  , probeCircuitBreaker  :: !(Maybe CircuitBreakerSettings)
  , probeHeaders         :: ![(Text, Text)]
  } deriving (Show, Generic)

instance FromJSON ProbeConfig where
  parseJSON = withObject "ProbeConfig" $ \v -> ProbeConfig
    <$> v .: "name"
    <*> v .: "url"
    <*> v .:? "interval_seconds" .!= 30
    <*> v .:? "timeout_ms"
    <*> v .:? "retries"
    <*> v .:? "follow_redirects"
    <*> v .:? "expected_status"
    <*> v .:? "circuit_breaker"
    <*> v .:? "headers" .!= []

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
