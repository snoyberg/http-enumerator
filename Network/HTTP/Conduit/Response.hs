{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.HTTP.Conduit.Response
    ( lbsConsumer
    , Response (..)
    , ResponseConsumer
    , getResponse
    ) where

import Control.Arrow (first)
import Data.Typeable (Typeable)

import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L

import qualified Data.CaseInsensitive as CI

import Control.Monad.Trans.Resource (ResourceT, ResourceIO)
import qualified Data.Conduit as C
import qualified Data.Conduit.Zlib as CZ
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL

import qualified Network.HTTP.Types as W

import Network.HTTP.Conduit.Manager
import Network.HTTP.Conduit.Request
import Network.HTTP.Conduit.Util
import Network.HTTP.Conduit.Parser
import Network.HTTP.Conduit.Chunk


-- | Convert the HTTP response into a 'Response' value.
--
-- Even though a 'Response' contains a lazy bytestring, this function does
-- /not/ utilize lazy I/O, and therefore the entire response body will live in
-- memory. If you want constant memory usage, you'll need to write your own
-- iteratee and use 'http' or 'httpRedirect' directly.
lbsConsumer :: ResourceIO m => ResponseConsumer m Response
lbsConsumer (W.Status sc _) hs bsrc = do
    lbs <- fmap L.fromChunks $ bsrc C.$$ CL.consume
    return $ Response sc hs lbs

-- | A simple representation of the HTTP response created by 'lbsConsumer'.
data Response = Response
    { statusCode :: Int
    , responseHeaders :: W.ResponseHeaders
    , responseBody :: L.ByteString
    }
    deriving (Show, Read, Eq, Typeable)

type ResponseConsumer m a
    = W.Status
   -> W.ResponseHeaders
   -> C.BufferedSource m S.ByteString
   -> ResourceT m a

getResponse :: ResourceIO m
            => Request m
            -> ResponseConsumer m a
            -> C.BufferedSource m S8.ByteString
            -> ResourceT m (WithConnResponse a)
getResponse req@(Request {..}) bodyStep bsrc = do
    ((_, sc, sm), hs) <- bsrc C.$$ sinkHeaders
    let s = W.Status sc sm
    let hs' = map (first CI.mk) hs
    let mcl = lookup "content-length" hs'
    -- RFC 2616 section 4.4_1 defines responses that must not include a body
    res <- if hasNoBody method sc
        then do
            bsrcNull <- C.bufferSource $ CL.sourceList []
            bodyStep s hs' bsrcNull
        else do
            bsrc' <-
                if ("transfer-encoding", "chunked") `elem` hs'
                    then C.bufferSource $ bsrc C.$= chunkedConduit rawBody
                    else
                        case mcl >>= readDec . S8.unpack of
                            Just len -> C.bufferSource $ bsrc C.$= CB.isolate len
                            Nothing  -> return bsrc
            bsrc'' <-
                if needsGunzip req hs'
                    then C.bufferSource $ bsrc' C.$= CZ.ungzip
                    else return bsrc'
            bodyStep s hs' bsrc''
            -- FIXME this is causing hangs, need to look into it bsrc C.$$ CL.sinkNull
            -- Most likely just need to flush the actual buffer

    -- should we put this connection back into the connection manager?
    let toPut = Just "close" /= lookup "connection" hs'
    return $ WithConnResponse (if toPut then Reuse else DontReuse) res
