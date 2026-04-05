{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}
module Sentinel.Alert.PrometheusSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import Data.Text (Text, isInfixOf, pack)
import qualified Data.ByteString.Lazy as LBS
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as TLS
import System.Process (readProcess)
import Test.Hspec

import qualified TestContainers as TC
import TestContainers.Hspec (withContainers)

import Sentinel.Alert.Prometheus (pushMetrics, formatMetrics)
import Sentinel.Types

spec :: Spec
spec = describe "Prometheus alerting" $ do
  describe "formatMetrics" $ do
    it "formats probe_up gauge" $ do
      let metrics = formatMetrics "my-app" True 89.5
      isInfixOf "sentinel_probe_up" metrics `shouldBe` True
      isInfixOf "probe=\"my-app\"" metrics `shouldBe` True
      isInfixOf "} 1" metrics `shouldBe` True

    it "formats probe_up as 0 when down" $ do
      let metrics = formatMetrics "my-app" False 0
      isInfixOf "} 0" metrics `shouldBe` True

    it "includes latency metric" $ do
      let metrics = formatMetrics "my-app" True 89.5
      isInfixOf "sentinel_probe_latency_ms" metrics `shouldBe` True
      isInfixOf "89.5" metrics `shouldBe` True

  describe "Pushgateway integration (Docker)" $ beforeAll dockerAvailable $ do
    it "pushes metrics to Pushgateway" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else withContainers setupPushgateway $ \port -> do
          let cfg = PrometheusConfig
                { promPushgatewayUrl = "http://localhost:" <> pack (show port)
                , promJob = "sentinel-test"
                }
          pushMetrics cfg "test-probe" True 42.0

          -- Give Pushgateway time to process
          threadDelay 1_000_000

          -- Query metrics from Pushgateway
          mgr <- HTTP.newManager TLS.tlsManagerSettings
          req <- HTTP.parseRequest $
            "http://localhost:" <> show port <> "/metrics"
          resp <- HTTP.httpLbs req mgr
          let body = LBS.toStrict (HTTP.responseBody resp)
              bodyText = pack (show body)
          isInfixOf "sentinel_probe_up" bodyText `shouldBe` True
          isInfixOf "test-probe" bodyText `shouldBe` True

setupPushgateway :: TC.TestContainer Int
setupPushgateway = do
  container <- TC.run $ TC.containerRequest (TC.fromTag "prom/pushgateway:latest")
    TC.& TC.setExpose [9091]
    TC.& TC.setWaitingFor (TC.waitUntilTimeout 30 (TC.waitUntilMappedPortReachable 9091))
  pure (TC.containerPort container 9091)

dockerAvailable :: IO Bool
dockerAvailable = do
  result <- try (readProcess "docker" ["info"] "") :: IO (Either SomeException String)
  pure $ case result of
    Right _ -> True
    Left _  -> False
