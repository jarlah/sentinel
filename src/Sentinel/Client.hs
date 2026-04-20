module Sentinel.Client
  ( makeAlertClient
  ) where

import Network.HTTP.Tower
  ( Client, newClient, applyMiddleware
  , withRetry, constantBackoff, withTimeout, withUserAgent
  )
import Sentinel.Version (userAgent)
import Data.Function ((&))

makeAlertClient :: Int -> IO Client                                                                                                                                                                               
makeAlertClient ms = do
    client <- newClient                                                                                                                                                                                             
    pure $ client & applyMiddleware                                                                                                                                                                               
        ( withRetry (constantBackoff 2 1.0)                                                                                                                                                                           
        . withTimeout ms
        . withUserAgent userAgent                                                                                                                                                                                     
        )  
  