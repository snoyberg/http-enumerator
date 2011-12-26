{-# LANGUAGE FlexibleContexts #-}
module Network.HTTP.Conduit.Chunk
    ( chunkedConduit
    , chunkIt
    ) where

import Control.Exception (assert)
import Data.Monoid (mconcat)
import Numeric (showHex)

import Control.Monad.Trans.Class (lift)

import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy as L

import Blaze.ByteString.Builder.HTTP
import qualified Blaze.ByteString.Builder as Blaze

import qualified Data.Attoparsec.ByteString as A

import qualified Data.Conduit as C
import Data.Conduit.Attoparsec (ParseError (ParseError))

import Network.HTTP.Conduit.Parser


data CState = NeedHeader (S.ByteString -> A.Result Int)
            | Isolate Int
            | NeedNewline (S.ByteString -> A.Result ())
            | Complete

chunkedConduit :: C.ResourceThrow m
               => Bool -- ^ send the headers as well, necessary for a proxy
               -> C.Conduit S.ByteString m S.ByteString
chunkedConduit sendHeaders = C.conduitState
    (NeedHeader $ A.parse parseChunkHeader)
    (push id)
    close
  where
    push front (NeedHeader f) x =
        case f x of
            A.Done x' i
                | i == 0 -> push front Complete x'
                | otherwise -> do
                    let header = S8.pack $ showHex i "\r\n"
                    let addHeader = if sendHeaders then (header:) else id
                    push (front . addHeader) (Isolate i) x'
            A.Partial f' -> return (NeedHeader f', C.Producing $ front [])
            A.Fail _ contexts msg -> lift $ C.resourceThrow $ ParseError contexts msg
    push front (Isolate i) x = do
        let (a, b) = S.splitAt i x
            i' = i - S.length a
        if i' == 0
            then push
                    (front . (a:))
                    (NeedNewline $ A.parse newline)
                    b
            else assert (S.null b) $ return
                ( Isolate i'
                , C.Producing (front [a])
                )
    push front (NeedNewline f) x =
        case f x of
            A.Done x' () -> do
                let header = S8.pack "\r\n"
                let addHeader = if sendHeaders then (header:) else id
                push
                    (front . addHeader)
                    (NeedHeader $ A.parse parseChunkHeader)
                    x'
            A.Partial f' -> return (NeedNewline f', C.Producing $ front [])
            A.Fail _ contexts msg -> lift $ C.resourceThrow $ ParseError contexts msg
    push front Complete leftover = do
        let end = if sendHeaders then [S8.pack "0\r\n"] else []
            lo = if S.null leftover then Nothing else Just leftover
        return (Complete, C.Finished lo $ front end)
    close state = return []

chunkIt :: C.Resource m => C.Conduit Blaze.Builder m Blaze.Builder
chunkIt = C.Conduit $ return $ C.PreparedConduit
    { C.conduitPush = \xs -> return $ C.Producing [chunkedTransferEncoding xs]
    , C.conduitClose = return [chunkedTransferTerminator]
    }
