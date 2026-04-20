{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.Report
  ( startReportLoop
  , buildReport
  , isReportDay
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO, atomically, readTVar, writeTVar)
import Control.Exception (SomeException, try)
import Control.Monad (forever, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text, pack)
import Data.Time.Calendar (Day, DayOfWeek(..), dayOfWeek)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, utcToLocalTime, localDay, localTimeOfDay, todHour)

import Sentinel.Types
import qualified Sentinel.Alert.Resend as Resend

startReportLoop
  :: ResendConfig
  -> TVar (Map Text ProbeResult)
  -> TVar [AlertEvent]
  -> IO ()
startReportLoop resendCfg resultsVar eventsVar = do
  lastSentVar <- newTVarIO (Nothing :: Maybe Day)
  putStrLn "Status report: enabled (Monday and Friday)"
  forever $ do
    threadDelay 60_000_000
    now <- getCurrentTime
    tz <- getCurrentTimeZone
    let localTime = utcToLocalTime tz now
        today = localDay localTime
        hour = todHour (localTimeOfDay localTime)
        dow = dayOfWeek today

    lastSent <- readTVarIO lastSentVar

    when (isReportDay dow && hour >= 8 && lastSent /= Just today) $ do
      results <- readTVarIO resultsVar
      events <- atomically $ do
        evts <- readTVar eventsVar
        writeTVar eventsVar []
        pure evts

      let (emailSubject, emailBody) = buildReport results events
      putStrLn $ "Sending status report: " <> show emailSubject
      _ <- try (Resend.sendEmail resendCfg emailSubject emailBody) :: IO (Either SomeException ())
      atomically $ writeTVar lastSentVar (Just today)

isReportDay :: DayOfWeek -> Bool
isReportDay Monday = True
isReportDay Friday = True
isReportDay _      = False

buildReport :: Map Text ProbeResult -> [AlertEvent] -> (Text, Text)
buildReport results events =
  let hasDowntime = not (null events)
      subj = if hasDowntime
        then "[Sentinel] Status Report \x2014 Downtime detected"
        else "[Sentinel] Status Report \x2014 No downtime"
      body = reportHtml results events hasDowntime
  in (subj, body)

reportHtml :: Map Text ProbeResult -> [AlertEvent] -> Bool -> Text
reportHtml results events hasDowntime =
  "<h2>Sentinel Status Report</h2>"
  <> if hasDowntime
     then "<p style=\"color:#c0392b;\">Downtime was detected since the last report.</p>"
       <> "<h3>Incidents</h3><ul>" <> foldMap eventItem (reverse events) <> "</ul>"
     else "<p style=\"color:#27ae60;\">All monitored services have been operational since the last report.</p>"
  <> probeStatusTable results

probeStatusTable :: Map Text ProbeResult -> Text
probeStatusTable results
  | Map.null results = ""
  | otherwise =
      "<h3>Current Probe Status</h3>"
      <> "<table style=\"border-collapse:collapse;width:100%;\">"
      <> "<tr style=\"background:#f5f5f5;\">"
      <> th "Probe" <> th "Status" <> th "Latency" <> th "Last Checked"
      <> "</tr>"
      <> foldMap probeRow (Map.elems results)
      <> "</table>"
  where
    th label = "<th style=\"padding:8px;text-align:left;border:1px solid #ddd;\">" <> label <> "</th>"

probeRow :: ProbeResult -> Text
probeRow r =
  let statusText = case resultStatus r of
        Up   -> "<span style=\"color:#27ae60;\">Up</span>"
        Down -> "<span style=\"color:#c0392b;\">Down</span>"
  in "<tr>"
  <> td (resultName r)
  <> td statusText
  <> td (pack (show (round (resultLatencyMs r) :: Int)) <> "ms")
  <> td (pack (show (resultCheckedAt r)))
  <> "</tr>"
  where
    td content = "<td style=\"padding:8px;border:1px solid #ddd;\">" <> content <> "</td>"

eventItem :: AlertEvent -> Text
eventItem (ServiceDown name err t) =
  "<li><strong>" <> name <> "</strong> went DOWN at " <> pack (show t)
  <> maybe "" (\e -> " &mdash; " <> e) err <> "</li>"
eventItem (ServiceStillDown name err t) =
  "<li><strong>" <> name <> "</strong> still DOWN at " <> pack (show t)
  <> maybe "" (\e -> " &mdash; " <> e) err <> "</li>"
eventItem (ServiceRecovered name latency t) =
  "<li><strong>" <> name <> "</strong> recovered at " <> pack (show t)
  <> " (latency: " <> pack (show (round latency :: Int)) <> "ms)</li>"
