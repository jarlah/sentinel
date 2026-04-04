{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.Probe
  ( runProbe
  , startProbeLoop
  , ProbeEnv(..)
  , initProbeEnv
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Control.Monad (forever)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack)
import qualified Data.CaseInsensitive as CI
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import qualified Network.HTTP.Client as HTTP

import Network.HTTP.Tower
  ( Client, newClient, runRequest, (|>)
  , withRetry, constantBackoff
  , withTimeout
  , withLogging
  , withRequestId
  , withUserAgent
  , withFollowRedirects
  , withValidateStatus
  , withTracing
  , withCircuitBreaker
  , withHeader
  , CircuitBreakerConfig(..)
  , CircuitBreaker
  , newCircuitBreaker
  , displayError
  )

import Sentinel.Types

-- | Per-probe runtime state (circuit breakers, etc.)
data ProbeEnv = ProbeEnv
  { probeEnvBreakers :: Map Text CircuitBreaker
  }

-- | Initialize runtime state for all probes.
initProbeEnv :: [ProbeConfig] -> IO ProbeEnv
initProbeEnv configs = do
  breakers <- Map.fromList <$> mapM mkBreaker configs
  pure ProbeEnv { probeEnvBreakers = breakers }
  where
    mkBreaker cfg = do
      breaker <- newCircuitBreaker
      pure (probeName cfg, breaker)

-- | Build a Tower client for a probe config and execute one probe.
runProbe :: ProbeEnv -> AppConfig -> ProbeConfig -> IO ProbeResult
runProbe env appConfig config = do
  client <- newClient
  let -- Base: always applied
      base = client
        |> withUserAgent "sentinel/0.1.0"
        |> withRequestId

      -- Custom headers (only if configured)
      c1 = foldl (\c (k, v) -> c |> withHeader (CI.mk (encodeUtf8 k)) (encodeUtf8 v))
        base (probeHeaders config)

      -- Follow redirects (only if configured)
      c2 = maybe c1 (\n -> c1 |> withFollowRedirects n) (probeFollowRedirects config)

      -- Retry (only if configured)
      c3 = maybe c2 (\n -> c2 |> withRetry (constantBackoff n 1.0)) (probeRetries config)

      -- Timeout (only if configured)
      c4 = maybe c3 (\ms -> c3 |> withTimeout ms) (probeTimeout config)

      -- Status validation (only if configured)
      c5 = maybe c4 (\(lo, hi) -> c4 |> withValidateStatus (\c -> c >= lo && c <= hi))
        (probeExpectedStatus config)

      -- Circuit breaker (only if configured)
      c6 = case (probeCircuitBreaker config, Map.lookup (probeName config) (probeEnvBreakers env)) of
        (Just cbs, Just breaker) ->
          c5 |> withCircuitBreaker
            (CircuitBreakerConfig (cbsFailureThreshold cbs) (fromIntegral (cbsCooldownSeconds cbs)))
            breaker
        _ -> c5

      -- OTel tracing (only if enabled globally)
      c7 = if configTracing appConfig then c6 |> withTracing else c6

      -- Logging (always last — outermost layer)
      configured = c7
        |> withLogging (\msg -> putStrLn $ "[probe:" <> unpack (probeName config) <> "] " <> unpack msg)

  req <- HTTP.parseRequest (unpack (probeUrl config))
  start <- getCurrentTime
  result <- runRequest configured req
  end <- getCurrentTime
  let latency = realToFrac (diffUTCTime end start) * 1000 :: Double
  pure $ case result of
    Right _resp -> ProbeResult
      { resultName      = probeName config
      , resultStatus    = Up
      , resultLatencyMs = latency
      , resultError     = Nothing
      , resultCheckedAt = end
      }
    Left err -> ProbeResult
      { resultName      = probeName config
      , resultStatus    = Down
      , resultLatencyMs = latency
      , resultError     = Just (displayError err)
      , resultCheckedAt = end
      }

-- | Start an infinite loop that probes at the configured interval.
startProbeLoop :: ProbeEnv -> AppConfig -> TVar (Map Text ProbeResult) -> ProbeConfig -> IO ()
startProbeLoop env appConfig stateVar config = forever $ do
  result <- runProbe env appConfig config
  atomically $ modifyTVar' stateVar (Map.insert (probeName config) result)
  threadDelay (probeInterval config * 1_000_000)
