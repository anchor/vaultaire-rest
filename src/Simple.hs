{-# LANGUAGE OverloadedStrings #-}
module Simple where

import           Control.Applicative
import           Control.Concurrent           hiding (yield)
import           Control.Monad                (forever)
import           Control.Monad.IO.Class
import           Data.Aeson                   (encode, toJSON)
import           Data.ByteString              (ByteString)
import qualified Data.ByteString.Char8        as B
import qualified Data.ByteString.Lazy         as LB
import           Data.ByteString.Lazy.Builder (string7)
import           Data.List                    (sortBy)
import           Data.Maybe
import           Data.ProtocolBuffers         (getField)
import           Pipes
import           Pipes.Concurrent
import           Snap.Core
import           System.Timeout               (timeout)
import           Types.Chevalier              (SourceQuery (..))
import           Types.ReaderD                (DataBurst (..), DataFrame (..),
                                               Range (..), RangeQuery (..))
import           Util

simpleSearch :: MVar SourceQuery -> Snap ()
simpleSearch chevalier_mvar = do
    query <- utf8Or400 =<< fromMaybe "*" <$> getParam "q"
    page <- toInt <$> fromMaybe "0" <$> getParam "page"

    maybe_response <- liftIO $ do
        response_mvar <- newEmptyMVar
        putMVar chevalier_mvar $ SourceQuery query page response_mvar
        timeout chevalierTimeout $ takeMVar response_mvar

    either_response <- maybe timeoutError return maybe_response
    either chevalierError writeJSON either_response
  where
    chevalierTimeout = 10000000 -- 10 seconds

    chevalierError e = do
        logException e
        writeError 500 $ string7 "Exception talking to chevalier backend"

    timeoutError = do
        let msg = "Timed out talking to chevalier backend"
        logException msg
        writeError 500 $ string7 msg

interpolated :: MVar RangeQuery -> Snap ()
interpolated readerd_mvar = do
    -- The reader daemon provides no timestamp sorting within a chunk, but will
    -- provide sorting between chunks.
    --
    -- This means that the latest point (chronologically) in a burst will be no
    -- later than the first point in the next burst.
    --
    -- This allows us to stream the data the user chunk by chunk.

    tags <- tagsOr400 =<< utf8Or400 =<< fromJust <$> getParam "source"
    start <- toInt <$> fromMaybe "0" <$> getParam "start"
    end <- toInt <$> fromMaybe "0" <$> getParam "end"

    input <- liftIO $ do
        (output, input) <- spawn Single
        putMVar readerd_mvar $ RangeQuery tags start end output
        return input

    writeBS "["
    runEffect $ for (fromInput input
                     >-> logExceptions
                     >-> unRange
                     >-> sortBurst
                     >-> jsonEncode
                     >-> addCommas True)
                    (lift . writeLBS)
    writeBS "]"
  where
    -- Pipes are chained from top to bottom:

    -- Log exceptions, pass on Ranges
    logExceptions = forever $ await >>= either (lift . logException) yield

    -- Extract a DataBurst from a Range, stopping when Done
    unRange = do
        range <- await
        case range of Burst b -> yield b >> unRange
                      Done -> return ()

    -- Sort the DataBurst by time, passing on a list of DataFrames
    sortBurst = do
        unsorted <- getField . frames <$> await
        yield $ sortBy compareByTime unsorted
        sortBurst
      where
        compareByTime frame_a frame_b = compare (ts frame_a) (ts frame_b)
        ts = getField . timestamp

    jsonEncode = do
        burst <- encode . toJSON <$> await
        yield burst

    -- We want to prepend all but the first burst with a comma.
    addCommas is_first
        | is_first  = await >> addCommas False
        | otherwise = do
            burst <- await
            yield $ LB.append "," burst
            addCommas False

toInt :: Integral a => ByteString -> a
toInt bs = maybe 0 (fromIntegral . fst) (B.readInteger bs)
