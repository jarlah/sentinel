{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Sentinel.ProbeSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (try, SomeException)
import Data.Text (pack)
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing)
import System.Process (callCommand, readProcess)
import Test.Hspec

import qualified TestContainers as TC
import TestContainers.Hspec (withContainers)

import Sentinel.Probe (runProbe, ProbeEnv(..), initProbeEnv)
import Sentinel.Types

-- | Generate test certificates: CA, server cert, client cert.
generateCerts :: FilePath -> IO ()
generateCerts dir = do
  createDirectoryIfMissing True dir
  -- CA
  callCommand $ "openssl genrsa -out " <> dir <> "/ca-key.pem 2048 2>/dev/null"
  callCommand $ "openssl req -new -x509 -key " <> dir <> "/ca-key.pem"
    <> " -out " <> dir <> "/ca.pem -days 1 -subj '/CN=Test CA' 2>/dev/null"
  -- Server (signed by CA, with SAN for localhost)
  callCommand $ "openssl genrsa -out " <> dir <> "/server-key.pem 2048 2>/dev/null"
  callCommand $ "openssl req -new -key " <> dir <> "/server-key.pem"
    <> " -out " <> dir <> "/server.csr -subj '/CN=localhost' 2>/dev/null"
  writeFile (dir <> "/san.cnf") $ unlines
    [ "[v3_req]"
    , "subjectAltName = DNS:localhost,IP:127.0.0.1"
    ]
  callCommand $ "openssl x509 -req -in " <> dir <> "/server.csr"
    <> " -CA " <> dir <> "/ca.pem -CAkey " <> dir <> "/ca-key.pem"
    <> " -CAcreateserial -out " <> dir <> "/server.pem -days 1"
    <> " -extensions v3_req -extfile " <> dir <> "/san.cnf 2>/dev/null"
  -- Client (signed by CA)
  callCommand $ "openssl genrsa -out " <> dir <> "/client-key.pem 2048 2>/dev/null"
  callCommand $ "openssl req -new -key " <> dir <> "/client-key.pem"
    <> " -out " <> dir <> "/client.csr -subj '/CN=Test Client' 2>/dev/null"
  callCommand $ "openssl x509 -req -in " <> dir <> "/client.csr"
    <> " -CA " <> dir <> "/ca.pem -CAkey " <> dir <> "/ca-key.pem"
    <> " -CAcreateserial -out " <> dir <> "/client.pem -days 1 2>/dev/null"

nginxConf :: String
nginxConf = unlines
  [ "events { worker_connections 64; }"
  , "http {"
  , "  server {"
  , "    listen 443 ssl;"
  , "    ssl_certificate /certs/server.pem;"
  , "    ssl_certificate_key /certs/server-key.pem;"
  , "    ssl_client_certificate /certs/ca.pem;"
  , "    ssl_verify_client on;"
  , "    location / { return 200 'mTLS OK'; }"
  , "  }"
  , "}"
  ]

dockerAvailable :: IO Bool
dockerAvailable = do
  result <- try (readProcess "docker" ["info"] "") :: IO (Either SomeException String)
  pure $ case result of
    Right _ -> True
    Left _  -> False

certDir :: FilePath
certDir = "/tmp/sentinel-test-certs"

spec :: Spec
spec = describe "Probe mTLS (Docker)" $ beforeAll dockerAvailable $ do

  it "succeeds with mTLS client cert" $ \isAvailable -> do
    if not isAvailable
      then pendingWith "Docker not available"
      else do
        generateCerts certDir
        writeFile (certDir <> "/nginx.conf") nginxConf

        withContainers (setupNginx certDir) $ \port -> do
          threadDelay 2_000_000

          let config = (mtlsProbe port)
                { probeTlsCaPath = Just (certDir <> "/ca.pem")
                , probeTlsClientCert = Just (certDir <> "/client.pem")
                , probeTlsClientKey = Just (certDir <> "/client-key.pem")
                }
          env <- initProbeEnv [config]
          result <- runProbe env defaultAppConfig config
          resultStatus result `shouldBe` Up

  it "fails without client cert when mTLS is required" $ \isAvailable -> do
    if not isAvailable
      then pendingWith "Docker not available"
      else do
        generateCerts certDir
        writeFile (certDir <> "/nginx.conf") nginxConf

        withContainers (setupNginx certDir) $ \port -> do
          threadDelay 2_000_000

          let config = (mtlsProbe port)
                { probeTlsCaPath = Just (certDir <> "/ca.pem")
                , probeTlsClientCert = Nothing
                , probeTlsClientKey = Nothing
                , probeExpectedStatus = Just (200, 299)
                }
          env <- initProbeEnv [config]
          result <- runProbe env defaultAppConfig config
          resultStatus result `shouldBe` Down

setupNginx :: FilePath -> TC.TestContainer Int
setupNginx dir = do
  container <- TC.run $ TC.containerRequest (TC.fromTag "nginx:alpine")
    TC.& TC.setExpose [443]
    TC.& TC.setVolumeMounts
        [ (pack dir, "/certs")
        , (pack (dir <> "/nginx.conf"), "/etc/nginx/nginx.conf")
        ]
    TC.& TC.setWaitingFor (TC.waitUntilTimeout 30 (TC.waitUntilMappedPortReachable 443))
  pure (TC.containerPort container 443)

mtlsProbe :: Int -> ProbeConfig
mtlsProbe port = ProbeConfig
  { probeName = "mtls-test"
  , probeUrl = "https://localhost:" <> pack (show port) <> "/"
  , probeInterval = 30
  , probeTimeout = Just 10000
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

defaultAppConfig :: AppConfig
defaultAppConfig = AppConfig
  { configPort = 8080
  , configProbes = []
  , configTracing = False
  , configAlerting = Nothing
  }
