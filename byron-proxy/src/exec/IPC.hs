{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}

module IPC where

import qualified Codec.CBOR.Write as CBOR (toStrictByteString)
import Codec.Serialise (Serialise (..), deserialiseOrFail)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (STM)
import Control.Exception (SomeException, bracket, catch, throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Resource (ResourceT, runResourceT)
import Control.Tracer (Tracer (..), contramap, nullTracer, traceWith)
import qualified Data.ByteString.Lazy as Lazy (ByteString, fromStrict)
import qualified Data.ByteString.Lazy.Char8 as Lazy (pack)
import Data.Either (either)
import qualified Data.Map as Map

import Network.TypedProtocol.Channel (hoistChannel)
import Network.TypedProtocol.Codec (hoistCodec)
import Network.TypedProtocol.Driver (runPeer)
import Network.Socket (Socket)
import qualified Network.Socket as Socket

import Ouroboros.Network.Channel (Channel, socketAsChannel)
import qualified Ouroboros.Network.Server.Socket as Server
import Ouroboros.Network.Server.Version (Application (..), Dict (..), Version (..), Versions (..), Sigma (..))
import Ouroboros.Network.Server.Version.Protocol (clientPeerFromVersions, serverPeerFromVersions)
import qualified Ouroboros.Network.Server.Version.CBOR as Version

import qualified Ouroboros.Network.Protocol.ChainSync.Client as ChainSync
import qualified Ouroboros.Network.Protocol.ChainSync.Server as ChainSync
import qualified Ouroboros.Byron.Proxy.ChainSync.Client as Client
import qualified Ouroboros.Byron.Proxy.ChainSync.Server as Server
import qualified Ouroboros.Byron.Proxy.ChainSync.Types as ChainSync

import qualified Ouroboros.Byron.Proxy.DB as DB (DB, blockEpochAndRelativeSlot, ebbEpoch)

import qualified Control.Monad.Class.MonadThrow as NonStandard
import qualified Control.Monad.Catch as Standard

version0
  :: Tracer IO String 
  -> Sigma (Version (Dict Serialise) (Channel IO Lazy.ByteString -> IO ()))
version0 tracer = Sigma (42 :: Int) $ Version
  { versionExtra = Dict
  , versionApplication = application0 tracer
  }

application0 :: Tracer IO String -> Application (anything -> IO ()) Int
application0 tracer = Application $ \_localData remoteData _channel ->
  traceWith tracer $ mconcat
    [ "Version 0. Remote data is "
    , show remoteData
    ]

clientApplication1
  :: Tracer IO String
  -> Application (Channel IO Lazy.ByteString -> IO ()) Lazy.ByteString
clientApplication1 tracer = Application $ \_localData remoteData channel -> do
  traceWith tracer $ mconcat
    [ "Client version 1. Remote data is "
    , show remoteData
    ]
  runPeer nullTracer ChainSync.codec channel peer
  where
  peer = ChainSync.chainSyncClientPeer (chainSyncClient (contramap chainSyncShow tracer))

clientVersion1
  :: Tracer IO String
  -> Sigma (Version (Dict Serialise) (Channel IO Lazy.ByteString -> IO ()))
clientVersion1 tracer = Sigma (Lazy.pack "this is the client version data") $ Version
  { versionExtra = Dict
  , versionApplication = clientApplication1 tracer
  }

serverApplication1
  :: Tracer IO String
  -> Int
  -> DB.DB IO
  -> Application (Channel IO Lazy.ByteString -> IO ()) Lazy.ByteString
serverApplication1 tracer usPoll db = Application $ \_localData remoteData channel -> do
  traceWith tracer $ mconcat
    [ "Server version 1. Remote data is "
    , show remoteData
    ]
  let peer = ChainSync.chainSyncServerPeer (chainSyncServer usPoll db)
      -- `peer` is in ResourceT`, so we must hoist channel and codec into
      -- `ResourceT`
      inResourceT :: forall x . IO x -> ResourceT IO x
      inResourceT = liftIO
      codec' = hoistCodec inResourceT ChainSync.codec
      channel' = hoistChannel inResourceT channel
  (runResourceT $ runPeer nullTracer codec' channel' peer) `catch` (\(e :: SomeException) -> do
    traceWith tracer $ mconcat
      [ "Version 1 connection from terminated with exception "
      , show e
      ]
    throwIO e
    )
  traceWith tracer $ mconcat
    [ "Version 1 connection from terminated normally"
    ]

serverVersion1
  :: Tracer IO String
  -> Int
  -> DB.DB IO
  -> Sigma (Version (Dict Serialise) (Channel IO Lazy.ByteString -> IO ()))
serverVersion1 tracer usPoll db = Sigma (Lazy.pack "server version data here") $ Version
  { versionExtra = Dict
  , versionApplication = serverApplication1 tracer usPoll db
  }

clientVersions
  :: Tracer IO String
  -> Versions Version.Number (Dict Serialise) (Channel IO Lazy.ByteString -> IO ())
clientVersions tracer = Versions $ Map.fromList
  [ (0, version0 tracer)
  , (1, clientVersion1 tracer)
  ]

serverVersions
  :: Tracer IO String
  -> Int
  -> DB.DB IO
  -> Versions Version.Number (Dict Serialise) (Channel IO Lazy.ByteString -> IO ())
serverVersions tracer usPoll db = Versions $ Map.fromList
  [ (0, version0 tracer)
  , (1, serverVersion1 tracer usPoll db)
  ]

encodeBlob :: Dict Serialise t -> t -> Version.Blob
encodeBlob Dict = CBOR.toStrictByteString . encode

decodeBlob :: Dict Serialise t -> Version.Blob -> Maybe t
decodeBlob Dict = either (const Nothing) Just . deserialiseOrFail . Lazy.fromStrict

-- | Echos rolls (forward or backward) using a trace.
chainSyncClient
  :: forall m x .
     ( Monad m )
  => Tracer m (Either ChainSync.Point ChainSync.Block, ChainSync.Point)
  -> ChainSync.ChainSyncClient ChainSync.Block ChainSync.Point m x
chainSyncClient trace = Client.chainSyncClient fold
  where
  fold :: Client.Fold m x
  fold = Client.Fold $ pure $ Client.Continue forward backward
  forward :: ChainSync.Block -> ChainSync.Point -> Client.Fold m x
  forward blk point = Client.Fold $ do
    traceWith trace (Right blk, point)
    Client.runFold fold
  backward :: ChainSync.Point -> ChainSync.Point -> Client.Fold m x
  backward point1 point2 = Client.Fold $ do
    traceWith trace (Left point1, point2)
    Client.runFold fold

chainSyncShow
  :: (Either ChainSync.Point ChainSync.Block, ChainSync.Point)
  -> String
chainSyncShow = \(roll, _tip) -> case roll of
  Left  back    -> mconcat
    [ "Roll back to "
    , show back
    ]
  Right forward -> mconcat
    [ "Roll forward to "
    , case ChainSync.getBlock forward of
        Left ebb  -> show $ DB.ebbEpoch ebb
        Right blk -> show $ DB.blockEpochAndRelativeSlot blk
    ]

-- a chain sync server that serves whole blocks.
-- The `ResourceT` is needed because we deal with DB iterators.
chainSyncServer
  :: Int
  -> DB.DB IO
  -> ChainSync.ChainSyncServer ChainSync.Block ChainSync.Point (ResourceT IO) ()
chainSyncServer usPoll = Server.chainSyncServer err poll
  where
  err = throwIO
  poll :: Server.PollT IO
  poll p m = do
    s <- m
    mbT <- p s
    case mbT of
      Nothing -> lift (threadDelay usPoll) >> poll p m
      Just t  -> pure t

-- | Run a chain sync server over an IPv4 socket.
--
-- The `STM ()` is for normal shutdown. When it returns, the server stops.
-- So, for instance, use `STM.retry` to never stop (until killed).
runVersionedServer
  :: Socket.HostAddress
  -> Socket.PortNumber
  -> Tracer IO String
  -> STM ()
  -> Int
  -> DB.DB IO
  -> IO ()
runVersionedServer host port tracer closeTx usPoll db = bracket mkSocket Socket.close $ \socket ->
  Server.run (fromSocket socket) throwIO accept complete (const closeTx) ()
  where
  -- New connections are always accepted. The channel is used to run the
  -- version negotiation protocol determined by `versions`. Some stdout
  -- printing is done just to help you see what's going on.
  accept sockAddr st = pure $ Server.Accept st $ \channel -> do
    traceWith tracer $ mconcat
      [ "Got connection from "
      , show sockAddr
      ]
    let versionServer = serverPeerFromVersions encodeBlob decodeBlob (serverVersions tracer usPoll db)
    mbVersion <- runPeer nullTracer Version.codec channel versionServer `catch` (\(e :: SomeException) -> do
      traceWith tracer $ mconcat
        [ "Exception during version negotation with "
        , show sockAddr
        , ": "
        , show e
        ]
      throwIO e)
    case mbVersion of
      Nothing -> traceWith tracer $ mconcat
        [ "No compatible versions with "
        , show sockAddr
        ]
      Just k -> k channel
  -- When a connection completes, we do nothing. State is ().
  -- Crucially: we don't re-throw exceptions, because doing so would
  -- bring down the server.
  -- For the demo, the client will stop by closing the socket, which causes
  -- a deserialise failure (unexpected end of input) and we don't want that
  -- to bring down the proxy.
  complete outcome st = case outcome of
    Left  err -> pure st
    Right r   -> pure st
  mkSocket :: IO Socket
  mkSocket = do
    socket <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption socket Socket.ReuseAddr 1
    Socket.bind socket (Socket.SockAddrInet port host)
    Socket.listen socket 1
    pure socket
  -- Make a server-compatibile socket from a network socket.
  fromSocket :: Socket -> Server.Socket Socket.SockAddr (Channel IO Lazy.ByteString)
  fromSocket socket = Server.Socket
    { Server.acceptConnection = do
        (socket', addr) <- Socket.accept socket
        pure (addr, socketAsChannel socket', Socket.close socket')
    }

-- | Connects (IPv4) to a server at a given address and runs the version
-- negotiation protocol determined by `clientVersions`.
runVersionedClient
  :: Socket.HostAddress
  -> Socket.PortNumber
  -> Tracer IO String
  -> IO ()
runVersionedClient host port tracer = bracket mkSocket Socket.close $ \socket -> do
  _ <- Socket.connect socket (Socket.SockAddrInet port host)
  let channel = socketAsChannel socket
      versionClient = clientPeerFromVersions encodeBlob decodeBlob (clientVersions tracer)
  -- Run the version negotiation client, and then whatever continuation it
  -- produces.
  mbVersion <- runPeer nullTracer Version.codec channel versionClient
  case mbVersion of
    -- TODO it should give an explanation.
    Nothing -> error "failed to negotiate version"
    Just k  -> k channel
  where
  mkSocket = do
    socket <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.bind socket (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (0, 0, 0, 0)))
    pure socket

-- Orphans, forced upon me because of the IO sim stuff.
-- Required because we use ResourceT in the chain sync server.

instance NonStandard.MonadThrow (ResourceT IO) where
  throwM = Standard.throwM

-- Non-standard MonadThrow includes bracket... we can get it for free if we
-- give a non-standard MonadCatch

instance NonStandard.MonadCatch (ResourceT IO) where
  catch = Standard.catch

instance NonStandard.MonadMask (ResourceT IO) where
  mask = Standard.mask
  uninterruptibleMask = Standard.uninterruptibleMask
