{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.Slack
  ( notify
  , notifyWith
  , buildPayload
  ) where

import Data.Aeson (encode, object, (.=))
import Data.Text (Text, pack, unpack)
import qualified Data.ByteString.Lazy as LBS
import qualified Network.HTTP.Client as HTTP

import Data.Function ((&))
import Network.HTTP.Tower
  ( Client, newClient, runRequest, applyMiddleware
  , withRetry, constantBackoff, withTimeout, withUserAgent
  )

import Sentinel.Types

-- | Post an alert to a Slack webhook using a default client.
notify :: SlackConfig -> AlertEvent -> IO ()
notify cfg event = do
  client <- newClient
  let configured = client & applyMiddleware
        ( withRetry (constantBackoff 2 1.0)
        . withTimeout 5000
        . withUserAgent "sentinel/0.1.0"
        )
  notifyWith configured cfg event

-- | Post an alert to a Slack webhook using a provided client.
notifyWith :: Client -> SlackConfig -> AlertEvent -> IO ()
notifyWith client cfg event = do
  initReq <- HTTP.parseRequest (unpack (slackWebhookUrl cfg))
  let req = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (buildPayload event)
        , HTTP.requestHeaders = [("Content-Type", "application/json")]
        }
  _ <- runRequest client req
  pure ()

-- | Build the Slack webhook JSON payload.
buildPayload :: AlertEvent -> LBS.ByteString
buildPayload event = encode $ object ["text" .= formatMessage event]

formatMessage :: AlertEvent -> Text
formatMessage (ServiceDown name err _) =
  ":red_circle: *" <> name <> "* is DOWN" <> maybe "" (" — " <>) err
formatMessage (ServiceStillDown name err _) =
  ":warning: *" <> name <> "* is still DOWN" <> maybe "" (" — " <>) err
formatMessage (ServiceRecovered name latency _) =
  ":large_green_circle: *" <> name <> "* recovered (" <> pack (show (round latency :: Int)) <> "ms)"
