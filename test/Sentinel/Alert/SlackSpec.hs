{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.SlackSpec (spec) where

import Data.Aeson (decode, Value(..), (.:))
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import Data.IORef
import Data.Text (Text, isInfixOf)
import Data.Time.Clock (getCurrentTime)
import qualified Network.HTTP.Client as HTTP
import Test.Hspec

import Network.HTTP.Tower (HttpResponse, newClient, (|>), withMock)

import Sentinel.Alert.Slack (notifyWith, buildPayload)
import Sentinel.Types

spec :: Spec
spec = describe "Slack alerting" $ do
  describe "buildPayload" $ do
    it "includes probe name in ServiceDown message" $ do
      now <- getCurrentTime
      let text = extractText (buildPayload (ServiceDown "my-app" (Just "timeout") now))
      text `shouldSatisfy` maybe False (isInfixOf "my-app")

    it "includes DOWN in ServiceDown message" $ do
      now <- getCurrentTime
      let text = extractText (buildPayload (ServiceDown "my-app" Nothing now))
      text `shouldSatisfy` maybe False (isInfixOf "DOWN")

    it "includes 'still DOWN' in reminder" $ do
      now <- getCurrentTime
      let text = extractText (buildPayload (ServiceStillDown "my-app" Nothing now))
      text `shouldSatisfy` maybe False (isInfixOf "still DOWN")

    it "includes 'recovered' in recovery message" $ do
      now <- getCurrentTime
      let text = extractText (buildPayload (ServiceRecovered "my-app" 89.5 now))
      text `shouldSatisfy` maybe False (isInfixOf "recovered")

    it "includes error message when present" $ do
      now <- getCurrentTime
      let text = extractText (buildPayload (ServiceDown "my-app" (Just "connection refused") now))
      text `shouldSatisfy` maybe False (isInfixOf "connection refused")

  describe "notifyWith" $ do
    it "sends POST to the webhook URL" $ do
      recorder <- newIORef []
      client <- newClient
      let mocked = client |> withMock (\req -> do
            modifyIORef' recorder (req :)
            pure (Right fakeOkResponse))
          cfg = SlackConfig "http://hooks.example.com/slack"
      now <- getCurrentTime
      notifyWith mocked cfg (ServiceDown "my-app" Nothing now)
      reqs <- readIORef recorder
      length reqs `shouldBe` 1
      HTTP.method (head reqs) `shouldBe` "POST"
      HTTP.host (head reqs) `shouldBe` "hooks.example.com"

    it "sends JSON content type" $ do
      recorder <- newIORef []
      client <- newClient
      let mocked = client |> withMock (\req -> do
            modifyIORef' recorder (req :)
            pure (Right fakeOkResponse))
          cfg = SlackConfig "http://hooks.example.com/slack"
      now <- getCurrentTime
      notifyWith mocked cfg (ServiceDown "test" Nothing now)
      reqs <- readIORef recorder
      lookup "Content-Type" (HTTP.requestHeaders (head reqs)) `shouldBe` Just "application/json"

extractText :: LBS.ByteString -> Maybe Text
extractText bs = do
  val <- decode bs
  parseMaybe (\(Object o) -> o .: "text") val

fakeOkResponse :: HttpResponse
fakeOkResponse = error "response body not evaluated in mock tests"
