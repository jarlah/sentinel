module Sentinel.Config
  ( loadConfig
  ) where

import Data.Yaml (decodeFileThrow)
import Sentinel.Types (AppConfig)

loadConfig :: FilePath -> IO AppConfig
loadConfig = decodeFileThrow
