{-# LANGUAGE OverloadedStrings #-}

module Sentinel.Version
  ( userAgent
  ) where

import Data.Text (Text, pack)
import Data.Text.Encoding (encodeUtf8)
import Data.Version (showVersion)
import qualified Data.ByteString as BS

import Paths_sentinel (version)

userAgent :: BS.ByteString
userAgent = encodeUtf8 ("sentinel/" <> pack (showVersion version))
