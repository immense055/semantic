{-# LANGUAGE DeriveAnyClass #-}
module Language.Ruby.Syntax where

import Control.Monad (unless)
import Control.Abstract.Value (MonadValue)
import Data.Abstract.Environment
import Data.Abstract.Evaluatable
import Data.Abstract.Value (LocationFor)
import Diffing.Algorithm
import Prelude hiding (fail)
import Prologue
import qualified Data.Map as Map

data Require a = Require { requireRelative :: Bool, requirePath :: !a }
  deriving (Diffable, Eq, Foldable, Functor, GAlign, Generic1, Mergeable, Ord, Show, Traversable, FreeVariables1)

instance Eq1 Require where liftEq = genericLiftEq
instance Ord1 Require where liftCompare = genericLiftCompare
instance Show1 Require where liftShowsPrec = genericLiftShowsPrec

instance Evaluatable Require where
  eval (Require _ x) = do
    name <- pathToQualifiedName <$> (subtermValue x >>= asString)
    importedEnv <- isolate (require name)
    modifyGlobalEnv (flip (Map.foldrWithKey envInsert) (unEnvironment importedEnv))
    unit

newtype Load a = Load { loadArgs :: [a] }
  deriving (Diffable, Eq, Foldable, Functor, GAlign, Generic1, Mergeable, Ord, Show, Traversable, FreeVariables1)

instance Eq1 Load where liftEq = genericLiftEq
instance Ord1 Load where liftCompare = genericLiftCompare
instance Show1 Load where liftShowsPrec = genericLiftShowsPrec

instance Evaluatable Load where
  eval (Load [x]) = do
    path <- subtermValue x >>= asString
    doLoad path False
  eval (Load [x, wrap]) = do
    path <- subtermValue x >>= asString
    shouldWrap <- subtermValue wrap >>= toBool
    doLoad path shouldWrap
  eval (Load _) = fail "invalid argument supplied to load, path is required"

doLoad :: (MonadAnalysis term value m, MonadValue value m, Ord (LocationFor value)) => ByteString -> Bool -> m value
doLoad path shouldWrap = do
  let name = pathToQualifiedName path
  importedEnv <- isolate (load name)
  unless shouldWrap $ modifyGlobalEnv (flip (Map.foldrWithKey envInsert) (unEnvironment importedEnv))
  unit
  where pathToQualifiedName = qualifiedName . splitOnPathSeparator' dropExtension

-- TODO: autoload
