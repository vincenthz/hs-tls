{-# LANGUAGE CPP #-}
-- |
-- Module      : Network.TLS.Backend
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- A Backend represents a unified way to do IO on different
-- types without burdening our calling API with multiple
-- ways to initialize a new context.
--
-- Typically, a backend provides:
-- * a way to read data
-- * a way to write data
-- * a way to close the stream
-- * a way to flush the stream
--
module Network.TLS.Backend
    ( HasBackend(..)
    , Backend(..)
    , makeStreamRecvFromDgram
    , makeDgramSocketBackend
    ) where

import Network.TLS.Imports
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import System.IO (Handle, hSetBuffering, BufferMode(..), hFlush, hClose)
import Control.Concurrent.MVar

#ifdef INCLUDE_NETWORK
import qualified Network.Socket as Network (Socket, close, SockAddr)
import qualified Network.Socket.ByteString as Network
#endif

#ifdef INCLUDE_HANS
import qualified Hans.NetworkStack as Hans
#endif

-- | Connection IO backend
data Backend = Backend
    { backendFlush :: IO ()                -- ^ Flush the connection sending buffer, if any.
    , backendClose :: IO ()                -- ^ Close the connection.
    , backendSend  :: ByteString -> IO ()  -- ^ Send a bytestring through the connection.
    , backendRecv  :: Int -> IO ByteString -- ^ Receive specified number of bytes from the connection.
    }

class HasBackend a where
    initializeBackend :: a -> IO ()
    getBackend :: a -> Backend

instance HasBackend Backend where
    initializeBackend _ = return ()
    getBackend = id

#if defined(__GLASGOW_HASKELL__) && WINDOWS
-- Socket recv and accept calls on Windows platform cannot be interrupted when compiled with -threaded.
-- See https://ghc.haskell.org/trac/ghc/ticket/5797 for details.
-- The following enables simple workaround
#define SOCKET_ACCEPT_RECV_WORKAROUND
#endif

safeRecv :: Network.Socket -> Int -> IO ByteString
#ifndef SOCKET_ACCEPT_RECV_WORKAROUND
safeRecv = Network.recv
#else
safeRecv s buf = do
    var <- newEmptyMVar
    forkIO $ Network.recv s buf `E.catch` (\(_::IOException) -> return S8.empty) >>= putMVar var
    takeMVar var
#endif

-- It does not make much sense to instantiate a Backend directly from a datagram-oriented socket
-- because in order to send we need to know a peer address (unless the socket is
-- "connected"), and when we receive a datagram, there is also peer address
-- which might be useful for an application.
-- Therefore we'll just prepare a helper function which makes a recvFrom
-- to look like a regular recv from stream-oriented socket.
-- The "leftovers" argument is the contents that is to be "read out" in the first place,
-- before the actual recvFrom would occurs. This is convenient for simple (test purpose) servers
-- where we have to recvFrom to know the address of our peer.
makeStreamRecvFromDgram :: [B.ByteString] -> IO B.ByteString -> IO (Int -> IO B.ByteString)
makeStreamRecvFromDgram leftovers recvDgram = do
  buf <- newMVar $ L.fromChunks leftovers
  let recvStream len dgram = do
        b' <- takeMVar buf
        let b = b' `mappend` L.fromStrict dgram
            (nb, mr) = if L.length b >= fromIntegral len
                       then let (result, rest) = L.splitAt (fromIntegral len) b
                            in (rest, Just $ L.toStrict result)
                       else (b, Nothing)
        putMVar buf nb
        case mr of
          Just result -> return result
          Nothing -> recvDgram >>= recvStream len
  return $ \len -> recvStream len B.empty


#ifdef INCLUDE_NETWORK
instance HasBackend Network.Socket where
    initializeBackend _ = return ()
    getBackend sock = Backend (return ()) (Network.close sock) (Network.sendAll sock) recvAll
      where recvAll n = B.concat <$> loop n
              where loop 0    = return []
                    loop left = do
                        r <- safeRecv sock left
                        if B.null r
                            then return []
                            else (r:) <$> loop (left - B.length r)

-- | Create a backend from a datagram-oriented socket sock to communicate with a peer
-- whose address is specified as sockaddr
makeDgramSocketBackend :: [B.ByteString] -> Network.Socket -> Network.SockAddr -> IO Backend
makeDgramSocketBackend leftovers sock sockaddr = do
  recv' <- makeStreamRecvFromDgram leftovers $ (fst <$> Network.recvFrom sock 65535)
  let send' = \b -> Network.sendTo sock b sockaddr >> return ()
  return $ Backend (return ()) (Network.close sock) send' recv'

  
#endif

#ifdef INCLUDE_HANS
instance HasBackend Hans.Socket where
    initializeBackend _ = return ()
    getBackend sock = Backend (return ()) (Hans.close sock) sendAll recvAll
      where sendAll x = do
              amt <- fromIntegral <$> Hans.sendBytes sock (L.fromStrict x)
              if (amt == 0) || (amt == B.length x)
                 then return ()
                 else sendAll (B.drop amt x)
            recvAll n = loop (fromIntegral n) L.empty
            loop    0 acc = return (L.toStrict acc)
            loop left acc = do
                r <- Hans.recvBytes sock left
                if L.null r
                   then loop 0 acc
                   else loop (left - L.length r) (acc `L.append` r)
#endif

instance HasBackend Handle where
    initializeBackend handle = hSetBuffering handle NoBuffering
    getBackend handle = Backend (hFlush handle) (hClose handle) (B.hPut handle) (B.hGet handle)
