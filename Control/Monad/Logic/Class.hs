-------------------------------------------------------------------------
-- |
-- Module      : Control.Monad.Logic.Class
-- Copyright   : (c) Dan Doel
-- License     : BSD3
-- Maintainer  : Andrew Lelechenko <andrew.lelechenko@gmail.com>
--
-- Adapted from the paper
-- <http://okmij.org/ftp/papers/LogicT.pdf Backtracking, Interleaving, and Terminating Monad Transformers>
-- by Oleg Kiselyov, Chung-chieh Shan, Daniel P. Friedman, Amr Sabry.
-------------------------------------------------------------------------

{-# LANGUAGE Safe #-}

module Control.Monad.Logic.Class (MonadLogic(..), reflect) where

import Control.Applicative
import Control.Monad
import Control.Monad.Reader (ReaderT(..))
import Control.Monad.Trans (MonadTrans(..))
import qualified Control.Monad.State.Lazy as LazyST
import qualified Control.Monad.State.Strict as StrictST

-- | A backtracking, logic programming monad.
class (Monad m, Alternative m) => MonadLogic m where
    -- | Attempts to __split__ the computation, giving access to the first
    --   result. Satisfies the following laws:
    --
    --   > msplit empty          == pure Nothing
    --   > msplit (pure a <|> m) == pure (Just (a, m))
    msplit     :: m a -> m (Maybe (a, m a))

    -- | __Fair disjunction.__ It is possible for a logical computation
    --   to have an infinite number of potential results, for instance:
    --
    --   > odds = pure 1 <|> fmap (+ 2) odds
    --
    --   Such computations can cause problems in some circumstances. Consider:
    --
    --   > do x <- odds <|> pure 2
    --   >    if even x then pure x else empty
    --
    --   Such a computation may never consider the @pure 2@, and
    --   will therefore never return any results. By contrast, using
    --   'interleave' in place of 'Control.Applicative.<|>' ensures fair consideration
    --   of both branches of a disjunction.
    --
    --   Note that even with 'interleave' this computation will never
    --   terminate after returning 2: only the first value can be
    --   safely observed, after which each odd value becomes 'Control.Applicative.empty'
    --   (equivalent to a
    --   <http://lpn.swi-prolog.org/lpnpage.php?pagetype=html&pageid=lpn-htmlse45 Prolog @fail@>)
    --   which does not stop the evaluation but indicates there is no
    --   value to return yet.
    --
    interleave :: m a -> m a -> m a

    -- | __Fair conjunction.__ Similarly to the previous function, consider
    --   the distributivity law, naturally expected from 'MonadPlus':
    --
    --   > (a <|> b) >>= k = (a >>= k) <|> (b >>= k)
    --
    --   If @(a >>= k)@ can backtrack arbitrarily many times, @(b >>= k)@
    --   may never be considered. In logic statements,
    --   "backtracking" is the process of discarding the current
    --   possible solution value and returning to a previous decision
    --   point where a new value can be obtained and tried.  For
    --   example:
    --
    --   >>> do { x <- pure 0 <|> pure 1 <|> pure 2; if even x then pure x else empty } :: [Int]
    --   [0,2]
    --
    --   Here, the @x@ value can be produced three times, where
    --   'Control.Applicative.<|>' represents the decision points of that
    --   production.  The subsequent @if@ statement specifies
    --   'Control.Applicative.empty' (fail)
    --   if @x@ is odd, causing it to be discarded and a return
    --   to an 'Control.Applicative.<|>' decision point to get the next @x@.
    --
    --   The statement @(a >>= k)@ "can backtrack arbitrarily many
    --   times" means that the computation is resulting in 'Control.Applicative.empty' and
    --   that @a@ has an infinite number of 'Control.Applicative.<|>' applications to
    --   return to.  This is called a conjunctive computation because
    --   the logic for @a@ /and/ @k@ must both succeed (i.e. 'pure'
    --   a value instead of 'Control.Applicative.empty').
    --
    --   Similar to the way 'interleave' allows both branches of a
    --   disjunctive computation, the '>>-' operator takes care to
    --   consider both branches of a conjunctive computation.
    --
    --   Consider the operation:
    --
    --   > odds = pure 1 <|> fmap (2 +) odds
    --   >
    --   > oddsPlus n = odds >>= \a -> pure (a + n)
    --   >
    --   > do x <- (pure 0 <|> pure 1) >>= oddsPlus
    --   >    if even x then pure x else empty
    --
    --   This will never produce any value because all values produced
    --   by the @do@ program come from the @pure 1@ driven operation
    --   (adding one to the sequence of odd values, resulting in the
    --   even values that are allowed by the test in the second line),
    --   but the @pure 0@ input to @oddsPlus@ generates an infinite
    --   number of 'Control.Applicative.empty' failures so the even values generated by
    --   the @pure 1@ alternative are never seen.  Using
    --   'interleave' here instead of 'Control.Applicative.<|>' does not help due
    --   to the aforementioned distributivity law.
    --
    --   Also note that the @do@ notation desugars to '>>=' bind
    --   operations, so the following would also fail:
    --
    --   > do a <- pure 0 <|> pure 1
    --   >    x <- oddsPlus a
    --   >    if even x then pure x else empty
    --
    --   The solution is to use the '>>-' in place of the normal
    --   monadic bind operation '>>=' when fairness between
    --   alternative productions is needed in a conjunction of
    --   statements (rules):
    --
    --   > do x <- (pure 0 <|> pure 1) >>- oddsPlus
    --   >    if even x then pure x else empty
    --
    --   However, a bit of care is needed when using '>>-' because
    --   unlike '>>=', it is not associative.  For example:
    --
    --   >>> let m = [10,2,7] :: [Integer]
    --   >>> let k x = [x, x + 1]
    --   >>> let h x = [x, x * 2]
    --   >>> m >>= (\x -> k x >>= h) == (m >>= k) >>= h
    --   True
    --   >>> m >>- (\x -> k x >>- h) == (m >>- k) >>- h
    --   False
    --
    --   This means that the following will be productive:
    --
    --   >>> (pure 0 <|> pure 1) >>-
    --   >>>    oddsPlus >>-
    --   >>>    \x -> if even x then pure x else empty
    --
    --   Which is equivalent to
    --
    --   >>> ((pure 0 <|> pure 1) >>- oddsPlus) >>-
    --   >>>    (\x -> if even x then pure x else empty)
    --
    --   But the following will /not/ be productive:
    --
    --   >>> (pure 0 <|> pure 1) >>-
    --   >>> (\a -> (oddsPlus a >>- \x -> if even x then pure x else empty))
    --
    --   Since do notation desugaring results in the latter, the
    --   @RebindableSyntax@ language pragma cannot easily be used
    --   either.  Instead, it is recommended to carefully use explicit
    --   '>>-' only when needed.
    --
    (>>-)      :: m a -> (a -> m b) -> m b
    infixl 1 >>-

    -- | Logical __conditional.__ The equivalent of
    --   <http://lpn.swi-prolog.org/lpnpage.php?pagetype=html&pageid=lpn-htmlse44 Prolog's soft-cut>.
    --   If its first argument succeeds at all, then the results will be fed into
    --   the success branch. Otherwise, the failure branch is taken.
    --   satisfies the following laws:
    --
    --   > ifte (pure a) th el       == th a
    --   > ifte empty th el          == el
    --   > ifte (pure a <|> m) th el == th a <|> (m >>= th)
    ifte       :: m a -> (a -> m b) -> m b -> m b

    -- | __Pruning.__ Selects one result out of many. Useful for when multiple
    --   results of a computation will be equivalent, or should be treated as
    --   such.
    once       :: m a -> m a

    -- | __Inverts__ a logic computation. If @m@ succeeds with at least one value,
    --   @lnot m@ fails. If @m@ fails, then @lnot m@ succeeds with the value @()@.
    lnot :: m a -> m ()

    -- All the class functions besides msplit can be derived from msplit, if
    -- desired
    interleave m1 m2 = msplit m1 >>=
                        maybe m2 (\(a, m1') -> pure a <|> interleave m2 m1')

    m >>- f = do (a, m') <- maybe empty pure =<< msplit m
                 interleave (f a) (m' >>- f)

    ifte t th el = msplit t >>= maybe el (\(a,m) -> th a <|> (m >>= th))

    once m = do (a, _) <- maybe empty pure =<< msplit m
                pure a

    lnot m = ifte (once m) (const empty) (pure ())


-------------------------------------------------------------------------------
-- | The inverse of msplit. Satisfies the following law:
--
-- > msplit m >>= reflect == m
reflect :: Alternative m => Maybe (a, m a) -> m a
reflect Nothing = empty
reflect (Just (a, m)) = pure a <|> m

-- An instance of MonadLogic for lists
instance MonadLogic [] where
    msplit []     = pure Nothing
    msplit (x:xs) = pure $ Just (x, xs)

-- | Note that splitting a transformer does
-- not allow you to provide different input
-- to the monadic object returned.
-- For instance, in:
--
-- > let Just (_, rm') = runReaderT (msplit rm) r in runReaderT rm' r'
--
-- @r'@ will be ignored, because @r@ was already threaded through the
-- computation.
instance MonadLogic m => MonadLogic (ReaderT e m) where
    msplit rm = ReaderT $ \e -> do r <- msplit $ runReaderT rm e
                                   case r of
                                     Nothing -> pure Nothing
                                     Just (a, m) -> pure (Just (a, lift m))

-- | See note on splitting above.
instance (MonadLogic m, MonadPlus m) => MonadLogic (StrictST.StateT s m) where
    msplit sm = StrictST.StateT $ \s ->
                    do r <- msplit (StrictST.runStateT sm s)
                       case r of
                            Nothing          -> pure (Nothing, s)
                            Just ((a,s'), m) ->
                                pure (Just (a, StrictST.StateT (const m)), s')

    interleave ma mb = StrictST.StateT $ \s ->
                        StrictST.runStateT ma s `interleave` StrictST.runStateT mb s

    ma >>- f = StrictST.StateT $ \s ->
                StrictST.runStateT ma s >>- \(a,s') -> StrictST.runStateT (f a) s'

    ifte t th el = StrictST.StateT $ \s -> ifte (StrictST.runStateT t s)
                                                (\(a,s') -> StrictST.runStateT (th a) s')
                                                (StrictST.runStateT el s)

    once ma = StrictST.StateT $ \s -> once (StrictST.runStateT ma s)

-- | See note on splitting above.
instance (MonadLogic m, MonadPlus m) => MonadLogic (LazyST.StateT s m) where
    msplit sm = LazyST.StateT $ \s ->
                    do r <- msplit (LazyST.runStateT sm s)
                       case r of
                            Nothing -> pure (Nothing, s)
                            Just ((a,s'), m) ->
                                pure (Just (a, LazyST.StateT (const m)), s')

    interleave ma mb = LazyST.StateT $ \s ->
                        LazyST.runStateT ma s `interleave` LazyST.runStateT mb s

    ma >>- f = LazyST.StateT $ \s ->
                LazyST.runStateT ma s >>- \(a,s') -> LazyST.runStateT (f a) s'

    ifte t th el = LazyST.StateT $ \s -> ifte (LazyST.runStateT t s)
                                              (\(a,s') -> LazyST.runStateT (th a) s')
                                              (LazyST.runStateT el s)

    once ma = LazyST.StateT $ \s -> once (LazyST.runStateT ma s)
