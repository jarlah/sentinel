{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert.SlackSpec (spec) where

import Data.Aeson (decode, Value(..), (.:))
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text, isInfixOf)
import Data.Time.Clock (getCurrentTime)
import Test.Hspec

import Sentinel.Alert.Slack (buildPayload)
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

extractText :: LBS.ByteString -> Maybe Text
extractText bs = do
  val <- decode bs
  parseMaybe (\(Object o) -> o .: "text") val
