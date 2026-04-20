{-# LANGUAGE OverloadedStrings #-}

module Sentinel.ReportSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (isInfixOf)
import Data.Time.Calendar (DayOfWeek(..))
import Data.Time.Clock (getCurrentTime)
import Test.Hspec

import Sentinel.Report (buildReport, isReportDay)
import Sentinel.Types

spec :: Spec
spec = describe "Status report" $ do
  describe "isReportDay" $ do
    it "returns True for Monday" $
      isReportDay Monday `shouldBe` True

    it "returns True for Friday" $
      isReportDay Friday `shouldBe` True

    it "returns False for other days" $ do
      isReportDay Tuesday `shouldBe` False
      isReportDay Wednesday `shouldBe` False
      isReportDay Thursday `shouldBe` False
      isReportDay Saturday `shouldBe` False
      isReportDay Sunday `shouldBe` False

  describe "buildReport" $ do
    it "reports no downtime when no events" $ do
      let (subj, body) = buildReport Map.empty []
      isInfixOf "No downtime" subj `shouldBe` True
      isInfixOf "operational" body `shouldBe` True

    it "reports downtime when events present" $ do
      now <- getCurrentTime
      let events = [ServiceDown "my-app" (Just "timeout") now]
          (subj, body) = buildReport Map.empty events
      isInfixOf "Downtime detected" subj `shouldBe` True
      isInfixOf "my-app" body `shouldBe` True
      isInfixOf "timeout" body `shouldBe` True

    it "includes recovery events" $ do
      now <- getCurrentTime
      let events = [ServiceRecovered "my-app" 89.5 now]
          (_, body) = buildReport Map.empty events
      isInfixOf "recovered" body `shouldBe` True

    it "includes current probe status" $ do
      now <- getCurrentTime
      let results = Map.singleton "test-probe" ProbeResult
            { resultName = "test-probe"
            , resultStatus = Up
            , resultLatencyMs = 42.0
            , resultError = Nothing
            , resultCheckedAt = now
            }
          (_, body) = buildReport results []
      isInfixOf "test-probe" body `shouldBe` True
      isInfixOf "Up" body `shouldBe` True

    it "shows down probes in current status" $ do
      now <- getCurrentTime
      let results = Map.singleton "failing" ProbeResult
            { resultName = "failing"
            , resultStatus = Down
            , resultLatencyMs = 5000.0
            , resultError = Just "Connection refused"
            , resultCheckedAt = now
            }
          (_, body) = buildReport results []
      isInfixOf "failing" body `shouldBe` True
      isInfixOf "Down" body `shouldBe` True
