{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.Probe
  ( runProbe
  , startProbeLoop
  , ProbeEnv(..)
  , initProbeEnv
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, newTVarIO, atomically, modifyTVar', readTVarIO)
import Control.Monad (forever)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack)
import qualified Data.CaseInsensitive as CI
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import qualified Network.HTTP.Client as HTTP

import Data.Function ((&))
import Network.HTTP.Tower
  ( Client, newClientWithTLS, runRequest, applyMiddleware
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
import Sentinel.Version (userAgent)
import Sentinel.Probe.Database (runDbProbe)
import qualified Sentinel.Alert as Alert

-- | Per-probe runtime state.
data ProbeEnv = ProbeEnv
  { probeEnvBreakers  :: Map Text CircuitBreaker
  , probeEnvStates    :: TVar (Map Text ProbeState)
  , probeEnvEventLog  :: TVar [AlertEvent]
  }

-- | Initialize runtime state for all probes.
initProbeEnv :: [ProbeConfig] -> IO ProbeEnv
initProbeEnv configs = do
  breakers <- Map.fromList <$> mapM mkBreaker configs
  statesVar <- newTVarIO Map.empty
  eventLog <- newTVarIO []
  pure ProbeEnv
    { probeEnvBreakers  = breakers
    , probeEnvStates    = statesVar
    , probeEnvEventLog  = eventLog
    }
  where
    mkBreaker cfg = do
      breaker <- newCircuitBreaker
      pure (probeName cfg, breaker)

-- | Execute one probe, dispatching based on ProbeKind.
runProbe :: ProbeEnv -> AppConfig -> ProbeConfig -> IO ProbeResult
runProbe env appConfig config = case probeKind config of
  HttpProbe httpCfg -> runHttpProbe env appConfig config httpCfg
  _                 -> runDbProbe (probeEnvBreakers env) config

-- | Build a Tower HTTP client for a probe config and execute one HTTP probe.
runHttpProbe :: ProbeEnv -> AppConfig -> ProbeConfig -> HttpProbeConfig -> IO ProbeResult
runHttpProbe env appConfig config httpCfg = do
  let mClientCert = (,) <$> httpTlsClientCert httpCfg <*> httpTlsClientKey httpCfg
  client <- newClientWithTLS (httpTlsCaPath httpCfg) mClientCert
  let cbPair = (,) <$> probeCircuitBreaker config
                    <*> Map.lookup (probeName config) (probeEnvBreakers env)
      configured = client
        & applyMiddleware (withUserAgent userAgent . withRequestId)
        & applyHeaders (httpHeaders httpCfg)
        & withOpt (httpFollowRedirects httpCfg) withFollowRedirects
        & withOpt (probeRetries config) (\n -> withRetry (constantBackoff n 1.0))
        & withOpt (probeTimeout config) withTimeout
        & withOpt (httpExpectedStatus httpCfg)
            (\(lo, hi) -> withValidateStatus (\s -> s >= lo && s <= hi))
        & withOpt cbPair
            (\(cbs, breaker) -> withCircuitBreaker
              (CircuitBreakerConfig (cbsFailureThreshold cbs) (fromIntegral (cbsCooldownSeconds cbs)))
              breaker)
        & (if configTracing appConfig then applyMiddleware withTracing else id)
        & applyMiddleware
            (withLogging (\msg -> putStrLn $ "[probe:" <> unpack (probeName config) <> "] " <> unpack msg))

  req <- HTTP.parseRequest (unpack (httpUrl httpCfg))
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
  where
    withOpt mv f = maybe id (applyMiddleware . f) mv
    applyHeaders hs c = foldl (\c' (k, v) -> c' & applyMiddleware (withHeader (CI.mk (encodeUtf8 k)) (encodeUtf8 v))) c hs

-- | Start an infinite loop that probes at the configured interval.
startProbeLoop :: ProbeEnv -> AppConfig -> TVar (Map Text ProbeResult) -> ProbeConfig -> IO ()
startProbeLoop env appConfig stateVar config = forever $ do
  result <- runProbe env appConfig config
  atomically $ modifyTVar' stateVar (Map.insert (probeName config) result)

  -- Check for state transitions and fire alerts
  case configAlerting appConfig of
    Just alertCfg -> do
      states <- readTVarIO (probeEnvStates env)
      let prevState = Map.findWithDefault defaultProbeState (probeName config) states
          event = Alert.detectEvent config prevState result (resultCheckedAt result)
      case event of
        Just evt -> atomically $ modifyTVar' (probeEnvEventLog env) (evt :)
        Nothing  -> pure ()
      newState <- Alert.checkAndAlert alertCfg config prevState result
      atomically $ modifyTVar' (probeEnvStates env) (Map.insert (probeName config) newState)
    Nothing -> pure ()

  threadDelay (probeInterval config * 1_000_000)
