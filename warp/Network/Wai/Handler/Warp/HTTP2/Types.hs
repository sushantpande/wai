{-# LANGUAGE OverloadedStrings #-}

module Network.Wai.Handler.Warp.HTTP2.Types where

import Control.Applicative ((<$>),(<*>))
import Control.Concurrent
import Control.Concurrent.STM
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef)
import qualified Data.IntMap.Strict as M
import Data.IntMap.Strict (IntMap)
import qualified Network.HTTP.Types as H
import Network.Wai (Request)
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HPACK

----------------------------------------------------------------

http2ver :: H.HttpVersion
http2ver = H.HttpVersion 2 0

isHTTP2 :: Transport -> Bool
isHTTP2 TCP = False
isHTTP2 tls = useHTTP2
  where
    useHTTP2 = case tlsNegotiatedProtocol tls of
        Nothing    -> False
        Just proto -> "h2-" `BS.isPrefixOf` proto

----------------------------------------------------------------

data Input = Input Stream Request

data Context = Context {
    http2settings      :: IORef Settings
  , streamTable        :: IORef (IntMap Stream)
  , concurrency        :: IORef Int
  , continued          :: IORef (Maybe StreamIdentifier)
  , currentStreamId    :: IORef Int
  , inputQ             :: TQueue Input
  , outputQ            :: TQueue ByteString
  , encodeDynamicTable :: IORef DynamicTable
  , decodeDynamicTable :: IORef DynamicTable
  , wait               :: MVar ()
  }

----------------------------------------------------------------

newContext :: IO Context
newContext = Context <$> newIORef defaultSettings
                     <*> newIORef M.empty
                     <*> newIORef 0
                     <*> newIORef Nothing
                     <*> newIORef 0
                     <*> newTQueueIO
                     <*> newTQueueIO
                     <*> (newDynamicTableForEncoding 4096 >>= newIORef)
                     <*> (newDynamicTableForDecoding 4096 >>= newIORef)
                     <*> newEmptyMVar

----------------------------------------------------------------

data StreamState =
    Idle
  | Continued [HeaderBlockFragment] Bool
  | NoBody HeaderList
  | HasBody HeaderList
  | Body (TQueue ByteString)
  | HalfClosed
  | Closed

instance Show StreamState where
    show Idle            = "Idle"
    show (Continued _ _) = "Continued"
    show (NoBody  _)     = "NoBody"
    show (HasBody _)     = "HasBody"
    show (Body _)        = "Body"
    show HalfClosed      = "HalfClosed"
    show Closed          = "Closed"

----------------------------------------------------------------

data Activity = Active | Inactive

data Stream = Stream {
    streamNumber        :: Int
  , streamState         :: IORef StreamState
  , streamActivity      :: IORef Activity
  , streamTimeoutAction :: IORef (IO ())
  , streamContentLength :: IORef (Maybe Int)
  , streamBodyLength    :: IORef Int
  }

newStream :: Int -> IO Stream
newStream sid = Stream sid <$> newIORef Idle
                           <*> newIORef Active
                           <*> newIORef (return ())
                           <*> newIORef Nothing
                           <*> newIORef 0

----------------------------------------------------------------

defaultConcurrency :: Int
defaultConcurrency = 100
