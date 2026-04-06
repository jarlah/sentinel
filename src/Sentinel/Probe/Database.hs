{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Probe.Database
  ( runDbProbe
  ) where

import Control.Exception (SomeException, try)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Tower
  ( Service(..)
  , ServiceError(..)
  , runService
  , withRetry
  , constantBackoff
  , withTimeout
  , withCircuitBreaker
  , CircuitBreakerConfig(..)
  , CircuitBreaker
  , displayError
  )

import qualified Database.PostgreSQL.Simple as PG
import qualified Database.MySQL.Base as MySQL
import qualified Database.Redis as Redis

import Sentinel.Types

-- | Run a database probe: build a tower-hs Service wrapping a DB ping,
-- apply middleware (timeout, retry, circuit breaker), execute, and return ProbeResult.
runDbProbe :: Map Text CircuitBreaker -> ProbeConfig -> IO ProbeResult
runDbProbe breakers config = do
  let baseService = mkPingService (probeKind config)
      withMiddleware = applyMiddleware config breakers baseService
      name = probeName config

  start <- getCurrentTime
  result <- runService withMiddleware ()
  end <- getCurrentTime
  let latency = realToFrac (diffUTCTime end start) * 1000 :: Double

  pure $ case result of
    Right () -> ProbeResult
      { resultName      = name
      , resultStatus    = Up
      , resultLatencyMs = latency
      , resultError     = Nothing
      , resultCheckedAt = end
      }
    Left err -> ProbeResult
      { resultName      = name
      , resultStatus    = Down
      , resultLatencyMs = latency
      , resultError     = Just (displayError err)
      , resultCheckedAt = end
      }

-- | Create a base tower-hs Service that pings the database.
-- Each invocation creates a fresh connection, pings, and closes it.
mkPingService :: ProbeKind -> Service () ()
mkPingService kind = Service $ \() -> do
  result <- try (ping kind) :: IO (Either SomeException ())
  pure $ case result of
    Right () -> Right ()
    Left ex  -> Left (TransportError ex)
  where
    ping (PostgresProbe connStr) = do
      conn <- PG.connectPostgreSQL (encodeUtf8 connStr)
      _ <- PG.query_ conn "SELECT 1" :: IO [PG.Only Int]
      PG.close conn

    ping (MySQLProbe cfg) = do
      conn <- MySQL.connect MySQL.defaultConnectInfo
        { MySQL.ciHost     = unpack (mysqlHost cfg)
        , MySQL.ciPort     = fromIntegral (mysqlPort cfg)
        , MySQL.ciUser     = encodeUtf8 (mysqlUser cfg)
        , MySQL.ciPassword = encodeUtf8 (mysqlPassword cfg)
        , MySQL.ciDatabase = encodeUtf8 (mysqlDatabase cfg)
        }
      MySQL.ping conn
      MySQL.close conn

    ping (RedisProbe connUri) = do
      connInfo <- case Redis.parseConnectInfo (unpack connUri) of
        Right ci -> pure ci
        Left err -> fail $ "Invalid Redis URI: " <> err
      conn <- Redis.checkedConnect connInfo
      Redis.disconnect conn

    ping (HttpProbe _) = error "runDbProbe called with HttpProbe"

-- | Apply tower-hs middleware (retry, timeout, circuit breaker) to a service.
applyMiddleware :: ProbeConfig -> Map Text CircuitBreaker -> Service () () -> Service () ()
applyMiddleware config breakers base =
  let s1 = maybe base (\n -> withRetry (constantBackoff n 1.0) base) (probeRetries config)
      s2 = maybe s1 (\ms -> withTimeout ms s1) (probeTimeout config)
      s3 = case (probeCircuitBreaker config, Map.lookup (probeName config) breakers) of
        (Just cbs, Just breaker) ->
          withCircuitBreaker
            (CircuitBreakerConfig (cbsFailureThreshold cbs) (fromIntegral (cbsCooldownSeconds cbs)))
            breaker
            s2
        _ -> s2
  in s3
