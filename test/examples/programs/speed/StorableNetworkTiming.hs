{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Parallel.MPI.Common
import Control.Parallel.MPI.Storable
import qualified Control.Parallel.MPI.Internal as Internal
import Data.Array.Storable
import Data.Array.IO
import Control.Monad (when, forM, forM_)
import Text.Printf
import System.Random
import System.Environment (getArgs)
import Control.Applicative
import Foreign (sizeOf, castPtr, nullPtr)
import Foreign.C.Types

type El = Double
type Msg = StorableArray Int El
type Counters = IOUArray Int Double

root :: Rank
root = 0

-- Fit a and b to the model y=ax+b. Return a, b, variance
linfit :: Counters -> Counters -> IO (Double, Double, Double)
linfit x y = do
  x_bnds <- getBounds x
  y_bnds <- getBounds y
  when (x_bnds /= y_bnds) $ error "x and y must have same length and dimensions"

  xs <- getElems x
  ys <- getElems y

  let n  = rangeSize x_bnds
      sx = sum xs
      sy = sum ys

      sxon = sx/(fromIntegral n)

      ts = map (\x -> x-sxon) xs
      sson = sum $ map (^2) ts

      a = (sum $ zipWith (*) ts ys)/sson
      b = (sy-sx*a)/(fromIntegral n)

      norm = sum $ map (^2) xs
      res  = zipWith (\x y -> y - a*x - b) xs ys
      varest = (sum $ map (^2) res)/(norm * (fromIntegral $ n-2))

  return (a,b,varest)

---- Main program
maxI = 10         -- Number of blocks
maxM = 500000     -- Largest block
block = maxM `div` maxI -- Block size

repeats = 10

data Mode = Prim | API deriving Eq

main = mpi $ do
  args <- getArgs
  numProcs <- commSize commWorld
  myRank   <- commRank commWorld
  let mode = case args of
               ("prim":_) -> Prim
               _      -> API

  when (myRank == root) $ do
    putStrLn $ printf "MAXM = %d, number of processors = %d" maxM numProcs
    putStrLn $ printf "Measurements are repeated %d times for reliability" repeats

  if numProcs < 2
    then putStrLn "Program needs at least two processors - aborting"
    else measure mode numProcs myRank

measure mode numProcs myRank = do
  procName <- getProcessorName
  putStrLn $ printf "I am process %d on %s" (fromEnum myRank) procName

  -- Initialize data
  let elsize = sizeOf (undefined::Double)

  noelem  <- newArray (1, maxI) (0::Double) :: IO Counters
  bytes   <- newArray (1, maxI) (0::Double) :: IO Counters
  mintime <- newArray (1, maxI) (100000::Double) :: IO Counters
  maxtime <- newArray (1, maxI) (-100000::Double) :: IO Counters
  avgtime <- newArray (1, maxI) (0::Double) :: IO Counters

  cpuOH <- if myRank == root then do
    ohs <- sequence $ replicate repeats $ do
      t1 <- wtime
      t2 <- wtime
      return (t2-t1)
    let oh = minimum ohs
    putStrLn $ printf "Timing overhead is %f seconds." oh
    return oh
    else return undefined

  let message_sizes = [ block*(i-1)+1 | i <- [1..maxI] ]
  messages <- if myRank == root
              then do let a = replicate maxM (666::El) -- Random generation is slow
                      sequence [ newListArray (1,m) (take m a) | m <- message_sizes ]
              else return []
  buffers  <- sequence [ newArray (1,m) 0 | m <- message_sizes ]

  forM_ [1..repeats] $ \k -> do
    when (myRank == root) $ putStrLn $ printf "Run %d of %d" k repeats

    forM_ [1..maxI] $ \i -> do
      let m = message_sizes!!(i-1)
      writeArray noelem i (fromIntegral m)

      barrier commWorld

      let (c :: Msg) = buffers!!(i-1)

      barrier commWorld -- Synchronize all before timing
      if myRank == root then do
        let (msg :: Msg) = messages!!(i-1)
        diff <- if mode == API then do
            t1 <- wtime
            send commWorld 1 unitTag msg
            recv commWorld (toEnum $ numProcs-1) unitTag c
            t2 <- wtime
            return (t2-t1-cpuOH)
          else do
            let cnt :: CInt = fromIntegral m      
            t1 <- wtime
            withStorableArray msg $ \sendPtr ->
              Internal.send (castPtr sendPtr) cnt double 1 0 commWorld
            withStorableArray c $ \recvPtr ->
              Internal.recv (castPtr recvPtr) cnt double (fromIntegral $ numProcs-1) 0 commWorld nullPtr
            t2 <- wtime
            return (t2-t1-cpuOH)               
        curr_avg <- readArray avgtime i
        writeArray avgtime i $ curr_avg + diff/(fromIntegral numProcs)

        curr_min <- readArray mintime i
        curr_max <- readArray maxtime i
        when (diff < curr_min) $ writeArray mintime i diff
        when (diff > curr_max) $ writeArray maxtime i diff
        else if mode == API then do -- non-root processes. Get msg and pass it on
            recv commWorld (myRank-1) unitTag c
            send commWorld ((myRank+1) `mod` toEnum numProcs) unitTag c
          else do
            let cnt :: CInt = fromIntegral m      
            withStorableArray c $ \recvPtr -> do
              Internal.recv (castPtr recvPtr) cnt double (fromIntegral $ myRank-1) 0 commWorld nullPtr
              Internal.send (castPtr recvPtr) cnt double (fromIntegral $ (myRank+1) `mod` toEnum numProcs) 0 commWorld
            return ()
  when (myRank == root) $ do
    putStrLn "Bytes transferred   time (micro seconds)"
    putStrLn "                    min        avg        max "
    putStrLn "----------------------------------------------"

    forM_ [1..maxI] $ \i -> do

      avgtime_ <- (round.(*1e6).(/(fromIntegral repeats))) <$> readArray avgtime i :: IO Int -- Average micro seconds
      mintime_dbl <- (*1e6) <$> readArray mintime i :: IO Double -- Min micro seconds
      maxtime_ <- round.(*1e6) <$> readArray maxtime i :: IO Int -- Max micro seconds
      let mintime_ = round mintime_dbl :: Int

      m <- readArray noelem i
      writeArray bytes   i ((fromIntegral elsize) * m)
      writeArray mintime i mintime_dbl

      putStrLn $ printf "%10d    %10d %10d %10d" ((round $ (fromIntegral elsize) * m)::Int) mintime_ avgtime_ maxtime_


    (tbw, tlat, varest) <- linfit bytes mintime
    putStrLn $ "\nLinear regression on best timings (t = t_l + t_b * bytes):"
    putStrLn $ printf "  t_b = %f\n  t_l = %f" tbw tlat
    putStrLn $ printf "  Estimated relative variance = %.9f\n" varest

    putStrLn $ printf "Estimated bandwith (1/t_b):  %.3f Mb/s" (1.0/tbw)
    mt0 <- readArray mintime 1
    b0 <- readArray bytes 1
    putStrLn $ printf "Estimated latency:           %d micro s" (round (mt0-b0*tbw) :: Int)
