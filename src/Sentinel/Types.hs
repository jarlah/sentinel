{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Types
  ( ProbeConfig(..)
  , ProbeResult(..)
  , ProbeStatus(..)
  , AppConfig(..)
  , CircuitBreakerSettings(..)
  , AlertingConfig(..)
  , SlackConfig(..)
  , ResendConfig(..)
  , PrometheusConfig(..)
  , AlertEvent(..)
  , ProbeState(..)
  , defaultProbeState
  ) where

import Data.Aeson (ToJSON(..), FromJSON(..), (.=), (.:), (.:?), (.!=), object, withObject)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)

-- App config

data AppConfig = AppConfig
  { configPort     :: !Int
  , configProbes   :: ![ProbeConfig]
  , configTracing  :: !Bool
  , configAlerting :: !(Maybe AlertingConfig)
  } deriving (Show, Generic)

instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \v -> AppConfig
    <$> v .:? "port" .!= 8080
    <*> v .: "probes"
    <*> v .:? "tracing" .!= False
    <*> v .:? "alerting"

-- Alerting config

data AlertingConfig = AlertingConfig
  { alertSlack      :: !(Maybe SlackConfig)
  , alertResend      :: !(Maybe ResendConfig)
  , alertPrometheus :: !(Maybe PrometheusConfig)
  } deriving (Show, Generic)

instance FromJSON AlertingConfig where
  parseJSON = withObject "AlertingConfig" $ \v -> AlertingConfig
    <$> v .:? "slack"
    <*> v .:? "resend"
    <*> v .:? "prometheus"

newtype SlackConfig = SlackConfig
  { slackWebhookUrl :: Text
  } deriving (Show, Generic)

instance FromJSON SlackConfig where
  parseJSON = withObject "SlackConfig" $ \v -> SlackConfig
    <$> v .: "webhook_url"

data ResendConfig = ResendConfig
  { resendApiUrl :: !Text
  , resendApiKey :: !Text
  , resendFrom   :: !Text
  , resendTo     :: ![Text]
  } deriving (Show, Generic)

instance FromJSON ResendConfig where
  parseJSON = withObject "ResendConfig" $ \v -> ResendConfig
    <$> v .:? "api_url" .!= "https://api.resend.com/emails"
    <*> v .: "api_key"
    <*> v .: "from"
    <*> v .: "to"

data PrometheusConfig = PrometheusConfig
  { promPushgatewayUrl :: !Text
  , promJob            :: !Text
  } deriving (Show, Generic)

instance FromJSON PrometheusConfig where
  parseJSON = withObject "PrometheusConfig" $ \v -> PrometheusConfig
    <$> v .: "pushgateway_url"
    <*> v .:? "job" .!= "sentinel"

-- Circuit breaker

data CircuitBreakerSettings = CircuitBreakerSettings
  { cbsFailureThreshold :: !Int
  , cbsCooldownSeconds  :: !Int
  } deriving (Show, Generic)

instance FromJSON CircuitBreakerSettings where
  parseJSON = withObject "CircuitBreakerSettings" $ \v -> CircuitBreakerSettings
    <$> v .:? "failure_threshold" .!= 5
    <*> v .:? "cooldown_seconds" .!= 30

-- Probe config

data ProbeConfig = ProbeConfig
  { probeName            :: !Text
  , probeUrl             :: !Text
  , probeInterval        :: !Int
  , probeTimeout         :: !(Maybe Int)
  , probeRetries         :: !(Maybe Int)
  , probeFollowRedirects :: !(Maybe Int)
  , probeExpectedStatus  :: !(Maybe (Int, Int))
  , probeCircuitBreaker  :: !(Maybe CircuitBreakerSettings)
  , probeHeaders         :: ![(Text, Text)]
  , probeAlertAfter      :: !Int
  , probeAlertReminder   :: !Int    -- seconds, 0 = no reminders
  , probeAlerts          :: !(Maybe [Text])  -- channel names, Nothing = all configured
  , probeTlsCaPath       :: !(Maybe FilePath)
  , probeTlsClientCert   :: !(Maybe FilePath)
  , probeTlsClientKey    :: !(Maybe FilePath)
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
    <*> v .:? "alert_after" .!= 1
    <*> v .:? "alert_reminder" .!= 0
    <*> v .:? "alerts"
    <*> v .:? "tls_ca_path"
    <*> v .:? "tls_client_cert"
    <*> v .:? "tls_client_key"

-- Probe result

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

-- Alert events

data AlertEvent
  = ServiceDown !Text !(Maybe Text) !UTCTime        -- probe name, error, time
  | ServiceStillDown !Text !(Maybe Text) !UTCTime    -- reminder
  | ServiceRecovered !Text !Double !UTCTime           -- probe name, latency, time
  deriving (Show, Eq)

-- Probe state tracking for alert logic

data ProbeState = ProbeState
  { psLastStatus       :: !ProbeStatus
  , psConsecutiveFails :: !Int
  , psAlerted          :: !Bool
  , psLastAlertAt      :: !(Maybe UTCTime)
  } deriving (Show, Eq)

defaultProbeState :: ProbeState
defaultProbeState = ProbeState
  { psLastStatus       = Up
  , psConsecutiveFails = 0
  , psAlerted          = False
  , psLastAlertAt      = Nothing
  }
