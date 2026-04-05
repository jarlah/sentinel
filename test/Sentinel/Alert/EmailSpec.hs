{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.EmailSpec (spec) where

import Data.Aeson (decode, Value(..))
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Key (fromText)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text, isInfixOf)
import Data.Time.Clock (getCurrentTime)
import Test.Hspec

import Sentinel.Alert.Email (buildRequestBody)
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
          subj = extractField "subject" body
      subj `shouldSatisfy` maybe False (isInfixOf "my-app")

    it "includes DOWN in subject for ServiceDown" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceDown "my-app" Nothing now)
          subj = extractField "subject" body
      subj `shouldSatisfy` maybe False (isInfixOf "DOWN")

    it "includes 'recovered' in subject for ServiceRecovered" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceRecovered "my-app" 89.5 now)
          subj = extractField "subject" body
      subj `shouldSatisfy` maybe False (isInfixOf "recovered")

    it "includes error in HTML body when present" $ do
      now <- getCurrentTime
      let body = buildRequestBody cfg (ServiceDown "my-app" (Just "DNS failure") now)
          html = extractField "html" body
      html `shouldSatisfy` maybe False (isInfixOf "DNS failure")

extractField :: Text -> LBS.ByteString -> Maybe Text
extractField field bs = do
  Object o <- decode bs
  String t <- KM.lookup (fromText field) o
  pure t
