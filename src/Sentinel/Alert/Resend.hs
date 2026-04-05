{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.Resend
  ( notify
  , notifyWith
  , buildRequestBody
  ) where

import Data.Aeson (encode, object, (.=))
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8)
import qualified Data.ByteString.Lazy as LBS
import qualified Network.HTTP.Client as HTTP

import Network.HTTP.Tower
  ( Client, newClient, runRequest, (|>)
  , withRetry, constantBackoff, withTimeout, withUserAgent
  )

import Sentinel.Types

-- | Send an alert via the Resend API using a default client.
notify :: ResendConfig -> AlertEvent -> IO ()
notify cfg event = do
  client <- newClient
  let configured = client
        |> withRetry (constantBackoff 2 1.0)
        |> withTimeout 10000
        |> withUserAgent "sentinel/0.1.0"
  notifyWith configured cfg event

-- | Send an alert via the Resend API using a provided client.
notifyWith :: Client -> ResendConfig -> AlertEvent -> IO ()
notifyWith client cfg event = do
  initReq <- HTTP.parseRequest (unpack (resendApiUrl cfg))
  let req = initReq
        { HTTP.method = "POST"
        , HTTP.requestBody = HTTP.RequestBodyLBS (buildRequestBody cfg event)
        , HTTP.requestHeaders =
            [ ("Content-Type", "application/json")
            , ("Authorization", "Bearer " <> encodeUtf8 (resendApiKey cfg))
            ]
        }
  _ <- runRequest client req
  pure ()

-- | Build the Resend API JSON request body.
buildRequestBody :: ResendConfig -> AlertEvent -> LBS.ByteString
buildRequestBody cfg event = encode $ object
  [ "from"    .= resendFrom cfg
  , "to"      .= resendTo cfg
  , "subject" .= subject event
  , "html"    .= htmlBody event
  ]

subject :: AlertEvent -> Text
subject (ServiceDown name _ _)      = "[Sentinel] " <> name <> " is DOWN"
subject (ServiceStillDown name _ _) = "[Sentinel] " <> name <> " still DOWN"
subject (ServiceRecovered name _ _) = "[Sentinel] " <> name <> " recovered"

htmlBody :: AlertEvent -> Text
htmlBody (ServiceDown name err t) =
  "<h2>" <> name <> " is DOWN</h2>"
  <> "<p>Time: " <> pack (show t) <> "</p>"
  <> maybe "" (\e -> "<p>Error: " <> e <> "</p>") err
htmlBody (ServiceStillDown name err t) =
  "<h2>" <> name <> " is still DOWN</h2>"
  <> "<p>Time: " <> pack (show t) <> "</p>"
  <> maybe "" (\e -> "<p>Error: " <> e <> "</p>") err
htmlBody (ServiceRecovered name latency t) =
  "<h2>" <> name <> " recovered</h2>"
  <> "<p>Time: " <> pack (show t) <> "</p>"
  <> "<p>Latency: " <> pack (show (round latency :: Int)) <> "ms</p>"
