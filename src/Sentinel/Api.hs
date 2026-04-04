{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Sentinel.Api
  ( app
  ) where

import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map, elems)
import Data.Text (Text)
import Network.Wai (Application)
import Servant

import Sentinel.Types (ProbeResult)

type StatusAPI = "status" :> Get '[JSON] [ProbeResult]

statusServer :: TVar (Map Text ProbeResult) -> Server StatusAPI
statusServer stateVar = do
  results <- liftIO $ readTVarIO stateVar
  pure (elems results)

api :: Proxy StatusAPI
api = Proxy

app :: TVar (Map Text ProbeResult) -> Application
app stateVar = serve api (statusServer stateVar)
