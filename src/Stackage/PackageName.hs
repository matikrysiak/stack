{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- | Names for packages.

module Stackage.PackageName
  (PackageName
  ,packageNameParser
  ,parsePackageName
  ,parsePackageNameFromString)
  where

import           Control.Applicative
import           Data.Attoparsec.ByteString.Char8
import           Data.Attoparsec.Combinators
import qualified Data.ByteString.Char8 as S8
import           Data.ByteString.Char8 as S8
import           Data.Char (isLetter)
import           Data.Data
import           Data.Hashable
import           GHC.Generics

-- | A package name.
newtype PackageName =
  PackageName ByteString
  deriving (Eq,Ord,Typeable,Data,Generic,Hashable)

instance Show PackageName where
  show (PackageName n) = S8.unpack n

-- | Attoparsec parser for a package name from bytestring.
packageNameParser :: Parser PackageName
packageNameParser =
  fmap (PackageName . S8.pack)
       (appending (many1 (satisfy isLetter))
                  (concating (many (alternating
                                      (pured (satisfy (\c -> isLetter c ||
                                                              isDigit c)))
                                      (appending (pured (satisfy (== '-')))
                                                 (pured (satisfy isLetter)))))))

-- | Convenient way to parse a package name from a bytestring.
parsePackageName :: ByteString -> Maybe PackageName
parsePackageName =
  either (const Nothing) Just .
  parseOnly (packageNameParser <* endOfInput)

-- | Migration function.
parsePackageNameFromString :: String -> Maybe PackageName
parsePackageNameFromString =
  parsePackageName . S8.pack
