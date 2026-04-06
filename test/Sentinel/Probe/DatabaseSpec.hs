{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.Probe.DatabaseSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import Data.Text (pack)
import qualified Data.Text.Lazy as LT
import qualified Data.Map.Strict as Map
import System.Process (readProcess)
import Test.Hspec

import qualified TestContainers as TC
import TestContainers.Hspec (withContainers)

import Sentinel.Probe.Database (runDbProbe)
import Sentinel.Types

dockerAvailable :: IO Bool
dockerAvailable = do
  result <- try (readProcess "docker" ["info"] "") :: IO (Either SomeException String)
  pure $ case result of
    Right _ -> True
    Left _  -> False

spec :: Spec
spec = describe "Database probes (Docker)" $ beforeAll dockerAvailable $ do

  describe "PostgreSQL" $ do
    it "returns Up for a healthy Postgres instance" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else withContainers setupPostgres $ \port -> do
          threadDelay 5_000_000  -- wait for postgres to fully initialize
          let config = pgProbe port
          result <- runDbProbe Map.empty config
          resultStatus result `shouldBe` Up

    it "returns Down for an unreachable Postgres" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else do
          let config = ProbeConfig
                { probeName = "bad-pg"
                , probeKind = PostgresProbe "host=localhost port=59999 dbname=nonexistent connect_timeout=1"
                , probeInterval = 30
                , probeTimeout = Just 3000
                , probeRetries = Nothing
                , probeCircuitBreaker = Nothing
                , probeAlertAfter = 1
                , probeAlertReminder = 0
                , probeAlerts = Nothing
                }
          result <- runDbProbe Map.empty config
          resultStatus result `shouldBe` Down

  describe "MySQL" $ do
    it "returns Up for a healthy MySQL instance" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else withContainers setupMySQL $ \port -> do
          threadDelay 10_000_000  -- wait for MariaDB to fully initialize
          let config = mysqlProbe port
          result <- runDbProbe Map.empty config
          resultStatus result `shouldBe` Up

    it "returns Down for an unreachable MySQL" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else do
          let config = ProbeConfig
                { probeName = "bad-mysql"
                , probeKind = MySQLProbe MySQLProbeConfig
                    { mysqlHost = "localhost"
                    , mysqlPort = 59_997
                    , mysqlUser = "root"
                    , mysqlPassword = "testpass"
                    , mysqlDatabase = "testdb"
                    }
                , probeInterval = 30
                , probeTimeout = Just 3000
                , probeRetries = Nothing
                , probeCircuitBreaker = Nothing
                , probeAlertAfter = 1
                , probeAlertReminder = 0
                , probeAlerts = Nothing
                }
          result <- runDbProbe Map.empty config
          resultStatus result `shouldBe` Down

  describe "Redis" $ do
    it "returns Up for a healthy Redis instance" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else withContainers setupRedis $ \port -> do
          threadDelay 1_000_000
          let config = redisProbe port
          result <- runDbProbe Map.empty config
          resultStatus result `shouldBe` Up

    it "returns Down for an unreachable Redis" $ \isAvailable -> do
      if not isAvailable
        then pendingWith "Docker not available"
        else do
          let config = ProbeConfig
                { probeName = "bad-redis"
                , probeKind = RedisProbe "redis://localhost:59998"
                , probeInterval = 30
                , probeTimeout = Just 3000
                , probeRetries = Nothing
                , probeCircuitBreaker = Nothing
                , probeAlertAfter = 1
                , probeAlertReminder = 0
                , probeAlerts = Nothing
                }
          result <- runDbProbe Map.empty config
          resultStatus result `shouldBe` Down

-- Test containers

setupPostgres :: TC.TestContainer Int
setupPostgres = do
  container <- TC.run $ TC.containerRequest (TC.fromTag "postgres:16-alpine")
    TC.& TC.setExpose [5432]
    TC.& TC.setEnv [("POSTGRES_PASSWORD", "testpass"), ("POSTGRES_DB", "testdb")]
    TC.& TC.setWaitingFor (TC.waitUntilTimeout 60
      (TC.waitForLogLine TC.Stderr (LT.isInfixOf "database system is ready to accept connections")))
  pure (TC.containerPort container 5432)

setupMySQL :: TC.TestContainer Int
setupMySQL = do
  container <- TC.run $ TC.containerRequest (TC.fromTag "mariadb:10.11")
    TC.& TC.setExpose [3306]
    TC.& TC.setEnv [ ("MARIADB_ROOT_PASSWORD", "testpass")
                   , ("MARIADB_DATABASE", "testdb")
                   ]
    TC.& TC.setWaitingFor (TC.waitUntilTimeout 120
      (TC.waitUntilMappedPortReachable 3306))
  pure (TC.containerPort container 3306)

setupRedis :: TC.TestContainer Int
setupRedis = do
  container <- TC.run $ TC.containerRequest (TC.fromTag "redis:7-alpine")
    TC.& TC.setExpose [6379]
    TC.& TC.setWaitingFor (TC.waitUntilTimeout 30 (TC.waitUntilMappedPortReachable 6379))
  pure (TC.containerPort container 6379)

-- Test probe configs

pgProbe :: Int -> ProbeConfig
pgProbe port = ProbeConfig
  { probeName = "test-pg"
  , probeKind = PostgresProbe $
      "host=localhost port=" <> pack (show port) <> " dbname=testdb user=postgres password=testpass"
  , probeInterval = 30
  , probeTimeout = Just 5000
  , probeRetries = Nothing
  , probeCircuitBreaker = Nothing
  , probeAlertAfter = 1
  , probeAlertReminder = 0
  , probeAlerts = Nothing
  }

mysqlProbe :: Int -> ProbeConfig
mysqlProbe port = ProbeConfig
  { probeName = "test-mysql"
  , probeKind = MySQLProbe MySQLProbeConfig
      { mysqlHost = "localhost"
      , mysqlPort = port
      , mysqlUser = "root"
      , mysqlPassword = "testpass"
      , mysqlDatabase = "testdb"
      }
  , probeInterval = 30
  , probeTimeout = Just 5000
  , probeRetries = Nothing
  , probeCircuitBreaker = Nothing
  , probeAlertAfter = 1
  , probeAlertReminder = 0
  , probeAlerts = Nothing
  }

redisProbe :: Int -> ProbeConfig
redisProbe port = ProbeConfig
  { probeName = "test-redis"
  , probeKind = RedisProbe $ "redis://localhost:" <> pack (show port)
  , probeInterval = 30
  , probeTimeout = Just 5000
  , probeRetries = Nothing
  , probeCircuitBreaker = Nothing
  , probeAlertAfter = 1
  , probeAlertReminder = 0
  , probeAlerts = Nothing
  }
