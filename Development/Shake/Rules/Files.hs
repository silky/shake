{-# LANGUAGE MultiParamTypeClasses, GeneralizedNewtypeDeriving, DeriveDataTypeable, ScopedTypeVariables #-}

module Development.Shake.Rules.Files(
    (?>>), (*>>)
    ) where

import Control.Monad
import Control.Monad.IO.Class
import Data.Maybe
import System.Directory

import Development.Shake.Core
import General.Base
import Development.Shake.Classes
import Development.Shake.Rules.File
import Development.Shake.FilePattern
import Development.Shake.FileTime

import System.FilePath(takeDirectory) -- important that this is the system local filepath, or wrong slashes go wrong


infix 1 ?>>, *>>


newtype FilesQ = FilesQ [BSU]
    deriving (Typeable,Eq,Hashable,Binary,NFData)

newtype FilesA = FilesA [FileTime]
    deriving (Typeable,Eq,Hashable,Binary,NFData)

instance Show FilesA where show (FilesA xs) = unwords $ "FileTimeHashes" : map show xs

instance Show FilesQ where show (FilesQ xs) = unwords $ map (showQuote . unpackU) xs


instance Rule FilesQ FilesA where
    storedValue (FilesQ xs) = fmap (fmap FilesA . sequence) $ mapM getModTimeMaybe xs


-- | Define a rule for building multiple files at the same time.
--   As an example, a single invokation of GHC produces both @.hi@ and @.o@ files:
--
-- @
-- [\"*.o\",\"*.hi\"] '*>>' \\[o,hi] -> do
--     let hs = o 'Development.Shake.FilePath.-<.>' \"hs\"
--     'Development.Shake.need' ... -- all files the .hs import
--     'Development.Shake.cmd' \"ghc -c\" [hs]
-- @
--
--   However, in practice, it's usually easier to define rules with '*>' and make the @.hi@ depend
--   on the @.o@. When defining rules that build multiple files, all the 'FilePattern' values must
--   have the same sequence of @\/\/@ and @*@ wildcards in the same order.
--   This function will create directories for the result files, if necessary.
(*>>) :: [FilePattern] -> ([FilePath] -> Action ()) -> Rules ()
-- Should probably have been called &*>, since it's an and (&&) of *>
ps *>> act
    | not $ compatible ps = error $
        "All patterns to *>> must have the same number and position of // and * wildcards\n" ++
        unwords ps
    | otherwise = do
        forM_ ps $ \p ->
            p *> \file -> do
                _ :: FilesA <- apply1 $ FilesQ $ map (packU . substitute (extract p file)) ps
                return ()
        rule $ \(FilesQ xs_) -> let xs = map unpackU xs_ in
            if not $ length xs == length ps && and (zipWith (?==) ps xs) then Nothing else Just $ do
                liftIO $ mapM_ (createDirectoryIfMissing True) $ fastNub $ map takeDirectory xs
                act xs
                liftIO $ getFileTimes "*>>" xs_


-- | Define a rule for building multiple files at the same time, a more powerful
--   and more dangerous version of '*>>'.
--
--   Given an application @test ?>> ...@, @test@ should return @Just@ if the rule applies, and should
--   return the list of files that will be produced. This list /must/ include the file passed as an argument and should
--   obey the invariant:
--
-- > forAll $ \x ys -> test x == Just ys ==> x `elem` ys && all ((== Just ys) . test) ys
--
--   As an example of a function satisfying the invariaint:
--
-- @
--test x | 'Development.Shake.FilePath.takeExtension' x \`elem\` [\".hi\",\".o\"]
--        = Just ['Development.Shake.FilePath.dropExtension' x 'Development.Shake.FilePath.<.>' \"hi\", 'Development.Shake.FilePath.dropExtension' x 'Development.Shake.FilePath.<.>' \"o\"]
--test _ = Nothing
-- @
--
--   Regardless of whether @Foo.hi@ or @Foo.o@ is passed, the function always returns @[Foo.hi, Foo.o]@.
(?>>) :: (FilePath -> Maybe [FilePath]) -> ([FilePath] -> Action ()) -> Rules ()
-- Should probably have been called &?>, since it's an and (&&) of ?>
(?>>) test act = do
    let checkedTest x = case test x of
            Nothing -> Nothing
            Just ys | x `elem` ys && all ((== Just ys) . test) ys -> Just ys
                    | otherwise -> error $ "Invariant broken in ?>> when trying on " ++ x

    isJust . checkedTest ?> \x -> do
        _ :: FilesA <- apply1 $ FilesQ $ map packU $ fromJust $ test x
        return ()

    rule $ \(FilesQ xs_) -> let xs@(x:_) = map unpackU xs_ in
        case checkedTest x of
            Just ys | ys == xs -> Just $ do
                liftIO $ mapM_ (createDirectoryIfMissing True) $ fastNub $ map takeDirectory xs
                act xs
                liftIO $ getFileTimes "?>>" xs_
            Just ys -> error $ "Error, ?>> is incompatible with " ++ show xs ++ " vs " ++ show ys
            Nothing -> Nothing


getFileTimes :: String -> [BSU] -> IO FilesA
getFileTimes name xs = do
    ys <- mapM getModTimeMaybe xs
    case sequence ys of
        Just ys -> return $ FilesA ys
        Nothing -> do
            let missing = length $ filter isNothing ys
            error $ "Error, " ++ name ++ " rule failed to build " ++ show missing ++
                    " file" ++ (if missing == 1 then "" else "s") ++ " (out of " ++ show (length xs) ++ ")" ++
                    concat ["\n  " ++ unpackU x ++ if isNothing y then " - MISSING" else "" | (x,y) <- zip xs ys]
