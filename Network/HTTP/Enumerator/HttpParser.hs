{-# LANGUAGE OverloadedStrings #-}
module Network.HTTP.Enumerator.HttpParser
    ( iterHeaders
    , iterChunkHeader
    , iterNewline
    , parserHeadersFromByteString
    ) where

import Prelude hiding (take, takeWhile)
import Data.Attoparsec
import Data.Attoparsec.Enumerator
import Data.Enumerator (Iteratee)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import Control.Applicative
import Data.Word (Word8)

type Header = (S.ByteString, S.ByteString)

parseHeader :: Parser Header
parseHeader = do
    k <- takeWhile1 notNewlineColon
    _ <- word8 58 -- colon
    skipWhile isSpace
    v <- takeWhile notNewline
    newline
    return (k, v)

notNewlineColon, isSpace, notNewline :: Word8 -> Bool

notNewlineColon 10 = False -- LF
notNewlineColon 13 = False -- CR
notNewlineColon 58 = False -- colon
notNewlineColon _  = True

isSpace 32 = True
isSpace _  = False

notNewline 10 = False
notNewline 13 = False
notNewline _  = True

newline :: Parser ()
newline =
    lf <|> (cr >> lf)
  where
    word8' x = word8 x >> return ()
    lf = word8' 10
    cr = word8' 13

parseHeaders :: Parser (Status, [Header])
parseHeaders = do
    s <- parseStatus <?> "HTTP status line"
    h <- manyTill parseHeader newline <?> "Response headers"
    return (s, h)

iterHeaders :: Monad m => Iteratee S.ByteString m (Status, [Header])
iterHeaders = iterParser parseHeaders


parserHeadersFromByteString :: Monad m => S.ByteString -> m (Either String (Status, [Header]))
parserHeadersFromByteString s = return $ parseOnly parseHeaders s


type Status = (S.ByteString, Int, S.ByteString)

parseStatus :: Parser Status
parseStatus = do
    _ <- string "HTTP/"
    ver <- takeWhile1 $ not . isSpace
    _ <- word8 32 -- space
    statCode <- takeWhile1 $ not . isSpace
    statCode' <-
        case reads $ S8.unpack statCode of
            [] -> fail $ "Invalid status code: " ++ S8.unpack statCode
            (x, _):_ -> return x
    _ <- word8 32
    statMsg <- takeWhile1 $ notNewline
    newline
    if (statCode == "100")
        then newline >> parseStatus
        else return (ver, statCode', statMsg)

parseChunkHeader :: Parser Int
parseChunkHeader = do
    len <- hexs
    skipWhile isSpace
    newline <|> attribs
    return len

iterChunkHeader :: Monad m => Iteratee S.ByteString m Int
iterChunkHeader =
    iterParser (parseChunkHeader <?> "Chunked transfer encoding header")

iterNewline :: Monad m => Iteratee S.ByteString m ()
iterNewline = iterParser newline

attribs :: Parser ()
attribs = do
    _ <- word8 59 -- colon
    skipWhile notNewline
    newline

hexs :: Parser Int
hexs = do
    ws <- many1 hex
    return $ foldl1 (\a b -> a * 16 + b) $ map fromIntegral ws

hex :: Parser Word8
hex =
    (digit <|> upper <|> lower) <?> "Hexadecimal digit"
  where
    digit = do
        d <- satisfy $ \w -> (w >= 48 && w <= 57)
        return $ d - 48
    upper = do
        d <- satisfy $ \w -> (w >= 65 && w <= 70)
        return $ d - 55
    lower = do
        d <- satisfy $ \w -> (w >= 97 && w <= 102)
        return $ d - 87

{-
iterParserTill :: Monad m
               => Parser a
               -> Parser end
               -> E.Enumeratee a S.ByteString m b
iterParserTill p pend =
    E.continue $ step $ parse p
  where
    step parse (E.Chunks xs) = parseLoop parse xs
    step parse E.EOF = case parse S.empty of
        Done extra a -> E.yield a $ if S.null extra
            then E.Chunks []
            else E.Chunks [extra]
        Partial _ -> err [] "iterParser: divergent parser"
        Fail _ ctx msg -> err ctx msg

    parseLoop parse [] = E.continue (step parse)
    parseLoop parse (x:xs) = case parse x of
        Done extra a -> E.yield a $ if S.null extra
            then E.Chunks xs
            else E.Chunks (extra:xs)
        Partial parse' -> parseLoop parse' xs
        Fail _ ctx msg -> err ctx msg

    err ctx msg = E.throwError (ParseError ctx msg)
-}
