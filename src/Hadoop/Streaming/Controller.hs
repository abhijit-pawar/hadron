{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Hadoop.Streaming.Controller
-- Copyright   :  Soostone Inc
-- License     :  BSD3
--
-- Maintainer  :  Ozgun Ataman
-- Stability   :  experimental
--
-- High level flow-control of Hadoop programs with ability to define a
-- sequence of Map-Reduce operations in a Monad, have strongly typed
-- data locations.
----------------------------------------------------------------------------

module Hadoop.Streaming.Controller
    (

    -- * Command Line Entry Point
      hadoopMain
    , HadoopEnv (..)
    , clouderaDemo
    , amazonEMR

    -- * Settings for MapReduce Jobs
    , MROptions
    , mroEq
    , mroPart
    , mroNumMap
    , mroNumReduce
    , mroCompress
    , gzipCodec
    , snappyCodec

    , RerunStrategy (..)

    -- * Logging Related
    , logTo

    -- * Hadoop Program Construction
    , Controller

    , connect
    , connect'
    , io

    , MapReduce (..)
    , Tap (..)
    , Tap'
    , tap
    , binaryDirTap
    , setupBinaryDir
    , fileListTap
    , readHdfsFile

    -- * Joining Multiple Datasets
    , joinStep
    , JoinType (..)
    , JoinKey

    ) where

-------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Error
import           Control.Lens
import           Control.Monad.Operational   hiding (view)
import qualified Control.Monad.Operational   as O
import           Control.Monad.State
import qualified Data.ByteString.Char8       as B
import           Data.Conduit
import           Data.Conduit.Utils
import           Data.Conduit.Zlib
import           Data.Default
import           Data.Hashable
import           Data.List
import           Data.List.LCS.HuntSzymanski
import qualified Data.Map                    as M
import           Data.Monoid
import           Data.Serialize
import qualified Data.Text                   as T
import           Data.Text.Encoding
import           System.Directory
import           System.Environment
import           System.FilePath
import           System.IO
-------------------------------------------------------------------------------
import           Hadoop.Streaming
import           Hadoop.Streaming.Hadoop
import           Hadoop.Streaming.Join
import           Hadoop.Streaming.Logger
import           Hadoop.Streaming.Protocol
import           Hadoop.Streaming.Types
-------------------------------------------------------------------------------



-------------------------------------------------------------------------------
-- | A packaged MapReduce step. Make one of these for each distinct
-- map-reduce step in your overall 'Controller' flow.
data MapReduce a m b = forall v. MapReduce {
      mrOptions :: MROptions
    -- ^ Hadoop and MapReduce options affecting only this specific
    -- job.
    , mrInPrism :: Prism' B.ByteString v
    -- ^ A serialization scheme for values between the map-reduce
    -- steps.
    , mrMapper  :: Mapper a m v
    , mrReducer :: Reducer v m b
    }


-- | The hadoop-understandable location of a datasource
type Location = String


-- | Tap is a data source/sink definition that *knows* how to serve
-- records of type 'a'.
--
-- It comes with knowledge on how to decode ByteString to target type
-- and can be used both as a sink (to save data form MR output) or
-- source (to feed MR programs).
--
-- Usually, you just define the various data sources and destinations
-- your MapReduce program is going to need:
--
-- > customers = 'tap' "s3n://my-bucket/customers" (csvProtocol def)
data Tap m a = Tap
    { location :: Location
    , proto    :: Protocol' m a
    }


-- | If two 'location's are the same, we consider two Taps equal.
instance Eq (Tap m a) where
    a == b = location a == location b


-- | It is often just fine to use IO as the base monad for MapReduce ops.
type Tap' a = Tap IO a


-- | Construct a 'DataDef'
tap :: Location -> Protocol' m a -> Tap m a
tap = Tap


------------------------------------------------------------------------------
-- | Conduit that takes in hdfs filenames and outputs the file contents.
readHdfsFile :: HadoopEnv -> Conduit B.ByteString IO B.ByteString
readHdfsFile settings = awaitForever $ \s3Uri -> do
    let uriStr = B.unpack s3Uri
    let getFile = hdfsLocalStream settings uriStr
    if isSuffixOf "gz" uriStr
      then getFile =$= ungzip
      else getFile


------------------------------------------------------------------------------
-- | Tap for handling file lists.  Hadoop can't process raw binary data
-- because it splits on newlines.  This tap allows you to get around that
-- limitation by instead making your input a list of file paths that contain
-- binary data.  Then the file names get split by hadoop and each map job
-- reads from those files as its first step.
fileListTap :: HadoopEnv
            -> Location
            -- ^ A file containing a list of files to be used as input
            -> Tap IO B.ByteString
fileListTap settings loc = tap loc (Protocol enc dec)
  where
    enc = error "You should never use a fileListTap as output!"
    dec = linesConduit =$= readHdfsFile settings


data ContState = ContState {
      _csMRCount :: Int
    }

instance Default ContState where
    def = ContState 0


makeLenses ''ContState



-------------------------------------------------------------------------------
data ConI a where
    Connect :: forall i o. MapReduce i IO o
            -> [Tap IO i] -> Tap IO o
            -> ConI ()

    MakeTap :: Protocol' IO a -> ConI (Tap IO a)
    BinaryDirTap :: Location -> ConI (Tap IO B.ByteString)

    ConIO :: IO a -> ConI a



-- | All MapReduce steps are integrated in the 'Controller' monad.
--
-- Warning: We do have an 'io' combinator as an escape valve for you
-- to use. However, you need to be careful how you use the result of
-- an IO computation. Remember that the same 'main' function will run
-- on both the main orchestrator process and on each and every
-- map/reduce node.
newtype Controller a = Controller { unController :: Program ConI a }
    deriving (Functor, Applicative, Monad)



-------------------------------------------------------------------------------
-- | Connect a MapReduce program to a set of inputs, returning the
-- output tap that was implicity generated (on hdfs) in the process.
connect'
    :: MapReduce a IO b
    -- ^ MapReduce step to run
    -> [Tap IO a]
    -- ^ Input files
    -> Protocol' IO b
    -- ^ Serialization protocol to be used on the output
    -> Controller (Tap IO b)
connect' mr inp proto = do
    out <- makeTap proto
    connect mr inp out
    return out


-------------------------------------------------------------------------------
-- | Connect a typed MapReduce program you supply with a list of
-- sources and a destination.
connect :: MapReduce a IO b -> [Tap IO a] -> Tap IO b -> Controller ()
connect mr inp outp = Controller $ singleton $ Connect mr inp outp


-------------------------------------------------------------------------------
makeTap :: Protocol' IO a -> Controller (Tap IO a)
makeTap proto = Controller $ singleton $ MakeTap proto


-------------------------------------------------------------------------------
-- | Creates a tap for a directory of binary files.
binaryDirTap :: Location -> Controller (Tap IO B.ByteString)
binaryDirTap loc = Controller $ singleton $ BinaryDirTap loc


-- | LIft IO into 'Controller'. Note that this is a NOOP for when the
-- Mappers/Reducers are running; it only executes in the main
-- controller application during job-flow orchestration.
--
-- If you try to construct a 'MapReduce' step that depends on the
-- result of an 'io' call, you'll get a runtime error when running
-- your job.
io :: IO a -> Controller a
io f = Controller $ singleton $ ConIO f


-------------------------------------------------------------------------------
newMRKey :: MonadState ContState m => m String
newMRKey = do
    i <- gets _csMRCount
    csMRCount %= (+1)
    return $! show i


setupBinaryDir settings loc = do
    localFile <- randomFilename
    files <- hdfsLs settings loc
    let suffix = lcs loc (head files)
        locBS = encodeUtf8 $ T.pack loc
        suffixBS = encodeUtf8 $ T.pack suffix
        prefixBS = maybe locBS (\i -> B.take i locBS) $ B.findSubstring suffixBS locBS
        prefix = T.unpack $ decodeUtf8 prefixBS
        paths = map (prefix++) files
    createDirectoryIfMissing True $ dropFileName localFile
    writeFile localFile $ unlines paths
    hdfsPut settings localFile localFile
    return localFile


-------------------------------------------------------------------------------
-- | Interpreter for the central job control process
orchestrate
    :: (MonadIO m, MonadLogger m)
    => Controller a
    -> HadoopEnv
    -> RerunStrategy
    -> ContState
    -> m (Either String a)
orchestrate (Controller p) settings rr s = evalStateT (runEitherT (go p)) s
    where
      go = eval . O.view

      eval (Return a) = return a
      eval (i :>>= f) = eval' i >>= go . f

      eval' :: (MonadLogger m, MonadIO m) => ConI a -> EitherT String (StateT ContState m) a

      eval' (ConIO f) = liftIO f

      eval' (MakeTap proto) = do
          loc <- liftIO randomFilename
          return $ Tap loc proto

      eval' (BinaryDirTap loc) = liftIO $ do
          localFile <- setupBinaryDir settings loc

          return $ fileListTap settings localFile

      eval' (Connect mr@(MapReduce mro mrInPrism _ _) inp outp) = go'
          where
            go' = do
                chk <- liftIO $ hdfsFileExists settings (location outp)
                case chk of
                  False -> go''
                  True ->
                    case rr of
                      RSFail -> lift $ $(logError) $ T.concat
                        ["Destination file exists: ", T.pack (location outp)]
                      RSSkip -> go''
                      RSReRun -> do
                        lift $ $(logInfo) $ T.pack $
                          "Destination file exists, will delete and rerun: " ++
                          location outp
                        _ <- liftIO $ hdfsDeletePath settings (location outp)
                        go''
            go'' = do
              mrKey <- newMRKey
              let mrs = mrOptsToRunOpts mro
              launchMapReduce settings mrKey
                mrs { mrsInput = map location inp
                    , mrsOutput = location outp }



data Phase = Map | Reduce


-------------------------------------------------------------------------------
-- | What to do when we notice that a destination file already exists.
data RerunStrategy
    = RSFail
    -- ^ Fail and log the problem.
    | RSReRun
    -- ^ Delete the file and rerun the analysis
    | RSSkip
    -- ^ Consider the analaysis already done and skip.
    deriving (Eq,Show,Read,Ord)

instance Default RerunStrategy where
    def = RSFail


-------------------------------------------------------------------------------
-- | The main entry point. Use this function to produce a command line
-- program that encapsulates everything.
--
-- When run without arguments, the program will orchestrate the entire
-- MapReduce job flow. The same program also doubles as the actual
-- mapper/reducer executable when called with right arguments, though
-- you don't have to worry about that.
hadoopMain
    :: forall m a. (MonadThrow m, MonadIO m)
    => Controller a
    -- ^ The Hadoop streaming application to run.
    -> HadoopEnv
    -- ^ Hadoop environment info.
    -> RerunStrategy
    -- ^ What to do if destination files already exist.
    -> m ()
hadoopMain c@(Controller p) hs rr = logTo stdout $ do
    args <- liftIO getArgs
    case args of
      [] -> do
        res <- orchestrate c hs rr def
        liftIO $ either print (const $ putStrLn "Success.") res
      [arg] -> do
        _ <- evalStateT (interpretWithMonad (go arg) p) def
        return ()
      _ -> error "Usage: No arguments for job control or a phase name."
    where

      mkArgs mrKey = [ (Map, "map_" ++ mrKey)
                     , (Reduce, "reduce_" ++ mrKey) ]


      go :: String -> ConI b -> StateT ContState (LoggingT m) b

      go _ (ConIO f) = liftIO f

      go _ (MakeTap proto) = do
          loc <- liftIO randomFilename
          return $ Tap loc proto
      --go _ MakeTap = return $ error "MakeTap should not be used during Map-Reduce operation. That's illegal."

      go _ (BinaryDirTap _) = liftIO $ do
          listFile <- randomFilename
          return $ fileListTap hs listFile
      --go _ (BinaryDirTap _) = return $ error "BinaryDirTap should not be used during Map-Reduce operation. That's illegal."

      go arg (Connect (MapReduce mro mrInPrism mp rd) inp outp) = do
          mrKey <- newMRKey
          case find ((== arg) . snd) $ mkArgs mrKey of
            Just (Map, _) -> do
              let inSer = proto $ head inp
                  logIn _ = liftIO $ hsEmitCounter "Map rows decoded" 1
              liftIO $ (mapperWith mrInPrism $
                protoDec inSer =$= performEvery 1 logIn =$= mp)
            Just (Reduce, _) -> do
              let outSer = proto outp
                  rd' = rd =$= protoEnc outSer
              liftIO $ (reducerMain mro mrInPrism rd')
            Nothing -> return ()


-- | TODO: See if this works. Objective is to increase type safety of
-- join inputs. Notice how we have an existential on a.
--
-- A join definition that ultimately produces objects of type b.
data JoinDef m b = forall a. JoinDef {
      joinTap  :: Tap m a
    , joinType :: JoinType
    , joinMap  :: Conduit a m (JoinKey, b)
    }


-------------------------------------------------------------------------------
-- | A convenient way to express multi-way join operations into a
-- single data type. All you need to supply is the map operation for
-- each tap, the reduce step is assumed to be the Monoidal 'mconcat'.
joinStep
    :: forall m b a. (MonadIO m, MonadThrow m,
                      Show b, Monoid b, Serialize b)
    => [(Tap m a, JoinType, Conduit a m (JoinKey, b))]
    -- ^ Dataset definitions and how to map each dataset.
    -> MapReduce a m b
joinStep fs = MapReduce joinOpts pSerialize mp rd
    where
      salt = 0
      showBS = B.pack . show

      names :: [(Location, DataSet)]
      names = map (\ (i, loc) -> (loc, DataSet $ B.concat [showBS i, ":",  showBS $ hashWithSalt salt loc])) $
              zip [(0::Integer)..] locations

      nameIx :: M.Map Location DataSet
      nameIx = M.fromList names

      tapIx :: M.Map DataSet (Tap m a)
      tapIx = M.fromList $ zip (map snd names) (map (view _1) fs)


      locations :: [Location]
      locations = map (location . view _1) fs


      getTapDS :: Tap m a -> DataSet
      getTapDS t =
          fromMaybe (error "Can't identify dataset name for given location") $
          M.lookup (location t) nameIx


      fs' :: [(DataSet, JoinType)]
      fs' = map (\ (t, jt, _) -> (getTapDS t, jt)) fs


      -- | get dataset name from a given input filename
      getDS nm = fromMaybe (error "Can't identify current tap from filename.") $ do
        loc <- find (flip isInfixOf nm) locations
        name <- M.lookup loc nameIx
        return name


      -- | get the conduit for given dataset name
      mkMap' ds = fromMaybe (error "Can't identify current tap in IX.") $ do
                      t <- M.lookup ds tapIx
                      cond <- find ((== t) . view _1) fs
                      return $ view _3 cond

      mp = joinMapper getDS mkMap'
      rd = joinReducer fs'


