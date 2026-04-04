{-# LANGUAGE NumericUnderscores #-}

module Main where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.STM (newTVarIO)
import qualified Data.Map.Strict as Map
import qualified Network.Wai.Handler.Warp as Warp
import System.Environment (getArgs)

import Sentinel.Api (app)
import Sentinel.Config (loadConfig)
import Sentinel.Probe (startProbeLoop)
import Sentinel.Types (AppConfig(..), ProbeConfig(..))

main :: IO ()
main = do
  args <- getArgs
  let configPath = case args of
        (path:_) -> path
        []       -> "config.yaml"

  config <- loadConfig configPath
  putStrLn $ "Sentinel starting on port " <> show (configPort config)
  putStrLn $ "Monitoring " <> show (length (configProbes config)) <> " probes"

  stateVar <- newTVarIO Map.empty

  -- Start probe loops concurrently alongside the web server
  let probes = configProbes config
      server = Warp.run (configPort config) (app stateVar)
      probeLoops = mapConcurrently_ (startProbeLoop stateVar) probes

  -- Run server and probes concurrently
  mapConcurrently_ id [server, probeLoops]
