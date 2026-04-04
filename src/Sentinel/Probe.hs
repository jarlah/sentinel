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
  let -- Base middleware: always applied
      base = client
        |> withUserAgent "sentinel/0.1.0"
        |> withRequestId

      -- Custom headers from config
      withCustomHeaders = foldl (\c (k, v) -> c |> withHeader (CI.mk (encodeUtf8 k)) (encodeUtf8 v))
        base (probeHeaders config)

      -- Follow redirects (0 = disabled)
      withRedirects = if probeFollowRedirects config > 0
        then withCustomHeaders |> withFollowRedirects (probeFollowRedirects config)
        else withCustomHeaders

      -- Retry with constant backoff
      withRetries = withRedirects
        |> withRetry (constantBackoff (probeRetries config) 1.0)

      -- Timeout
      withTmo = withRetries
        |> withTimeout (probeTimeout config)

      -- Status validation
      (minStatus, maxStatus) = probeExpectedStatus config
      withValidation = withTmo
        |> withValidateStatus (\c -> c >= minStatus && c <= maxStatus)

      -- Circuit breaker (if configured)
      withCb = case (probeCircuitBreaker config, Map.lookup (probeName config) (probeEnvBreakers env)) of
        (Just cbs, Just breaker) ->
          withValidation |> withCircuitBreaker
            (CircuitBreakerConfig (cbsFailureThreshold cbs) (fromIntegral (cbsCooldownSeconds cbs)))
            breaker
        _ -> withValidation

      -- OTel tracing (if enabled globally)
      withTrc = if configTracing appConfig
        then withCb |> withTracing
        else withCb

      -- Logging (always last — outermost layer)
      configured = withTrc
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
