{-# LANGUAGE OverloadedStrings #-}

module Sentinel.AlertSpec (spec) where

import Data.Text (Text)
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Test.Hspec

import Sentinel.Alert (checkAndAlert)
import Sentinel.Types

spec :: Spec
spec = describe "Alert state machine" $ do
  let alertCfg = AlertingConfig Nothing Nothing Nothing  -- no channels configured
      probeCfg = (minimalProbe "test") { probeAlertAfter = 2, probeAlertReminder = 0 }

  describe "Up -> Down transition" $ do
    it "does not alert before alert_after threshold" $ do
      now <- getCurrentTime
      let result = downResult "test" now
      newState <- checkAndAlert alertCfg probeCfg defaultProbeState result
      psAlerted newState `shouldBe` False
      psConsecutiveFails newState `shouldBe` 1

    it "alerts after reaching alert_after threshold" $ do
      now <- getCurrentTime
      let result = downResult "test" now
          stateWith1Fail = defaultProbeState
            { psLastStatus = Down, psConsecutiveFails = 1 }
      newState <- checkAndAlert alertCfg probeCfg stateWith1Fail result
      psAlerted newState `shouldBe` True
      psConsecutiveFails newState `shouldBe` 2

  describe "Down -> Down (no reminder)" $ do
    it "does not re-alert when already alerted and no reminder configured" $ do
      now <- getCurrentTime
      let result = downResult "test" now
          alertedState = ProbeState Down 5 True (Just now)
      newState <- checkAndAlert alertCfg probeCfg alertedState result
      -- Still alerted, but lastAlertAt should NOT change (no new alert)
      psAlerted newState `shouldBe` True
      psLastAlertAt newState `shouldBe` Just now

  describe "Down -> Down (with reminder)" $ do
    it "sends reminder after interval elapsed" $ do
      now <- getCurrentTime
      let longAgo = addUTCTime (-7200) now  -- 2 hours ago
          result = downResult "test" now
          probeCfgReminder = probeCfg { probeAlertReminder = 3600 }
          alertedState = ProbeState Down 5 True (Just longAgo)
      newState <- checkAndAlert alertCfg probeCfgReminder alertedState result
      -- lastAlertAt should update to now (reminder sent)
      psLastAlertAt newState `shouldBe` Just now

    it "does not send reminder before interval" $ do
      now <- getCurrentTime
      let recent = addUTCTime (-60) now  -- 1 minute ago
          result = downResult "test" now
          probeCfgReminder = probeCfg { probeAlertReminder = 3600 }
          alertedState = ProbeState Down 5 True (Just recent)
      newState <- checkAndAlert alertCfg probeCfgReminder alertedState result
      -- lastAlertAt should NOT change
      psLastAlertAt newState `shouldBe` Just recent

  describe "Down -> Up recovery" $ do
    it "fires recovery alert and resets state" $ do
      now <- getCurrentTime
      let result = upResult "test" now
          downState = ProbeState Down 3 True (Just now)
      newState <- checkAndAlert alertCfg probeCfg downState result
      psLastStatus newState `shouldBe` Up
      psConsecutiveFails newState `shouldBe` 0
      psAlerted newState `shouldBe` False

    it "does not fire recovery if never alerted" $ do
      now <- getCurrentTime
      let result = upResult "test" now
          downNoAlert = ProbeState Down 1 False Nothing
      newState <- checkAndAlert alertCfg probeCfg downNoAlert result
      psLastStatus newState `shouldBe` Up
      psAlerted newState `shouldBe` False

  describe "Up -> Up (stable)" $ do
    it "stays in default state" $ do
      now <- getCurrentTime
      let result = upResult "test" now
      newState <- checkAndAlert alertCfg probeCfg defaultProbeState result
      newState `shouldBe` defaultProbeState

-- Helpers

minimalProbe :: Text -> ProbeConfig
minimalProbe name = ProbeConfig
  { probeName = name
  , probeUrl = "http://example.com"
  , probeInterval = 30
  , probeTimeout = Nothing
  , probeRetries = Nothing
  , probeFollowRedirects = Nothing
  , probeExpectedStatus = Nothing
  , probeCircuitBreaker = Nothing
  , probeHeaders = []
  , probeAlertAfter = 1
  , probeAlertReminder = 0
  , probeAlerts = Nothing
  , probeTlsCaPath = Nothing
  , probeTlsClientCert = Nothing
  , probeTlsClientKey = Nothing
  }

downResult :: Text -> UTCTime -> ProbeResult
downResult name = ProbeResult name Down 0 (Just "connection refused")

upResult :: Text -> UTCTime -> ProbeResult
upResult name = ProbeResult name Up 89.5 Nothing
