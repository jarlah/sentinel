{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.Alert.PrometheusSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import Data.IORef
import Data.Text (Text, isInfixOf, pack)
import qualified Data.ByteString.Lazy as LBS
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as TLS
import System.Process (readProcess)
import Test.Hspec

import qualified TestContainers as TC
import TestContainers.Hspec (withContainers)

import Data.Function ((&))
import Network.HTTP.Tower (HttpResponse, newClient, applyMiddleware, withMock)

import Sentinel.Alert.Prometheus (pushMetrics, pushMetricsWith, formatMetrics)
import Sentinel.Types

spec :: Spec
spec = describe "Prometheus alerting" $ do
  describe "formatMetrics" $ do
    it "formats probe_up gauge as 1 when up" $ do
      let metrics = formatMetrics "my-app" True 89.5
      isInfixOf "sentinel_probe_up" metrics `shouldBe` True
      isInfixOf "probe=\"my-app\"" metrics `shouldBe` True
      isInfixOf "} 1" metrics `shouldBe` True

    it "formats probe_up gauge as 0 when down" $ do
      let metrics = formatMetrics "my-app" False 0
      isInfixOf "} 0" metrics `shouldBe` True

    it "includes latency metric" $ do
      let metrics = formatMetrics "my-app" True 89.5
      isInfixOf "sentinel_probe_latency_ms" metrics `shouldBe` True
      isInfixOf "89.5" metrics `shouldBe` True

  describe "pushMetricsWith" $ do
    it "sends POST to the correct pushgateway path" $ do
      recorder <- newIORef []
      client <- newClient
      let mocked = client & applyMiddleware (withMock (\req -> do
            modifyIORef' recorder (req :)
            pure (Right fakeOkResponse)))
          cfg = PrometheusConfig
            { promPushgatewayUrl = "http://localhost:9091"
            , promJob = "sentinel"
            }
      pushMetricsWith mocked cfg "my-app" True 42.0
      reqs <- readIORef recorder
      length reqs `shouldBe` 1
      HTTP.method (head reqs) `shouldBe` "POST"
      HTTP.path (head reqs) `shouldBe` "/metrics/job/sentinel/probe/my-app"

    it "sends text/plain content type" $ do
      recorder <- newIORef []
      client <- newClient
      let mocked = client & applyMiddleware (withMock (\req -> do
            modifyIORef' recorder (req :)
            pure (Right fakeOkResponse)))
          cfg = PrometheusConfig "http://localhost:9091" "sentinel"
      pushMetricsWith mocked cfg "test" True 10.0
      reqs <- readIORef recorder
      lookup "Content-Type" (HTTP.requestHeaders (head reqs))
        `shouldBe` Just "text/plain"

  describe "Pushgateway integration (Docker)" $ beforeAll dockerAvailable $ do
    it "pushes metrics to real Pushgateway" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else withContainers setupPushgateway $ \port -> do
          let cfg = PrometheusConfig
                { promPushgatewayUrl = "http://localhost:" <> pack (show port)
                , promJob = "sentinel-test"
                }
          pushMetrics cfg "test-probe" True 42.0
          threadDelay 1_000_000

          mgr <- HTTP.newManager TLS.tlsManagerSettings
          req <- HTTP.parseRequest $ "http://localhost:" <> show port <> "/metrics"
          resp <- HTTP.httpLbs req mgr
          let bodyText = pack (show (LBS.toStrict (HTTP.responseBody resp)))
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

fakeOkResponse :: HttpResponse
fakeOkResponse = error "response body not evaluated in mock tests"
