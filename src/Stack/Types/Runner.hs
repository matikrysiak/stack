{-# LANGUAGE CPP                        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | Run environment

module Stack.Types.Runner
    ( Runner (..)
    , HasRunner (..)
    , terminalL
    , reExecL
    , stickyL
    , logOptionsL
    , Sticky (..)
    , LogOptions (..)
    , ColorWhen (..)
    , withRunner
    ) where

import qualified Data.ByteString.Char8      as S8
import           Data.Char
import           Data.List                  (stripPrefix)
import qualified Data.Text                  as T
import qualified Data.Text.IO               as T
import           Data.Time
import           Distribution.PackageDescription (GenericPackageDescription)
import           GHC.Foreign                (peekCString, withCString)
import           GHC.Stack                  (CallStack, SrcLoc (..), getCallStack)
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax (lift)
import           Lens.Micro
import           Stack.Prelude              hiding (lift)
import           Stack.Constants
import           Stack.Types.PackageIdentifier (PackageIdentifierRevision)
import           System.Console.ANSI
import           System.FilePath
import           System.IO                  (localeEncoding)
import           RIO.Process (HasEnvOverride (..), EnvOverride, getEnvOverride)
import           System.Terminal

-- | Monadic environment.
data Runner = Runner
  { runnerReExec     :: !Bool
  , runnerLogOptions :: !LogOptions
  , runnerTerminal   :: !Bool
  , runnerSticky     :: !Sticky
  , runnerEnvOverride :: !EnvOverride
  , runnerParsedCabalFiles :: !(IORef
      ( Map PackageIdentifierRevision GenericPackageDescription
      , Map (Path Abs Dir)            (GenericPackageDescription, Path Abs File)
      ))
  -- ^ Cache of previously parsed cabal files.
  --
  -- TODO: This is really an ugly hack to avoid spamming the user with
  -- warnings when we parse cabal files multiple times and bypass
  -- performance issues. Ideally: we would just design the system such
  -- that it only ever parses a cabal file once. But for now, this is
  -- a decent workaround. See:
  -- <https://github.com/commercialhaskell/stack/issues/3591>.
  }

class HasEnvOverride env => HasRunner env where
  runnerL :: Lens' env Runner
instance HasEnvOverride Runner where
  envOverrideL = lens runnerEnvOverride (\x y -> x { runnerEnvOverride = y })
instance HasRunner Runner where
  runnerL = id

terminalL :: HasRunner env => Lens' env Bool
terminalL = runnerL.lens runnerTerminal (\x y -> x { runnerTerminal = y })

reExecL :: HasRunner env => Lens' env Bool
reExecL = runnerL.lens runnerReExec (\x y -> x { runnerReExec = y })

stickyL :: HasRunner env => Lens' env Sticky
stickyL = runnerL.lens runnerSticky (\x y -> x { runnerSticky = y })

logOptionsL :: HasRunner env => Lens' env LogOptions
logOptionsL = runnerL.lens runnerLogOptions (\x y -> x { runnerLogOptions = y })

newtype Sticky = Sticky
  { unSticky :: Maybe (MVar (Maybe Text))
  }

data LogOptions = LogOptions
  { logUseColor      :: Bool
  , logTermWidth     :: Int
  , logUseUnicode    :: Bool
  , logUseTime       :: Bool
  , logMinLevel      :: LogLevel
  , logVerboseFormat :: Bool
  }

--------------------------------------------------------------------------------
-- Logging functionality

instance HasLogFunc Runner where
  logFuncL = to $ \env -> stickyLoggerFuncImpl (view stickyL env) (view logOptionsL env)

-- FIXME move into RIO.Logger?
stickyLoggerFuncImpl
    :: Sticky -> LogOptions
    -> (CallStack -> LogSource -> LogLevel -> LogStr -> IO ())
stickyLoggerFuncImpl (Sticky mref) lo loc src level msgTextRaw =
    case mref of
        Nothing ->
            loggerFunc
                lo
                out
                loc
                src
                (case level of
                     LevelOther "sticky-done" -> LevelInfo
                     LevelOther "sticky" -> LevelInfo
                     _ -> level)
                msgTextRaw
        Just ref -> modifyMVar_ ref $ \sticky -> do
            let backSpaceChar = '\8'
                repeating = S8.replicate (maybe 0 T.length sticky)
                clear = S8.hPutStr out
                    (repeating backSpaceChar <>
                     repeating ' ' <>
                     repeating backSpaceChar)

            -- Convert some GHC-generated Unicode characters as necessary
            let msgText
                    | logUseUnicode lo = msgTextRaw
                    | otherwise = T.map replaceUnicode msgTextRaw

            case level of
                LevelOther "sticky-done" -> do
                    clear
                    T.hPutStrLn out msgText
                    hFlush out
                    return Nothing
                LevelOther "sticky" -> do
                    clear
                    T.hPutStr out msgText
                    hFlush out
                    return (Just msgText)
                _
                    | level >= logMinLevel lo -> do
                        clear
                        loggerFunc lo out loc src level msgText
                        case sticky of
                            Nothing ->
                                return Nothing
                            Just line -> do
                                T.hPutStr out line >> hFlush out
                                return sticky
                    | otherwise ->
                        return sticky
  where
    out = stderr

-- | Replace Unicode characters with non-Unicode equivalents
replaceUnicode :: Char -> Char
replaceUnicode '\x2018' = '`'
replaceUnicode '\x2019' = '\''
replaceUnicode c = c

-- | Logging function takes the log level into account.
loggerFunc :: LogOptions -> Handle -> CallStack -> Text -> LogLevel -> LogStr -> IO ()
loggerFunc lo outputChannel cs _src level msg =
   when (level >= logMinLevel lo)
        (liftIO (do out <- getOutput
                    T.hPutStrLn outputChannel out))
  where
    getOutput = do
      timestamp <- getTimestamp
      l <- getLevel
      lc <- getLoc
      return $ T.concat
        [ T.pack timestamp
        , T.pack l
        , T.pack (ansi [Reset])
        , msg
        , T.pack lc
        , T.pack (ansi [Reset])
        ]
     where
       ansi xs | logUseColor lo = setSGRCode xs
               | otherwise = ""
       getTimestamp
         | logVerboseFormat lo && logUseTime lo =
           do now <- getZonedTime
              return $
                  ansi [SetColor Foreground Vivid Black]
                  ++ formatTime' now ++ ": "
         | otherwise = return ""
         where
           formatTime' =
               take timestampLength . formatTime defaultTimeLocale "%F %T.%q"
       getLevel
         | logVerboseFormat lo =
           return ((case level of
                      LevelDebug -> ansi [SetColor Foreground Dull Green]
                      LevelInfo -> ansi [SetColor Foreground Dull Blue]
                      LevelWarn -> ansi [SetColor Foreground Dull Yellow]
                      LevelError -> ansi [SetColor Foreground Dull Red]
                      LevelOther _ -> ansi [SetColor Foreground Dull Magenta]) ++
                   "[" ++
                   map toLower (drop 5 (show level)) ++
                   "] ")
         | otherwise = return ""
       getLoc
         | logVerboseFormat lo =
           return $
               ansi [SetColor Foreground Vivid Black] ++
               "\n@(" ++ fileLocStr ++ ")"
         | otherwise = return ""
       fileLocStr =
         case reverse $ getCallStack cs of
           [] -> "<no call stack found>"
           (_desc, loc):_ ->
             let file = srcLocFile loc
                 line = show $ srcLocStartLine loc
                 char = show $ srcLocStartCol loc
                 dirRoot = $(lift . T.unpack . fromMaybe undefined . T.stripSuffix (T.pack $ "Stack" </> "Types" </> "Runner.hs") . T.pack . loc_filename =<< location)
              in fromMaybe file (stripPrefix dirRoot file) ++
                 ':' :
                 line ++
                 ':' :
                 char

-- | The length of a timestamp in the format "YYYY-MM-DD hh:mm:ss.μμμμμμ".
-- This definition is top-level in order to avoid multiple reevaluation at runtime.
timestampLength :: Int
timestampLength =
  length (formatTime defaultTimeLocale "%F %T.000000" (UTCTime (ModifiedJulianDay 0) 0))

-- | With a sticky state, do the thing.
withSticky :: (MonadIO m)
           => Bool -> (Sticky -> m b) -> m b
withSticky terminal m =
    if terminal
       then do state <- liftIO (newMVar Nothing)
               originalMode <- liftIO (hGetBuffering stdout)
               liftIO (hSetBuffering stdout NoBuffering)
               a <- m (Sticky (Just state))
               state' <- liftIO (takeMVar state)
               liftIO (when (isJust state') (S8.putStr "\n"))
               liftIO (hSetBuffering stdout originalMode)
               return a
       else m (Sticky Nothing)

-- | With a 'Runner', do the thing
withRunner :: MonadIO m
           => LogLevel
           -> Bool -- ^ use time?
           -> Bool -- ^ terminal?
           -> ColorWhen
           -> Maybe Int -- ^ terminal width override
           -> Bool -- ^ reexec?
           -> (Runner -> m a)
           -> m a
withRunner logLevel useTime terminal colorWhen widthOverride reExec inner = do
  useColor <- case colorWhen of
    ColorNever -> return False
    ColorAlways -> return True
    ColorAuto -> liftIO $ hSupportsANSI stderr
  termWidth <- clipWidth <$> maybe (fromMaybe defaultTerminalWidth
                                    <$> liftIO getTerminalWidth)
                                   pure widthOverride
  canUseUnicode <- liftIO getCanUseUnicode
  ref <- newIORef mempty
  menv <- getEnvOverride
  withSticky terminal $ \sticky -> inner Runner
    { runnerReExec = reExec
    , runnerLogOptions = LogOptions
        { logUseColor = useColor
        , logTermWidth = termWidth
        , logUseUnicode = canUseUnicode
        , logUseTime = useTime
        , logMinLevel = logLevel
        , logVerboseFormat = logLevel <= LevelDebug
        }
    , runnerTerminal = terminal
    , runnerSticky = sticky
    , runnerParsedCabalFiles = ref
    , runnerEnvOverride = menv
    }
  where clipWidth w
          | w < minTerminalWidth = minTerminalWidth
          | w > maxTerminalWidth = maxTerminalWidth
          | otherwise = w

-- | Taken from GHC: determine if we should use Unicode syntax
getCanUseUnicode :: IO Bool
getCanUseUnicode = do
    let enc = localeEncoding
        str = "\x2018\x2019"
        test = withCString enc str $ \cstr -> do
            str' <- peekCString enc cstr
            return (str == str')
    test `catchIO` \_ -> return False

data ColorWhen = ColorNever | ColorAlways | ColorAuto
    deriving (Show, Generic)
