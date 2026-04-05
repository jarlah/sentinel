{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.Prometheus
  ( push
  , pushMetrics
  , pushMetricsWith
  , formatMetrics
  ) where

import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8)
import qualified Network.HTTP.Client as HTTP

import Network.HTTP.Tower
  ( Client, newClient, runRequest, (|>)
  , withRetry, constantBackoff, withTimeout, withUserAgent
  )

import Sentinel.Types

-- | Push probe metrics to a Prometheus Pushgateway.
push :: PrometheusConfig -> AlertEvent -> IO ()
push cfg event = do
  let (probeName, isUp, latency) = extractMetrics event
  pushMetrics cfg probeName isUp latency

-- | Push metrics using a default client.
pushMetrics :: PrometheusConfig -> Text -> Bool -> Double -> IO ()
pushMetrics cfg probeName isUp latency = do
  client <- newClient
  let configured = client
        |> withRetry (constantBackoff 2 1.0)
        |> withTimeout 5000
        |> withUserAgent "sentinel/0.1.0"
  pushMetricsWith configured cfg probeName isUp latency

-- | Push metrics using a provided client.
pushMetricsWith :: Client -> PrometheusConfig -> Text -> Bool -> Double -> IO ()
pushMetricsWith client cfg probeName isUp latency = do
  let url = unpack (promPushgatewayUrl cfg)
          <> "/metrics/job/" <> unpack (promJob cfg)
          <> "/probe/" <> unpack probeName
  initReq <- HTTP.parseRequest url
  let body = formatMetrics probeName isUp latency
      req = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyBS (encodeUtf8 body)
        , HTTP.requestHeaders = [("Content-Type", "text/plain")]
        }
  _ <- runRequest client req
  pure ()

-- | Format metrics in Prometheus text exposition format.
formatMetrics :: Text -> Bool -> Double -> Text
formatMetrics probeName isUp latency =
  let upVal = if isUp then "1" else "0" :: Text
  in "# HELP sentinel_probe_up Whether the probe is up (1) or down (0)\n"
  <> "# TYPE sentinel_probe_up gauge\n"
  <> "sentinel_probe_up{probe=\"" <> probeName <> "\"} " <> upVal <> "\n"
  <> "# HELP sentinel_probe_latency_ms Probe latency in milliseconds\n"
  <> "# TYPE sentinel_probe_latency_ms gauge\n"
  <> "sentinel_probe_latency_ms{probe=\"" <> probeName <> "\"} " <> pack (show latency) <> "\n"

extractMetrics :: AlertEvent -> (Text, Bool, Double)
extractMetrics (ServiceDown name _ _)      = (name, False, 0)
extractMetrics (ServiceStillDown name _ _) = (name, False, 0)
extractMetrics (ServiceRecovered name l _) = (name, True, l)
