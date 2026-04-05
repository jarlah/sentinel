{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.EmailSpec (spec) where

import Data.Aeson (decode, Value(..))
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Key (fromText)
import qualified Data.ByteString.Lazy as LBS
import Data.IORef
import Data.Text (Text, isInfixOf)
import Data.Time.Clock (getCurrentTime)
import qualified Network.HTTP.Client as HTTP
import Test.Hspec

import Network.HTTP.Tower (HttpResponse, newClient, (|>), withMock)

import Sentinel.Alert.Email (notifyWith, buildRequestBody)
import Sentinel.Types

spec :: Spec
spec = describe "Email alerting" $ do
  let cfg = EmailConfig
        { emailApiUrl = "https://api.resend.com/emails"
        , emailApiKey = "re_test"
        , emailFrom = "sentinel@example.com"
        , emailTo = ["oncall@example.com"]
        }

  describe "buildRequestBody" $ do
    it "includes correct from address" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceDown "my-app" Nothing now)
      extractField "from" body `shouldBe` Just "sentinel@example.com"

    it "includes subject with probe name" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceDown "my-app" Nothing now)
      extractField "subject" body `shouldSatisfy` maybe False (isInfixOf "my-app")

    it "includes DOWN in subject for ServiceDown" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceDown "my-app" Nothing now)
      extractField "subject" body `shouldSatisfy` maybe False (isInfixOf "DOWN")

    it "includes 'recovered' in subject for ServiceRecovered" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceRecovered "my-app" 89.5 now)
      extractField "subject" body `shouldSatisfy` maybe False (isInfixOf "recovered")

    it "includes error in HTML body when present" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceDown "my-app" (Just "DNS failure") now)
      extractField "html" body `shouldSatisfy` maybe False (isInfixOf "DNS failure")

  describe "notifyWith" $ do
    it "sends POST to the API URL" $ do
      recorder <- newIORef []
      client <- newClient
      let mocked = client |> withMock (\req -> do
            modifyIORef' recorder (req :)
            pure (Right fakeOkResponse))
      now <- getCurrentTime
      notifyWith mocked cfg (ServiceDown "my-app" Nothing now)
      reqs <- readIORef recorder
      length reqs `shouldBe` 1
      HTTP.method (head reqs) `shouldBe` "POST"

    it "includes Authorization header with API key" $ do
      recorder <- newIORef []
      client <- newClient
      let mocked = client |> withMock (\req -> do
            modifyIORef' recorder (req :)
            pure (Right fakeOkResponse))
      now <- getCurrentTime
      notifyWith mocked cfg (ServiceDown "test" Nothing now)
      reqs <- readIORef recorder
      lookup "Authorization" (HTTP.requestHeaders (head reqs))
        `shouldBe` Just "Bearer re_test"

extractField :: Text -> LBS.ByteString -> Maybe Text
extractField field bs = do
  Object o <- decode bs
  String t <- KM.lookup (fromText field) o
  pure t

fakeOkResponse :: HttpResponse
fakeOkResponse = error "response body not evaluated in mock tests"
