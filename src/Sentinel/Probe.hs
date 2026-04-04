{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.Probe
  ( runProbe
  , startProbeLoop
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Control.Monad (forever)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import qualified Network.HTTP.Client as HTTP

import Network.HTTP.Tower
  ( Client, newClient, runRequest, (|>)
  , withRetry, constantBackoff
  , withTimeout
  , withLogging
  , displayError
  )

import Sentinel.Types (ProbeConfig(..), ProbeResult(..), ProbeStatus(..))

-- | Build a Tower client for a probe config and execute one probe.
runProbe :: ProbeConfig -> IO ProbeResult
runProbe config = do
  client <- newClient
  let configured = client
        |> withRetry (constantBackoff (probeRetries config) 1.0)
        |> withTimeout (probeTimeout config)
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

-- | Start an infinite loop that probes at the configured interval,
-- updating the shared state.
startProbeLoop :: TVar (Map Text ProbeResult) -> ProbeConfig -> IO ()
startProbeLoop stateVar config = forever $ do
  result <- runProbe config
  atomically $ modifyTVar' stateVar (Map.insert (probeName config) result)
  threadDelay (probeInterval config * 1_000_000)
