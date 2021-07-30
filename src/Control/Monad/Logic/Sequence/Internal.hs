{-# LANGUAGE CPP #-}
#include "logict-sequence.h"
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

#ifdef USE_PATTERN_SYNONYMS
{-# LANGUAGE PatternSynonyms #-}
#endif

#if __GLASGOW_HASKELL__ >= 704
{-# LANGUAGE Safe #-}
#endif
{-# OPTIONS_HADDOCK not-home #-}

-- | Based on the LogicT improvements in the paper, Reflection without
-- Remorse. Code is based on the code provided in:
-- https://github.com/atzeus/reflectionwithoutremorse
--
-- Note: that code is provided under an MIT license, so we use that as
-- well.
module Control.Monad.Logic.Sequence.Internal
(
#ifdef USE_PATTERN_SYNONYMS
    SeqT(MkSeqT, getSeqT, ..)
#else
    SeqT(..)
#endif
  , Seq
#ifdef USE_PATTERN_SYNONYMS
  , pattern MkSeq
  , getSeq
#endif
  , View(..)
  , view
  , toView
  , fromView
  , observeAllT
  , observeAll
  , observeManyT
  , observeMany
  , observeT
  , observe
  , fromSeqT
  , hoistPre
  , hoistPost
  , hoistPreUnexposed
  , hoistPostUnexposed
  , toLogicT
  , fromLogicT
  , cons
  , consM
  , choose
  , chooseM
)
where

import Control.Applicative
import Control.Monad
import qualified Control.Monad.Fail as Fail
import Control.Monad.Identity (Identity(..))
import Control.Monad.Trans (MonadTrans(..))
import Control.Monad.Logic.Class
import qualified Control.Monad.Logic as L
import Control.Monad.IO.Class
import Control.Monad.Reader.Class (MonadReader (..))
import Control.Monad.State.Class (MonadState (..))
import Control.Monad.Error.Class (MonadError (..))
import Control.Monad.Morph (MFunctor (..))
import qualified Data.SequenceClass as S
import Control.Monad.Logic.Sequence.Internal.Queue (Queue)
import qualified Text.Read as TR
import Data.Function (on)
#if MIN_VERSION_base(4,9,0)
import Data.Functor.Classes
#endif

#if !MIN_VERSION_base(4,8,0)
import Data.Monoid (Monoid(..))
#endif

#if MIN_VERSION_base(4,9,0)
import Data.Semigroup (Semigroup(..))
#endif

import qualified Data.Foldable as F
import GHC.Generics (Generic)

-- | A view of the front end of a 'SeqT'.
data View m a = Empty | a :< SeqT m a
  deriving Generic
infixl 5 :<

-- | A catamorphism for 'View's.
view :: b -> (a -> SeqT m a -> b) -> View m a -> b
view n _ Empty = n
view _ c (a :< s) = c a s
{-# INLINE view #-}

deriving instance (Show a, Show (SeqT m a)) => Show (View m a)
deriving instance (Read a, Read (SeqT m a)) => Read (View m a)
deriving instance (Eq a, Eq (SeqT m a)) => Eq (View m a)
deriving instance (Ord a, Ord (SeqT m a)) => Ord (View m a)
deriving instance Monad m => Functor (View m)

#if MIN_VERSION_base(4,9,0)
instance (Eq1 m, Monad m) => Eq1 (View m) where
  liftEq _ Empty Empty = True
  liftEq eq (a :< s) (b :< t) = eq a b && liftEq eq s t
  liftEq _ _ _ = False

instance (Ord1 m, Monad m) => Ord1 (View m) where
  liftCompare _ Empty Empty = EQ
  liftCompare _ Empty (_ :< _) = LT
  liftCompare cmp (a :< s) (b :< t) = cmp a b `mappend` liftCompare cmp s t
  liftCompare _ (_ :< _) Empty = GT

instance (Show1 m, Monad m) => Show1 (View m) where
  liftShowsPrec sp sl d val = case val of
    Empty -> ("Empty" ++)
    a :< s -> showParen (d > 5) $
      sp 6 a .
      showString " :< " .
      liftShowsPrec sp sl 6 s
#endif

-- | An asymptotically efficient logic monad transformer. It is generally best to
-- think of this as being defined
--
-- @
-- newtype SeqT m a = 'MkSeqT' { 'getSeqT' :: m ('View' m a) }
-- @
--
-- Using the 'MkSeqT' pattern synonym with 'getSeqT', you can (almost) pretend
-- it's really defined this way! However, the real implementation is different,
-- so as to be more efficient in the face of deeply left-associated `<|>` or
-- `mplus` applications.
newtype SeqT m a = SeqT (Queue (m (View m a)))

#ifdef USE_PATTERN_SYNONYMS
pattern MkSeqT :: Monad m => m (View m a) -> SeqT m a
pattern MkSeqT{getSeqT} <- (toView -> getSeqT)
  where
    MkSeqT = fromView
{-# COMPLETE MkSeqT #-}

pattern MkSeq :: View Identity a -> Seq a
pattern MkSeq{getSeq} <- (runIdentity . toView -> getSeq)
  where
    MkSeq = fromView . Identity
{-# COMPLETE MkSeq #-}
#endif

-- | A specialization of 'SeqT' to the 'Identity' monad. You can
-- imagine that this is defined
--
-- @
-- newtype Seq a = MkSeq { getSeq :: View Identity a }
-- @
--
-- Using the 'MkSeq' pattern synonym with 'getSeq', you can pretend it's
-- really defined this way! However, the real implementation is different,
-- so as to be more efficient in the face of deeply left-associated `<|>`
-- or `mplus` applications.
type Seq = SeqT Identity

fromView :: m (View m a) -> SeqT m a
fromView = SeqT . S.singleton
{-# INLINE fromView #-}

toView :: Monad m => SeqT m a -> m (View m a)
toView (SeqT s) = case S.viewl s of
  S.EmptyL -> return Empty
  h S.:< t -> h >>= \x -> case x of
    Empty -> toView (SeqT t)
    hi :< SeqT ti -> return (hi :< SeqT (ti S.>< t))
{-# INLINEABLE toView #-}
{-# SPECIALIZE INLINE toView :: Seq a -> Identity (View Identity a) #-}

{-
Theorem: toView . fromView = id

Proof:

toView (fromView m)
=
toView (SeqT (singleton m))
=
case viewl (singleton m) of
    h S.:< t -> h >>= \x -> case x of
      Empty -> toView (SeqT t)
      hi :< SeqT ti -> return (hi :< SeqT (ti S.>< t))
=
m >>= \x -> case x of
  Empty -> toView (SeqT S.empty)
  hi :< SeqT ti -> return (hi :< SeqT ti)
=
m >>= \x -> case x of
  Empty -> return Empty
  hi :< SeqT ti -> return (hi :< SeqT ti)
= m
-}

instance (Show (m (View m a)), Monad m) => Show (SeqT m a) where
  showsPrec d s = showParen (d > app_prec) $
      showString "MkSeqT " . showsPrec (app_prec + 1) (toView s)
    where app_prec = 10

instance Read (m (View m a)) => Read (SeqT m a) where
  readPrec = TR.parens $ TR.prec app_prec $ do
      TR.Ident "MkSeqT" <- TR.lexP
      m <- TR.step TR.readPrec
      return (fromView m)
    where app_prec = 10
  readListPrec = TR.readListPrecDefault

instance (Eq a, Eq (m (View m a)), Monad m) => Eq (SeqT m a) where
  (==) = (==) `on` toView
instance (Ord a, Ord (m (View m a)), Monad m) => Ord (SeqT m a) where
  compare = compare `on` toView


#if MIN_VERSION_base(4,9,0)
instance (Eq1 m, Monad m) => Eq1 (SeqT m) where
  liftEq eq s t = liftEq (liftEq eq) (toView s) (toView t)

instance (Ord1 m, Monad m) => Ord1 (SeqT m) where
  liftCompare eq s t = liftCompare (liftCompare eq) (toView s) (toView t)

instance (Show1 m, Monad m) => Show1 (SeqT m) where
  liftShowsPrec sp sl d s = showParen (d > app_prec) $
      showString "MkSeqT " . liftShowsPrec (liftShowsPrec sp sl) (liftShowList sp sl) (app_prec + 1) (toView s)
    where app_prec = 10
#endif

single :: Monad m => a -> m (View m a)
single a = return (a :< mzero)
{-# INLINE single #-}
{-# SPECIALIZE INLINE single :: a -> Identity (View Identity a) #-}

instance Monad m => Functor (SeqT m) where
  {-# INLINEABLE fmap #-}
  fmap f (SeqT q) = SeqT $ fmap (liftM (fmap f)) q
  {-# INLINABLE (<$) #-}
  x <$ SeqT q = SeqT $ fmap (liftM (x <$)) q

instance Monad m => Applicative (SeqT m) where
  {-# INLINE pure #-}
  {-# INLINABLE (<*>) #-}
  pure = fromView . single
  (<*>) = ap
  (*>) = (>>)
#if MIN_VERSION_base(4,10,0)
  liftA2 = liftM2
  {-# INLINABLE liftA2 #-}
#endif

instance Monad m => Alternative (SeqT m) where
  {-# INLINE empty #-}
  {-# INLINEABLE (<|>) #-}
  {-# SPECIALIZE INLINE (<|>) :: Seq a -> Seq a -> Seq a #-}
  empty = SeqT S.empty
  m <|> n = fromView (altView m n)

altView :: Monad m => SeqT m a -> SeqT m a -> m (View m a)
altView (toView -> m) n = m >>= \x -> case x of
  Empty -> toView n
  h :< t -> return (h :< cat t n)
    where cat (SeqT l) (SeqT r) = SeqT (l S.>< r)
{-# INLINE altView #-}

-- | @cons a s = pure a <|> s@
cons :: Monad m => a -> SeqT m a -> SeqT m a
cons a s = fromView (return (a :< s))
{-# INLINE cons #-}

-- | @consM m s = lift m <|> s@
consM :: Monad m => m a -> SeqT m a -> SeqT m a
consM m s = fromView (liftM (:< s) m)
{-# INLINE consM #-}

instance Monad m => Monad (SeqT m) where
  {-# INLINE return #-}
  {-# INLINEABLE (>>=) #-}
  {-# SPECIALIZE INLINE (>>=) :: Seq a -> (a -> Seq b) -> Seq b #-}
  return = fromView . single
  (toView -> m) >>= f = fromView $ m >>= \x -> case x of
    Empty -> return Empty
    h :< t -> f h `altView` (t >>= f)

  {-# INLINEABLE (>>) #-}
  (toView -> m) >> n = fromView $ m >>= \x -> case x of
    Empty -> return Empty
    _ :< t -> n `altView` (t >> n)

#if !MIN_VERSION_base(4,13,0)
  {-# INLINEABLE fail #-}
  fail = Fail.fail
#endif

instance Monad m => Fail.MonadFail (SeqT m) where
  {-# INLINEABLE fail #-}
  fail _ = SeqT S.empty

instance Monad m => MonadPlus (SeqT m) where
  {-# INLINE mzero #-}
  {-# INLINE mplus #-}
  mzero = Control.Applicative.empty
  mplus = (<|>)

#if MIN_VERSION_base(4,9,0)
instance Monad m => Semigroup (SeqT m a) where
  {-# INLINE (<>) #-}
  {-# INLINE sconcat #-}
  (<>) = mplus
  sconcat = foldr1 mplus
#endif

instance Monad m => Monoid (SeqT m a) where
  {-# INLINE mempty #-}
  {-# INLINE mappend #-}
  {-# INLINE mconcat #-}
  mempty = SeqT S.empty
  mappend = (<|>)
  mconcat = F.asum

instance MonadTrans SeqT where
  {-# INLINE lift #-}
  lift m = fromView (m >>= single)

instance Monad m => MonadLogic (SeqT m) where
  {-# INLINE msplit #-}
  {-# SPECIALIZE INLINE msplit :: Seq a -> Seq (Maybe (a, Seq a)) #-}
  msplit (toView -> m) = fromView $ do
    r <- m
    case r of
      Empty -> single Nothing
      a :< t -> single (Just (a, t))

  interleave m1 m2 = fromView $ interleaveView m1 m2

  (toView -> m) >>- f = fromView $ m >>= view
     (return Empty) (\a m' -> interleaveView (f a) (m' >>- f))

  ifte (toView -> t) th (toView -> el) = fromView $ t >>= view
    el
    (\a s -> altView (th a) (s >>= th))

  once (toView -> m) = fromView $ m >>= view
    (return Empty)
    (\a _ -> single a)

  lnot (toView -> m) = fromView $ m >>= view
    (single ()) (\ _ _ -> return Empty)

-- | A version of 'interleave' that produces a view instead of a
-- 'SeqT'. This lets us avoid @toView . fromView@ in '>>-'.
interleaveView :: Monad m => SeqT m a -> SeqT m a -> m (View m a)
interleaveView (toView -> m1) m2 = m1 >>= view
  (toView m2)
  (\a m1' -> return $ a :< interleave m2 m1')

-- | @choose = foldr (\a s -> pure a <|> s) empty@
--
-- @choose :: Monad m => [a] -> SeqT m a@
choose :: (F.Foldable t, Monad m) => t a -> SeqT m a
choose = F.foldr cons empty
{-# INLINABLE choose #-}

-- | @chooseM = foldr (\ma s -> lift ma <|> s) empty@
--
-- @chooseM :: Monad m => [m a] -> SeqT m a@
chooseM :: (F.Foldable t, Monad m) => t (m a) -> SeqT m a
-- The idea here, which I hope is sensible, is to avoid building and
-- restructuring queues unnecessarily. We end up building only *singleton*
-- queues, which should hopefully be pretty cheap.
chooseM = F.foldr consM empty
{-# INLINABLE chooseM #-}

observeAllT :: Monad m => SeqT m a -> m [a]
observeAllT (toView -> m) = m >>= go where
  go (a :< t) = liftM (a:) (toView t >>= go)
  go _ = return []
{-# INLINEABLE observeAllT #-}
{-# SPECIALIZE INLINE observeAllT :: Seq a -> Identity [a] #-}

observeT :: Monad m => SeqT m a -> m (Maybe a)
observeT (toView -> m) = m >>= go where
  go (a :< _) = return (Just a)
  go Empty = return Nothing
{-# INLINE observeT #-}

observeManyT :: Monad m => Int -> SeqT m a -> m [a]
observeManyT k m = toView m >>= go k where
  go n _ | n <= 0 = return []
  go _ Empty = return []
  go n (a :< t) = liftM (a:) (observeManyT (n-1) t)
{-# INLINEABLE observeManyT #-}

observe :: Seq a -> Maybe a
observe = runIdentity . observeT
{-# INLINE observe #-}

observeAll :: Seq a -> [a]
observeAll = runIdentity . observeAllT
{-# INLINE observeAll #-}

observeMany :: Int -> Seq a -> [a]
observeMany n = runIdentity . observeManyT n
{-# INLINE observeMany #-}

-- | Convert @'SeqT' m a@ to @t m a@ when @t@ is some other logic monad
-- transformer.
fromSeqT :: (Monad m, Monad (t m), MonadTrans t, Alternative (t m)) => SeqT m a -> t m a
fromSeqT (toView -> m) = lift m >>= \r -> case r of
  Empty -> empty
  a :< s -> pure a <|> fromSeqT s

-- | Convert @'SeqT' m a@ to @'L.LogicT' m a@.
--
-- @ toLogicT = 'fromSeqT' @
toLogicT :: Monad m => SeqT m a -> L.LogicT m a
toLogicT = fromSeqT

fromLogicT :: Monad m => L.LogicT m a -> SeqT m a
fromLogicT (L.LogicT f) = fromView $ f (\a v -> return (a :< fromView v)) (return Empty)

-- | 'hoist' is 'hoistPre'.
instance MFunctor SeqT where
  -- Note: if `f` is not a monad morphism, then hoist may not respect
  -- (==). That is, it could be that
  --
  --   s == t = True
  --
  --  but
  --
  --   hoist f s == hoist f t = False..
  --
  -- This behavior is permitted by the MFunctor
  -- documentation, and allows us to avoid restructuring
  -- the SeqT.
  hoist f = hoistPre f

-- | This function is the implementation of 'hoist' for 'SeqT'. The passed
-- function is required to be a monad morphism.
hoistPre :: Monad m => (forall x. m x -> n x) -> SeqT m a -> SeqT n a
hoistPre f (SeqT s) = SeqT $ fmap (f . liftM go) s
  where
    go Empty = Empty
    go (a :< as) = a :< hoistPre f as

-- | A version of `hoist` that uses the `Monad` instance for @n@
-- rather than for @m@. Like @hoist@, the passed function is required
-- to be a monad morphism.
hoistPost :: Monad n => (forall x. m x -> n x) -> SeqT m a -> SeqT n a
hoistPost f (SeqT s) = SeqT $ fmap (liftM go . f) s
  where
      go Empty = Empty
      go (a :< as) = a :< hoistPost f as

-- | A version of 'hoist' that works for arbitrary functions, rather
-- than just monad morphisms.
hoistPreUnexposed :: forall m n a. Monad m => (forall x. m x -> n x) -> SeqT m a -> SeqT n a
hoistPreUnexposed f (toView -> m) = fromView $ f (liftM go m)
  where
      go Empty = Empty
      go (a :< as) = a :< hoistPreUnexposed f as

-- | A version of 'hoistPost' that works for arbitrary functions, rather
-- than just monad morphisms. This should be preferred when the `Monad` instance
-- for `n` is less expensive than that for `m`.
hoistPostUnexposed :: forall m n a. (Monad m, Monad n) => (forall x. m x -> n x) -> SeqT m a -> SeqT n a
hoistPostUnexposed f (toView -> m) = fromView $ liftM go (f m)
  where
      go Empty = Empty
      go (a :< as) = a :< hoistPostUnexposed f as

instance MonadIO m => MonadIO (SeqT m) where
  {-# INLINE liftIO #-}
  liftIO = lift . liftIO

instance MonadReader e m => MonadReader e (SeqT m) where
  -- TODO: write more thorough tests for this instance (issue #31)
  ask = lift ask
  local f (SeqT q) = SeqT $ fmap (local f . liftM go) q
    where
      go Empty = Empty
      go (a :< s) = a :< local f s

instance MonadState s m => MonadState s (SeqT m) where
  get = lift get
  put = lift . put
  state = lift . state

instance MonadError e m => MonadError e (SeqT m) where
  -- TODO: write tests for this instance (issue #31)
  throwError = lift . throwError
  catchError (toView -> m) h = fromView $ (liftM go m) `catchError` (toView . h)
    where
      go Empty = Empty
      go (a :< s) = a :< catchError s h
