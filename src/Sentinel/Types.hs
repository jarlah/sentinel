{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Types
  ( ProbeConfig(..)
  , ProbeKind(..)
  , HttpProbeConfig(..)
  , MySQLProbeConfig(..)
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

import Data.Aeson (ToJSON(..), FromJSON(..), Value(..), (.=), (.:), (.:?), (.!=), object, withObject)
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

-- Probe kind (HTTP vs database)

data HttpProbeConfig = HttpProbeConfig
  { httpUrl             :: !Text
  , httpFollowRedirects :: !(Maybe Int)
  , httpExpectedStatus  :: !(Maybe (Int, Int))
  , httpHeaders         :: ![(Text, Text)]
  , httpTlsCaPath       :: !(Maybe FilePath)
  , httpTlsClientCert   :: !(Maybe FilePath)
  , httpTlsClientKey    :: !(Maybe FilePath)
  } deriving (Show, Generic)

data MySQLProbeConfig = MySQLProbeConfig
  { mysqlHost     :: !Text
  , mysqlPort     :: !Int
  , mysqlUser     :: !Text
  , mysqlPassword :: !Text
  , mysqlDatabase :: !Text
  } deriving (Show, Generic)

instance FromJSON MySQLProbeConfig where
  parseJSON = withObject "MySQLProbeConfig" $ \v -> MySQLProbeConfig
    <$> v .:? "host" .!= "localhost"
    <*> v .:? "port" .!= 3306
    <*> v .:? "user" .!= "root"
    <*> v .:? "password" .!= ""
    <*> v .:? "database" .!= ""

data ProbeKind
  = HttpProbe !HttpProbeConfig
  | PostgresProbe !Text          -- connection string
  | MySQLProbe !MySQLProbeConfig
  | RedisProbe !Text             -- connection URI (e.g. "redis://localhost:6379")
  deriving (Show, Generic)

-- Probe config (shared fields + kind-specific)

data ProbeConfig = ProbeConfig
  { probeName           :: !Text
  , probeKind           :: !ProbeKind
  , probeInterval       :: !Int
  , probeTimeout        :: !(Maybe Int)
  , probeRetries        :: !(Maybe Int)
  , probeCircuitBreaker :: !(Maybe CircuitBreakerSettings)
  , probeAlertAfter     :: !Int
  , probeAlertReminder  :: !Int    -- seconds, 0 = no reminders
  , probeAlerts         :: !(Maybe [Text])  -- channel names, Nothing = all configured
  } deriving (Show, Generic)

instance FromJSON ProbeConfig where
  parseJSON = withObject "ProbeConfig" $ \v -> do
    name         <- v .: "name"
    interval     <- v .:? "interval_seconds" .!= 30
    timeout      <- v .:? "timeout_ms"
    retries      <- v .:? "retries"
    cb           <- v .:? "circuit_breaker"
    alertAfter   <- v .:? "alert_after" .!= 1
    alertRemind  <- v .:? "alert_reminder" .!= 0
    alerts       <- v .:? "alerts"

    probeType <- v .:? "type" .!= ("http" :: Text)
    kind <- case probeType of
      "http" -> do
        url            <- v .: "url"
        followRedirs   <- v .:? "follow_redirects"
        expectedStatus <- v .:? "expected_status"
        headers        <- v .:? "headers" .!= []
        tlsCa          <- v .:? "tls_ca_path"
        tlsCert        <- v .:? "tls_client_cert"
        tlsKey         <- v .:? "tls_client_key"
        pure $ HttpProbe HttpProbeConfig
          { httpUrl             = url
          , httpFollowRedirects = followRedirs
          , httpExpectedStatus  = expectedStatus
          , httpHeaders         = headers
          , httpTlsCaPath       = tlsCa
          , httpTlsClientCert   = tlsCert
          , httpTlsClientKey    = tlsKey
          }
      "postgres" -> PostgresProbe <$> v .: "connection_string"
      "mysql"    -> MySQLProbe <$> parseJSON (Object v)
      "redis"    -> RedisProbe <$> v .:? "connection_string" .!= "redis://localhost:6379"
      other      -> fail $ "Unknown probe type: " <> show other

    pure ProbeConfig
      { probeName           = name
      , probeKind           = kind
      , probeInterval       = interval
      , probeTimeout        = timeout
      , probeRetries        = retries
      , probeCircuitBreaker = cb
      , probeAlertAfter     = alertAfter
      , probeAlertReminder  = alertRemind
      , probeAlerts         = alerts
      }

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
