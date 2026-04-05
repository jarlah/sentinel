{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Alert
  ( checkAndAlert
  , dispatch
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (try, SomeException)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, NominalDiffTime, diffUTCTime)

import Sentinel.Types
import qualified Sentinel.Alert.Slack as Slack
import qualified Sentinel.Alert.Resend as Resend
import qualified Sentinel.Alert.Prometheus as Prom

-- | Check probe result against previous state, return updated state and
-- maybe fire alerts. Alerts are dispatched asynchronously.
checkAndAlert
  :: AlertingConfig
  -> ProbeConfig
  -> ProbeState
  -> ProbeResult
  -> IO ProbeState
checkAndAlert alertCfg probeCfg prevState result = do
  let now = resultCheckedAt result
      event = detectEvent probeCfg prevState result now
      newState = updateState prevState result now event

  case event of
    Just evt -> do
      -- Fire alerts in background — don't block the probe loop
      _ <- forkIO $ do
        _ <- try (dispatch alertCfg probeCfg evt) :: IO (Either SomeException ())
        pure ()
      pure newState
    Nothing -> pure newState

-- | Detect what alert event (if any) should fire.
detectEvent :: ProbeConfig -> ProbeState -> ProbeResult -> UTCTime -> Maybe AlertEvent
detectEvent probeCfg prevState result now =
  case resultStatus result of
    Down ->
      let fails = psConsecutiveFails prevState + 1
      in if not (psAlerted prevState) && fails >= probeAlertAfter probeCfg
        -- First alert: threshold reached
        then Just (ServiceDown (resultName result) (resultError result) now)
        -- Already alerted — check reminder
        else if psAlerted prevState && probeAlertReminder probeCfg > 0
          then case psLastAlertAt prevState of
            Just lastAlert
              | diffUTCTime now lastAlert >= fromIntegral (probeAlertReminder probeCfg) ->
                  Just (ServiceStillDown (resultName result) (resultError result) now)
            _ -> Nothing
          else Nothing
    Up ->
      if psLastStatus prevState == Down && psAlerted prevState
        then Just (ServiceRecovered (resultName result) (resultLatencyMs result) now)
        else Nothing

-- | Update probe state based on the result and event.
updateState :: ProbeState -> ProbeResult -> UTCTime -> Maybe AlertEvent -> ProbeState
updateState prevState result now event =
  case resultStatus result of
    Up -> defaultProbeState
    Down -> ProbeState
      { psLastStatus       = Down
      , psConsecutiveFails = psConsecutiveFails prevState + 1
      , psAlerted          = psAlerted prevState || isDownEvent event
      , psLastAlertAt      = case event of
          Just _ -> Just now
          Nothing -> psLastAlertAt prevState
      }
  where
    isDownEvent (Just ServiceDown{})      = True
    isDownEvent (Just ServiceStillDown{}) = True
    isDownEvent _                         = False

-- | Dispatch an alert event to all configured (and probe-enabled) channels.
dispatch :: AlertingConfig -> ProbeConfig -> AlertEvent -> IO ()
dispatch alertCfg probeCfg event = do
  let channels = probeAlerts probeCfg
      enabled name = maybe True (elem name) channels

  case alertSlack alertCfg of
    Just cfg | enabled "slack" -> Slack.notify cfg event
    _ -> pure ()

  case alertResend alertCfg of
    Just cfg | enabled "resend" -> Resend.notify cfg event
    _ -> pure ()

  -- Prometheus always pushes (metrics, not alerts per se)
  case alertPrometheus alertCfg of
    Just cfg | enabled "prometheus" -> Prom.push cfg event
    _ -> pure ()
