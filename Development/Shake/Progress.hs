{-# LANGUAGE DeriveDataTypeable, RecordWildCards, CPP, ForeignFunctionInterface, ScopedTypeVariables #-}

-- | Progress tracking
module Development.Shake.Progress(
    Progress(..),
    progressSimple, progressDisplay, progressTitlebar, progressProgram,
    progressDisplayTester -- INTERNAL FOR TESTING ONLY
    ) where

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import System.Environment
import System.Directory
import System.Process
import Data.Char
import Data.Data
import Data.IORef
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.ByteString.Char8 as BS
import System.IO.Unsafe

#ifdef mingw32_HOST_OS

import Foreign
import Foreign.C.Types

type LPCSTR = Ptr CChar

foreign import stdcall "Windows.h SetConsoleTitleA" c_setConsoleTitle :: LPCSTR -> IO Bool

#endif


---------------------------------------------------------------------
-- PROGRESS TYPES - exposed to the user

-- | Information about the current state of the build, obtained by passing a callback function
--   to 'Development.Shake.shakeProgress'. Typically a program will use 'progressDisplay' to poll this value and produce
--   status messages, which is implemented using this data type.
data Progress = Progress
    {isFailure :: !(Maybe String) -- ^ Starts out 'Nothing', becomes 'Just' a target name if a rule fails.
    ,countSkipped :: {-# UNPACK #-} !Int -- ^ Number of rules which were required, but were already in a valid state.
    ,countBuilt :: {-# UNPACK #-} !Int -- ^ Number of rules which were have been built in this run.
    ,countUnknown :: {-# UNPACK #-} !Int -- ^ Number of rules which have been built previously, but are not yet known to be required.
    ,countTodo :: {-# UNPACK #-} !Int -- ^ Number of rules which are currently required (ignoring dependencies that do not change), but not built.
    ,timeSkipped :: {-# UNPACK #-} !Double -- ^ Time spent building 'countSkipped' rules in previous runs.
    ,timeBuilt :: {-# UNPACK #-} !Double -- ^ Time spent building 'countBuilt' rules.
    ,timeUnknown :: {-# UNPACK #-} !Double -- ^ Time spent building 'countUnknown' rules in previous runs.
    ,timeTodo :: {-# UNPACK #-} !(Double,Int) -- ^ Time spent building 'countTodo' rules in previous runs, plus the number which have no known time (have never been built before).
    }
    deriving (Eq,Ord,Show,Data,Typeable)

instance Monoid Progress where
    mempty = Progress Nothing 0 0 0 0 0 0 0 (0,0)
    mappend a b = Progress
        {isFailure = isFailure a `mplus` isFailure b
        ,countSkipped = countSkipped a + countSkipped b
        ,countBuilt = countBuilt a + countBuilt b
        ,countUnknown = countUnknown a + countUnknown b
        ,countTodo = countTodo a + countTodo b
        ,timeSkipped = timeSkipped a + timeSkipped b
        ,timeBuilt = timeBuilt a + timeBuilt b
        ,timeUnknown = timeUnknown a + timeUnknown b
        ,timeTodo = let (a1,a2) = timeTodo a; (b1,b2) = timeTodo b
                        x1 = a1 + b1; x2 = a2 + b2
                    in x1 `seq` x2 `seq` (x1,x2)
        }


---------------------------------------------------------------------
-- STREAM TYPES - for writing the progress functions

-- | A stream of values
newtype Stream i a = Stream {runStream :: i -> (a, Stream i a)}

instance Functor (Stream i) where
    fmap f s = pure f <*> s

instance Applicative (Stream i) where
    pure x = Stream $ const (x, pure x)
    Stream ff <*> Stream xx = Stream $ \i ->
        let (f1,f2) = ff i
            (x1,x2) = xx i
        in (f1 x1, f2 <*> x2)

idStream :: Stream i i
idStream = Stream $ \i -> (i, idStream)

foldStream :: (a -> b -> a) -> a -> Stream i b -> Stream i a
foldStream f z (Stream op) = Stream $ \a ->
    let (o1,o2) = op a
        z2 = f z o1
    in (z2, foldStream f z2 o2)


---------------------------------------------------------------------
-- STREAM UTILITIES

oldStream :: a -> Stream i a -> Stream i (a,a)
oldStream old = foldStream (\(_,old) new -> (old,new)) (old,old)

latch :: Stream i (Bool, a) -> Stream i a
latch s = fromJust <$> foldStream f Nothing s
    where f old (b,v) = Just $ if b then fromMaybe v old else v

iff :: Stream i Bool -> Stream i a -> Stream i a -> Stream i a
iff c t f = (\c t f -> if c then t else f) <$> c <*> t <*> f

posStream :: Stream i Int
posStream = foldStream (+) 0 $ pure 1

-- decay'd division, compute a/b, with a decay of f
-- r' is the new result, r is the last result
-- r ~= a / b
-- r' = r*b + f*(a'-a)
--      -------------
--      b + f*(b'-b)
-- when f == 1, r == r'
decay :: Double -> Stream i Double -> Stream i Double -> Stream i Double
decay f a b = foldStream step 0 $ (,) <$> oldStream 0 a <*> oldStream 0 b
    where step r ((a,a'),(b,b')) =((r*b) + f*(a'-a)) / (b + f*(b'-b))


fromInt :: Int -> Double
fromInt = fromInteger . toInteger


---------------------------------------------------------------------
-- MESSAGE GENERATOR

message :: Double -> Stream Progress Progress -> Stream Progress String
message sample progress = (\time perc -> time ++ " (" ++ perc ++ "%)") <$> time <*> perc
    where
        -- Number of seconds work completed
        -- Ignores timeSkipped which would be more truthful, but it makes the % drop sharply
        -- which isn't what users want
        done = fmap timeBuilt progress

        -- Predicted build time for a rule that has never been built before
        -- The high decay means if a build goes in "phases" - lots of source files, then lots of compiling
        -- we reach a reasonable number fairly quickly, without bouncing too much
        guess = iff ((==) 0 <$> samples) (pure 0) $ decay 10 time $ fmap fromInt samples
            where
                time = flip fmap progress $ \Progress{..} -> timeBuilt + fst timeTodo
                samples = flip fmap progress $ \Progress{..} -> countBuilt + countTodo - snd timeTodo

        -- Number of seconds work remaining, ignoring multiple threads
        todo = f <$> progress <*> guess
            where f Progress{..} guess = fst timeTodo + (fromIntegral (snd timeTodo) * guess)

        -- Number of seconds we have been going
        step = fmap ((*) sample . fromInt) posStream
        work = decay 1.2 done step

        -- Work value to use, don't divide by 0 and don't update work if done doesn't change
        realWork = iff ((==) 0 <$> done) (pure 1) $
            latch $ (,) <$> (uncurry (==) <$> oldStream 0 done) <*> work

        -- Display information
        time = flip fmap ((/) <$> todo <*> realWork) $ \guess ->
            let (mins,secs) = divMod (ceiling guess) (60 :: Int)
            in (if mins == 0 then "" else show mins ++ "m" ++ ['0' | secs < 10]) ++ show secs ++ "s"
        perc = iff ((==) 0 <$> done) (pure "0") $
            (\done todo -> show (floor (100 * done / (done + todo)) :: Int)) <$> done <*> todo


---------------------------------------------------------------------
-- EXPOSED FUNCTIONS

-- | Given a sampling interval (in seconds) and a way to display the status message,
--   produce a function suitable for using as 'Development.Shake.shakeProgress'.
--   This function polls the progress information every /n/ seconds, produces a status
--   message and displays it using the display function.
--
--   Typical status messages will take the form of @1m25s (15%)@, indicating that the build
--   is predicted to complete in 1 minute 25 seconds (85 seconds total), and 15% of the necessary build time has elapsed.
--   This function uses past observations to predict future behaviour, and as such, is only
--   guessing. The time is likely to go up as well as down, and will be less accurate from a
--   clean build (as the system has fewer past observations).
--
--   The current implementation is to predict the time remaining (based on 'timeTodo') and the
--   work already done ('timeBuilt'). The percentage is then calculated as @remaining / (done + remaining)@,
--   while time left is calculated by scaling @remaining@ by the observed work rate in this build,
--   roughly @done / time_elapsed@.
progressDisplay :: Double -> (String -> IO ()) -> IO Progress -> IO ()
progressDisplay = progressDisplayer True


-- | Version of 'progressDisplay' that omits the sleep
progressDisplayTester :: Double -> (String -> IO ()) -> IO Progress -> IO ()
progressDisplayTester = progressDisplayer False


progressDisplayer :: Bool -> Double -> (String -> IO ()) -> IO Progress -> IO ()
progressDisplayer sleep sample disp prog = do
    disp "Starting..." -- no useful info at this stage
    catchJust (\x -> if x == ThreadKilled then Just () else Nothing) (loop $ message sample idStream) (const $ disp "Finished")
    where
        loop :: Stream Progress String -> IO ()
        loop stream = do
            when sleep $ threadDelay $ ceiling $ sample * 1000000
            p <- prog
            (msg, stream) <- return $ runStream stream p
            disp $ msg ++ maybe "" (\err -> ", Failure! " ++ err) (isFailure p)
            loop stream


{-# NOINLINE xterm #-}
xterm :: Bool
xterm = System.IO.Unsafe.unsafePerformIO $
    -- Terminal.app uses "xterm-256color" as its env variable
    Control.Exception.catch (fmap ("xterm" `isPrefixOf`) $ getEnv "TERM") $
    \(e :: SomeException) -> return False


-- | Set the title of the current console window to the given text. If the
--   environment variable @$TERM@ is set to @xterm@ this uses xterm escape sequences.
--   On Windows, if not detected as an xterm, this function uses the @SetConsoleTitle@ API.
progressTitlebar :: String -> IO ()
progressTitlebar x
    | xterm = BS.putStr $ BS.pack $ "\ESC]0;" ++ x ++ "\BEL"
#ifdef mingw32_HOST_OS
    | otherwise = BS.useAsCString (BS.pack x) $ \x -> c_setConsoleTitle x >> return ()
#else
    | otherwise = return ()
#endif


-- | Call the program @shake-progress@ if it is on the @$PATH@. The program is called with
--   the following arguments:
--
-- * @--title=string@ - the string passed to @progressProgram@.
--
-- * @--state=Normal@, or one of @NoProgress@, @Normal@, or @Error@ to indicate
--   what state the progress bar should be in.
--
-- * @--value=25@ - the percent of the build that has completed, if not in @NoProgress@ state.
--
--   The program will not be called consecutively with the same @--state@ and @--value@ options.
--
--   Windows 7 or higher users can get taskbar progress notifications by placing the following
--   program in their @$PATH@: <https://github.com/ndmitchell/shake/releases>.
progressProgram :: IO (String -> IO ())
progressProgram = do
    exe <- findExecutable "shake-progress"
    case exe of
        Nothing -> return $ const $ return ()
        Just exe -> do
            ref <- newIORef Nothing
            return $ \msg -> do
                let failure = " Failure! " `isInfixOf` msg
                let perc = let (a,b) = break (== '%') msg
                           in if null b then "" else reverse $ takeWhile isDigit $ reverse a
                let key = (failure, perc)
                same <- atomicModifyIORef ref $ \old -> (Just key, old == Just key)
                let state = if perc == "" then "NoProgress" else if failure then "Error" else "Normal"
                rawSystem exe $ ["--title=" ++ msg, "--state=" ++ state] ++ ["--value=" ++ perc | perc /= ""]
                return ()


-- | A simple method for displaying progress messages, suitable for using as 'Development.Shake.shakeProgress'.
--   This function writes the current progress to the titlebar every five seconds using 'progressTitlebar',
--   and calls any @shake-progress@ program on the @$PATH@ using 'progressProgram'.
progressSimple :: IO Progress -> IO ()
progressSimple p = do
    program <- progressProgram
    progressDisplay 5 (\s -> progressTitlebar s >> program s) p
