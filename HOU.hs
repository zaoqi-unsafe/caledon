{-# LANGUAGE  
 FlexibleInstances,
 PatternGuards,
 UnicodeSyntax,
 BangPatterns,
 TupleSections
 #-}
module HOU where

import Choice
import AST
import Substitution
import Context
import TopoSortAxioms
import Control.Monad.State (StateT, forM_,runStateT, modify, get,put, State, runState)
import Control.Monad.RWS (RWST, runRWST, ask, tell)
import Control.Monad.Error (throwError, MonadError)
import Control.Monad (unless, forM, replicateM, void, (<=<), when)
import Control.Monad.Trans (lift)
import Control.Applicative
import qualified Data.Foldable as F
import Data.Foldable (foldlM)
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Map as M
import qualified Data.Set as S
import Debug.Trace

import Control.Lens hiding (Choice(..))

import System.IO.Unsafe
import Data.IORef

{-# NOINLINE levelVar #-}
levelVar :: IORef Int
levelVar = unsafePerformIO $ newIORef 0

{-# NOINLINE level #-}
level = unsafePerformIO $ readIORef levelVar

vtrace !i | i < level = trace
vtrace !i = const id

vtraceShow !i1 !i2 s v | i2 < level = trace $ s ++" : "++show v
vtraceShow !i1 !i2 s v | i1 < level = trace s
vtraceShow !i1 !i2 s v = id

throwTrace !i s = vtrace i s $ throwError s

mtrace True = trace
mtrace False = const id

lastBreak l = case reverse l of
  a:r -> (a,reverse r)
  _ -> error "not enough elements"

-----------------------------------------------
---  the higher order unification algorithm ---
-----------------------------------------------

flatten :: Constraint -> Env [SCons]
flatten (Bind quant nm ty c) = do
  modifyCtxt $ addToTail "-flatten-" quant nm ty
  flatten c
flatten (c1 :&: c2) = do
  l1 <- flatten c1
  l2 <- flatten c2
  return $ l1 ++ l2
flatten (SCons l) = return l

type UnifyResult = Maybe (Substitution, [SCons], Bool)

unify :: Constraint -> Env Substitution
unify cons =  do
  cons <- vtrace 0 ("CONSTRAINTS1: "++show cons) $ regenAbsVars cons
  cons <- vtrace 5 ("CONSTRAINTS2: "++show cons) $ flatten cons
  let uniWhile :: Substitution -> [SCons] -> Env (Substitution, [SCons])
      uniWhile !sub c' = fail "" <|> do
        c <- regenAbsVars c'     
        let uniWith !wth backup = searchIn c []
              where searchIn [] r = finish Nothing
                    searchIn (next:l) r = 
                      wth next $ \c1' -> case c1' of
                            Just (sub',next',b) -> finish $ Just (sub', subst sub' (reverse r)++
                                                                        (if b then (++next') else (next'++)) (subst sub' l))
                            Nothing -> searchIn l $ next:r
                    finish Nothing = backup
                    finish (Just (!sub', c')) = do
                      let !sub'' = sub *** sub'
                      modifyCtxt $ subst sub'
                      uniWhile sub'' $! c'
        
        ctxt <- getAllBindings
        
        vtraceShow 2 3 "CONST" c 
          $ vtraceShow 3 3 "CTXT" (reverse ctxt)
          $ uniWith unifyOne 
          $ uniWith unifySearchA
          $ uniWith unifySearchAtomA
          $ uniWith unifySearch
          $ uniWith unifySearchAtom
          $ checkFinished c >> return (sub, c)

  sub <- fst <$> uniWhile mempty cons
  
  return $ sub


checkFinished [] = return ()
checkFinished cval = throwTrace 0 $ "ambiguous constraint: " ++show cval

unifySearchA :: SCons -> CONT_T b Env UnifyResult
unifySearchA (In True a b) return | b /= atom = rightSearch True a b $ newReturn return
unifySearchA _ return = return Nothing

unifySearchAtomA :: SCons -> CONT_T b Env UnifyResult
unifySearchAtomA (In True a b) return = rightSearch True a b $ newReturn return
unifySearchAtomA _ return = return Nothing

newReturn return cons = return $ case cons of
  Nothing -> Nothing
  Just cons -> Just (mempty, cons, False)

unifySearch :: SCons -> CONT_T b Env UnifyResult
unifySearch (In sub a b) return | b /= atom = rightSearch sub a b $ newReturn return
unifySearch _ return = return Nothing

unifySearchAtom :: SCons -> CONT_T b Env UnifyResult
unifySearchAtom (In sub a b) return = rightSearch sub a b $ newReturn return
unifySearchAtom _ return = return Nothing


unifyOne :: SCons -> CONT_T b Env UnifyResult
unifyOne (a :=: b) return = do
  c' <- isolateForFail $ unifyEq $ a :=: b 
  case c' of 
    Nothing -> return =<< (isolateForFail $ unifyEq $ b :=: a)
    r -> return r
unifyOne _ return = return Nothing

impForallPrefix (Spine "#imp_forall#" [ty, Abs nm _ l]) = nm:impForallPrefix l
impForallPrefix _ = []

impAbsPrefix (Spine "#imp_abs#" (ty:(Abs nm _ l):r)) = nm:impAbsPrefix l
impAbsPrefix _ = []


unifyEq cons@(a :=: b) = case (a,b) of 
  (Spine "#ascribe#" (ty:v:l), b) -> return $ Just (mempty, [rebuildSpine v l :=: b], False)
  (b,Spine "#ascribe#" (ty:v:l)) -> return $ Just (mempty, [b :=: rebuildSpine v l], False)
{-  
  (Spine "#imp_forall#" [ty, Abs nm _ l], Spine "#imp_forall#" [ty',Abs nm' _ l']) | nm == nm' -> do
    a <- getNewWith "@aL"
    modifyCtxt $ addToTail "-implicit-" Forall a ty
    return $ Just (mempty, [Abs nm ty l `apply` var a :=: Abs nm' ty' l' `apply` var a , ty :=: ty'], False)

  -- this case doesn't cover the case where we have 
  -- ?\/x : t . A  =:= ?\/x :t . A, but "x in t" isn't necessarily solvable.
    
  -- this is solvable if we defer instantiation of x if we see x in b.
  -- by these rules though, ?\/x y : t1 . A =:= ?\/ y x : t1 . A  is not provable.
  -- this appears to be fine for the moment, although it won't imediately be derivable from the implicit CoC  
  -- where such a statement is true.  
  (Spine "#imp_forall#" [ty, l@(Abs nm _ _)], b) | not $ elem nm $ impForallPrefix b -> vtrace 1 "-implicit-" $ do
    a' <- getNewWith "@aL"
    modifyCtxt $ addToTail "-implicit-" Exists a' ty
    return $ Just (mempty, [l `apply` var a' :=: b , var a' :@: ty], False)
    
  (b, Spine "#imp_forall#" [ty, l@(Abs nm _ _)]) | not $ elem nm $ impForallPrefix b -> vtrace 1 "-implicit-" $ do
    a' <- getNewWith "@aR"
    modifyCtxt $ addToTail "-implicit-" Exists a' ty
    return $ Just (mempty,  [b :=: l `apply` var a' , var a' :@: ty], False)
    
  (Spine "#imp_abs#" (ty:(Abs nm _ l):r), Spine "#imp_abs#" (ty':(Abs nm' _ l'):r')) | nm == nm' -> do
    a <- getNewWith "@aL"
    modifyCtxt $ addToTail "-implicit-" Forall a ty
    return $ Just (mempty, [rebuildSpine (Abs nm ty l) (var a:r) :=: rebuildSpine (Abs nm' ty' l') (var a:r'), ty :=: ty'], False)
    
  (Spine "#imp_abs#" (ty:(l@(Abs nm _ _)):r), b) | not $ elem nm $ impAbsPrefix b -> vtrace 1 ("-imp_abs- : "++show a ++ "\n\t"++show b) $ do
    a <- getNewWith "@iaL"
    modifyCtxt $ addToTail "-imp_abs-" Exists a ty
    return $ Just (mempty, [rebuildSpine l (var a:r) :=: b , var a :@: ty], False)
  (b, Spine "#imp_abs#" (ty:(l@(Abs nm _ _)):r)) | not $ elem nm $ impAbsPrefix b -> vtrace 1 "-imp_abs-" $ do
    a <- getNewWith "@iaR"
    modifyCtxt $ addToTail "-imp_abs-" Exists a ty
    return $ Just (mempty, [b :=: rebuildSpine l (var a:r) , var a :@: ty], False)
-}
  (Spine t1 [Spine nm [_]], Spine t2 [Spine nm' [_]]) | isTycon t1 && isTycon t2 && nm /= nm' -> 
    throwTrace 0 $ "different type constraints: "++show cons
  (Spine t1 [Spine nm [val]], Spine t2 [Spine nm' [val']]) | isTycon t1 && isTycon t2 && nm == nm' -> 
    return $ Just (mempty, [val :=: val'], False)
    
    
  (Spine "#imp_abs#" [ty , Abs nm _ l], Spine "#imp_abs#" [ty' , Abs nm' _ l']) -> do
    unless (nm == nm') $ throwTrace 0 $ "names in ?lambdas: "++show cons
    a <- getNewWith "@aL"
    modifyCtxt $ addToTail "-implicit-" Forall a ty
    return $ Just (mempty, [rebuildSpine (Abs nm ty l) [var a] :=: rebuildSpine (Abs nm' ty' l') [var a], ty :=: ty'], False)
    
  (Spine "#imp_abs#" [ty, l@(Abs nm _ _)], b) -> vtrace 1 ("-imp_abs- : "++show a ++ "\n\t"++show b) $ do
    a <- getNewWith "@iaL"
    modifyCtxt $ addToTail "-imp_abs1-" Forall a ty
    return $ Just (mempty, [rebuildSpine l [var a] :=: b `apply` tycon nm (var a)], False)
  (b, Spine "#imp_abs#" [ty, l@(Abs nm _ _)]) -> vtrace 1 "-imp_abs-" $ do
    a <- getNewWith "@iaR"
    modifyCtxt $ addToTail "-imp_abs2-" Forall a ty
    return $ Just (mempty, [b `apply` tycon nm (var a) :=: rebuildSpine l [var a]], False)
    
  (Spine "#imp_forall#" [ty, av], Spine "#imp_forall#" [ty', av']) -> 
    return $ Just (mempty, [Spine "#imp_abs#" [ty ,av] :=: Spine "#imp_abs#" [ty',av']], False)
  
  (Abs nm ty s , Abs nm' ty' s') -> vtrace 1 "-aa-" $ do
    modifyCtxt $ addToTail "-aa-" Forall nm ty
    return $ Just (mempty, [ty :=: ty', s :=: subst (nm' |-> var nm) s'], False)
  (Abs nm ty s , s') -> vtraceShow 1 2 "-asL-" cons $ do
    modifyCtxt $ addToTail "-asL-" Forall nm ty
    return $ Just (mempty, [s :=: s' `apply` var nm], False)

  (s, Abs nm ty s' ) -> vtraceShow 1 2 "-asR-" cons $ do
    modifyCtxt $ addToTail "-asR-" Forall nm ty
    return $ Just (mempty, [s `apply` var nm :=: s'], False)

  (s , s') | s == s' -> vtrace 1 "-eq-" $ return $ Just (mempty, [], False)
  (s@(Spine x yl), s') -> vtraceShow 4 5 "-ss-" cons $ do
    bind <- getElm ("all: "++show cons) x
    case bind of
      Left bind@Binding{ elmQuant = Exists, elmType = ty } -> vtraceShow 4 5 "-g?-" cons $ do
        fors <- getForallsAfter bind
        exis <- getExistsAfter bind
        case s' of
            b@(Spine x' y'l) -> vtraceShow 4 5 "-gs-" cons $ do
              bind' <- getElm ("gvar-blah: "++show cons) x' 
              case bind' of
                Right ty' -> vtraceShow 1 2 "-gc-" cons $ -- gvar-const
                  if allElementsAreVariablesNoPP fors yl
                  then gvar_const (Spine x yl, ty) (Spine x' y'l, ty')  
                  else return Nothing
                Left Binding{ elmQuant = Forall } | (not $ elem (var x') yl) && S.member x' fors -> 
                  if allElementsAreVariables fors yl 
                  then throwTrace 0 $ "CANT: gvar-uvar-depends: "++show (a :=: b)
                  else return Nothing
                Left Binding{ elmQuant = Forall } | S.member x $ freeVariables y'l -> 
                  if allElementsAreVariables fors yl 
                  then throwTrace 0 $ "CANT: occurs check: "++show (a :=: b)
                  else return Nothing
                Left Binding{ elmQuant = Forall, elmType = ty' } | S.member x' fors -> vtraceShow 1 5 "-gui-" cons $  -- gvar-uvar-inside
                  if allElementsAreVariables fors yl
                  then gvar_uvar_inside (Spine x yl, ty) (Spine x' y'l, ty')
                  else return Nothing
                Left Binding{ elmQuant = Forall, elmType = ty' } -> vtraceShow 1 5 "-guo-" cons $ 
                  if allElementsAreVariablesNoPP fors yl
                  then gvar_uvar_outside (Spine x yl, ty) (Spine x' y'l, ty')
                  else return Nothing
                Left bind'@Binding{ elmQuant = Exists, elmType = ty'} -> vtraceShow 4 5 "-gg-" cons $
                  if not $ allElementsAreVariables fors yl && allElementsAreVariables fors y'l && S.member x' exis
                  then return Nothing 
                  else if x == x' 
                       then vtraceShow 1 2 "-ggs-" cons $ -- gvar-gvar-same
                         gvar_gvar_same (Spine x yl, ty) (Spine x' y'l, ty')
                       else -- gvar-gvar-diff
                         if S.member x $ freeVariables y'l 
                         then throwTrace 0 $ "CANT: ggd-occurs check: "++show (a :=: b)
                         else vtraceShow 1 2 "-ggd-" cons $ gvar_gvar_diff bind (Spine x yl, ty) (Spine x' y'l, ty') bind'
            _ -> vtraceShow 1 5 "-ggs-" cons $ return Nothing
      _ -> vtrace 4 "-u?-" $ case s' of 
        b@(Spine x' _) | x /= x' -> do
          bind' <- getElm ("const case: "++show cons) x'
          case bind' of
            Left Binding{ elmQuant = Exists } -> return Nothing
            _ -> throwTrace 0 ("CANT: -uud- two different universal equalities: "++show (a :=: b)) -- uvar-uvar 

        Spine x' yl' | x == x' -> vtraceShow 1 2 "-uue-" (a :=: b) $ do -- uvar-uvar-eq
          
          let match ((Spine "#tycon#" [Spine nm [a]]):al) bl = case findTyconInPrefix nm bl of
                Nothing -> throwTrace 0 $ "CANT: different numbers of arguments implicit 1: "++show cons
                Just (b,bl) -> ((a :=: b) :) <$> match al bl
              match ((Spine "#tyconM#" [Spine nm [a]]):al) bl = case findTyconInPrefix nm bl of
                Nothing -> match al bl
                Just (b,bl) -> ((a :=: b) :) <$> match al bl                
          -- in this case we know that al has no #tycon#s in its prefix since we exhausted all of them in the previous case
              match al (Spine "#tycon#" [Spine _ [_]]:bl) = throwTrace 0 $ "CANT: different numbers of arguments implicit 2: "++show cons
              match al (Spine "#tyconM#" [Spine _ [_]]:bl) = match al bl 
              match (a:al) (b:bl) = ((a :=: b) :) <$> match al bl 
              match [] [] = return []
              match _ _ = throwTrace 0 $ "CANT: different numbers of arguments: "++show cons 
                                      ++ "\n a-arg : "++(show $ case bind of
                                                                  Right ty -> ty
                                                                  Left b -> elmType b)

          cons <- match yl yl'
          return $ Just (mempty, cons, False)
        _ -> throwTrace 0 $ "CANT: uvar against a pi WITH CONS "++show cons
            
allElementsAreVariables :: S.Set Name -> [Spine] -> Bool
allElementsAreVariables fors = partialPerm mempty 
  where partialPerm s [] = True
        partialPerm s (Spine nm []:l) | S.member nm fors && not (S.member nm s) = 
          partialPerm (S.insert nm s) l
        partialPerm s (Spine t [Spine c [Spine nm []]]:l) | isTycon t && S.member nm fors && not (S.member nm s) = 
          partialPerm (S.insert nm s) l          
        partialPerm _ _ = False
        
allElementsAreVariablesNoPP fors = partial
  where partial [] = True
        partial (Spine t [Spine c [Spine nm []]]:l) | isTycon c && S.member nm fors = partial l
        partial (Spine nm []:l) | S.member nm fors = partial l
        partial _ = False
        

typeToListOfTypes (Spine "#forall#" [_, Abs x ty l]) = (x,ty):typeToListOfTypes l
typeToListOfTypes (Spine "#imp_forall#" [_, Abs x ty l]) = (x,ty):typeToListOfTypes l
typeToListOfTypes (Spine _ _) = []
typeToListOfTypes a@(Abs _ _ _) = error $ "not a type" ++ show a

-- the problem WAS (hopefully) here that the binds were getting
-- a different number of substitutions than the constraints were.
-- make sure to check that this is right in the future.
raiseToTop top@Binding{ elmNext = Just k}  bind@Binding{ elmName = x, elmType = ty } sp m | k == x = 
  m (sp, ty) mempty
raiseToTop top bind@Binding{ elmName = x, elmType = ty } sp m = do
  hl <- reverse <$> getBindingsBetween top bind
  x' <- getNewWith "@newx"
  
  let newx_args = map (var . fst) hl
      sub = x |-> Spine x' newx_args
      
      ty' = foldr (\(nm,ty) a -> forall nm ty a) ty hl
        
      addSub Nothing = return Nothing
      addSub (Just (sub',cons,b)) = do
        -- we need to solve subst twice because we might reify twice
        let sub'' = ((subst sub' <$> sub) *** sub') 

        modifyCtxt $ subst sub'
        return $ Just (sub'', cons,b)
        
  modifyCtxt $ addAfter "-rtt-" (elmName top) Exists x' ty' . removeFromContext x
  vtrace 3 ("RAISING: "++x' ++" +@+ "++ show newx_args ++ " ::: "++show ty'
         ++"\nFROM: "++x ++" ::: "++ show ty
          ) modifyCtxt $ subst sub
  
  -- now we can match against the right hand side
  r <- addSub =<< m (subst sub sp, ty') sub
  modifyCtxt $ removeFromContext x'
  return r

      
getBase 0 a = a
getBase n (Spine "#forall#" [_, Abs _ _ r]) = getBase (n - 1) r
getBase n (Spine "#imp_forall#" [_, Abs _ _ r]) = getBase (n - 1) r
getBase _ a = a

makeBind xN us tyl arg = foldr (uncurry Abs) (Spine xN $ map var arg) $ zip us tyl

gvar_gvar_same (a@(Spine x yl), aty) (b@(Spine _ y'l), _) = do
  aty <- regenAbsVars aty
  let n = length yl
         
      (uNl,atyl) = unzip $ take n $ typeToListOfTypes aty
      
  xN <- getNewWith "@ggs"
  
  let perm = [iyt | (iyt,_) <- filter (\(_,(a,b)) -> a == b) $ zip (zip uNl atyl) (zip yl y'l) ]
      
      l = makeBind xN uNl atyl $ map fst perm
      
      xNty = foldr (uncurry forall) (getBase n aty) perm
      
      sub = x |-> l
      
  modifyCtxt $ addBefore "-ggs-" x Exists xN xNty -- THIS IS DIFFERENT FROM THE PAPER!!!!
  modifyCtxt $ removeFromContext x
  
  return $ Just (sub, [], False) -- var xN :@: xNty])
  
gvar_gvar_same _ _ = error "gvar-gvar-same is not made for this case"

gvar_gvar_diff top (a',aty') (sp, _) bind = raiseToTop top bind sp $ \b subO -> do
  let a = (subst subO a', subst subO aty')
  gvar_gvar_diff' a b
  
gvar_gvar_diff'  (Spine x yl, aty) ((Spine x' y'l), bty) = do
      -- now x' comes before x 
      -- but we no longer care since I tested it, and switching them twice reduces to original
  let n = length yl
      m = length y'l
      
  aty <- regenAbsVars aty
  bty <- regenAbsVars bty
  
  let (uNl,atyl) = unzip $ take n $ typeToListOfTypes aty
      (vNl,btyl) = unzip $ take m $ typeToListOfTypes bty
      
  xN <- getNewWith "@ggd"
  
  let perm = do
        (iyt,y) <- zip (zip uNl atyl) yl
        (i',_) <- filter (\(_,y') -> y == y') $ zip vNl y'l 
        return (iyt,i')
      
      l = makeBind xN uNl atyl $ map (fst . fst) perm
      l' = makeBind xN vNl btyl $ map snd perm
      
      xNty = foldr (uncurry forall) (getBase n aty) (map fst perm)
      
      sub = (x' |-> l') *** (x |-> l) -- M.fromList [(x , l), (x',l')]

  modifyCtxt $ addBefore "-ggd-" x Exists xN xNty -- THIS IS DIFFERENT FROM THE PAPER!!!!
  modifyCtxt $ subst sub . removeFromContext x . removeFromContext x'
  vtrace 3 ("SUBST: -ggd- "++show sub) $ 
    return $ Just (sub, [] {- var xN :@: xNty] -}, False)
  
gvar_uvar_inside a@(Spine _ yl, _) b@(Spine y _, _) = 
  case elemIndex (var y) $ reverse yl of
    Nothing -> return Nothing
    Just _ -> gvar_uvar_possibilities a b
gvar_uvar_inside _ _ = error "gvar-uvar-inside is not made for this case"

gvar_uvar_outside = gvar_const

gvar_const a@(s@(Spine x yl), _) b@(s'@(Spine y _), bty) = gvar_fixed a b $ var . const y
gvar_const _ _ = error "gvar-const is not made for this case"

gvar_uvar_possibilities a@(s@(Spine x yl),_) b@(s'@(Spine y _),bty) = 
  case elemIndex (var y) yl of
    Just i -> gvar_fixed a b $ (!! i)
    Nothing -> throwTrace 0 $ "CANT: gvar-uvar-depends: "++show (s :=: s')
gvar_uvar_possibilities _ _ = error "gvar-uvar-possibilities is not made for this case"

getTyNews (Spine "#forall#" [_, Abs _ _ t]) = Nothing:getTyNews t
getTyNews (Spine "#imp_forall#" [_, Abs nm _ t]) = Just nm:getTyNews t
getTyNews _ = []

gvar_fixed (a@(Spine x _), aty) (b@(Spine _ y'l), bty) action = do
  let m = getTyNews bty
      cons = a :=: b
  
  let getArgs (Spine "#forall#" [ty, Abs ui _ r]) = ((var ui,ui),Left ty):getArgs r
      getArgs (Spine "#imp_forall#" [ty, Abs ui _ r]) = ((tycon ui $ var ui,ui),Right ty):getArgs r
      getArgs _ = []
      
      untylr = getArgs aty
      (un,_) = unzip untylr 
      (vun, _) = unzip un
  
  xm <- forM m $ \j -> do
    x <- getNewWith "@xm"
    return (x, (Spine x vun, case j of
      Nothing -> Spine x vun
      Just a -> tycon a $ Spine x vun))  
      
  let xml = map (snd . snd) xm
      -- when rebuilding the spine we want to use typeconstructed variables if bty contains implicit quantifiers
      toLterm (Spine "#forall#" [ty, Abs ui _ r]) = Abs ui ty $ toLterm r
      toLterm (Spine "#imp_forall#" [ty, Abs ui _ r]) = imp_abs ui ty $ toLterm r      
      toLterm _ = rebuildSpine (action vun) $ xml
      
      l = toLterm aty
  
      vbuild e = foldr (\((_,nm),ty) a -> case ty of
                           Left ty -> forall nm ty a
                           Right ty -> imp_forall nm ty a
                       ) e untylr
                 
      -- returns the list in the same order as xm
      substBty sub (Spine "#forall#" [_, Abs vi bi r]) ((x,xi):xmr) = (x,vbuild $ subst sub bi)
                                                                      :substBty (M.insert vi (fst xi) sub) r xmr
      substBty sub (Spine "#imp_forall#" [_, Abs vi bi r]) ((x,xi):xmr) = (x,vbuild $ subst sub bi)
                                                                          :substBty (M.insert vi (fst xi) sub) r xmr
      substBty _ _ [] = []
      substBty _ s l  = error $ "is not well typed: "++show s
                        ++"\nFOR "++show l 
                        ++ "\nON "++ show cons
      
      sub = x |-> l -- THIS IS THAT STRANGE BUG WHERE WE CAN'T use x in the output substitution!
      addExists s t = vtrace 3 ("adding: "++show s++" ::: "++show t) $ addAfter "-gf-" x Exists s t
      -- foldr ($) addBeforeX [x1...xN]
  modifyCtxt $ flip (foldr ($)) $ uncurry addExists <$> substBty mempty bty xm 
  modifyCtxt $ subst sub . removeFromContext x
  vtrace 4 ("RES: -gg- "++(show $ subst sub $ a :=: b)) $ 
    vtrace 4 ("FROM: -gg- "++(show $ a :=: b)) $ 
    return $ Just (sub, [ subst sub $ a :=: b -- this ensures that the function resolves to the intended output
                        ], False)

gvar_fixed _ _ _ = error "gvar-fixed is not made for this case"

--------------------
--- proof search ---  
--------------------

{-
∃ 6@hole : 5@k . 
∀ 10@sub : 6@hole . ( 10@sub ∈ˢ A → prop )

∃ 6@hole : 5@k . 
∀ 10@sub : 6@hole . 
10@sub ∈ˢ A → prop
--------------------
∃ 6@hole : 5@k . 
∀ 10@sub : 6@hole . 
∀ 24@sX : A . 
∃ z : prop . 
z :=: 10@sub 24@sX  /\  z ∈ˢ prop

----------------------------------------
∃ 6@hole : 5@k . 
∀ 10@sub : 6@hole . 
∀ 24@sX : A . 
10@sub 24@sX ∈ˢ prop
---------------------------------------
∃ 6@hole : 5@k . 
∀ 10@sub : 6@hole . 
∀ 24@sX : A . 
10@sub : 6@hole >> 10@sub 24@sX ∈ˢ prop
---------------------------------------


-}

-- need bidirectional search!
simpleGetType env (Abs n ty i) = forall n ty <$> simpleGetType (M.insert n ty env) i
simpleGetType env (Spine "#imp_abs#" [_,Abs n ty i]) = imp_forall n ty <$> simpleGetType (M.insert n ty env) i
simpleGetType env (Spine nm []) = env ! nm 
simpleGetType env (Spine nm l) | (v,l') <- lastBreak l = 
  case simpleGetType env (Spine nm l') of
    Just (Spine "#forall#" [_, f]) -> Just $ rebuildSpine f [v]
    Just (Spine "#imp_forall#" [ty, f]) -> Just $ rebuildSpine (Spine "#imp_abs#" [ty,f]) [v]
    _ -> Nothing
    
rightSearch :: Bool -> Term -> Type -> CONT_T b Env (Maybe [SCons])
rightSearch sub m goal ret = vtrace 1 ("-rs- "++show m++" ∈ "++show goal) $ fail (show m++" ∈ "++show goal) <|>
  case goal of
    Spine "#forall#" [a, b] -> do
      y <- getNewWith "@sY"
      x' <- getNewWith "@sX"
      let b' = b `apply` var x'
      modifyCtxt $ addToTail "-rsFf-" Forall x' a
      modifyCtxt $ addToTail "-rsFe-" Exists y b'

      ret $ Just [ var y :=: m `apply` var x' 
                 , In sub (var y) b'
                 ]

    Spine "#imp_forall#" [_, Abs x a b] -> do
      y <- getNewWith "@isY"
      x' <- getNewWith "@isX"
      let b' = subst (x |-> var x') b
      modifyCtxt $ addToTail "-rsIf-" Forall x' a        
      modifyCtxt $ addToTail "-rsIe-" Exists y b'
      
      ret $ Just [ var y :=: m `apply` (tycon x $ var x')
                 , In sub (var y) b'
                 ]
        
    Spine "putChar" [c@(Spine ['\'',l,'\''] [])] -> ret $ Just $ (m :=: Spine "putCharImp" [c]):seq action []
      where action = unsafePerformIO $ putStr $ l:[]

    Spine "putChar" [_] -> vtrace 0 "FAILING PUTCHAR" $ ret Nothing
  
    Spine "readLine" [l] -> 
      case toNCCstring $ unsafePerformIO $ getLine of
        s -> do -- ensure this is lazy so we don't check for equality unless we have to.
          y <- getNewWith "@isY"
          let ls = l `apply` s
          modifyCtxt $ addToTail "-rl-" Exists y ls
          ret $ Just [m :=: Spine "readLineImp" [l,s {- this is only safe because lists are lazy -}, var y], In sub (var y) $ Spine "run" [ls]]
    _ | goal == kind -> do
      case m of
        Abs{} -> throwError "not properly typed"
        _ | m == tipe || m == atom -> ret $ Just []
        _ -> breadth -- we should pretty much always use breadth first search here maybe, since this is type search
          where srch r1 r2 = r1 $ F.asum $ r2 . Just . return . (m :=:) <$> [atom , tipe] -- for breadth first
                breadth = srch (ret =<<) return
                depth = srch id (appendErr "" . ret)
    Spine nm l -> do
      constants <- getConstants

      foralls <- getForalls
      exists <- getExists
      ctxt <- getAnonSet      
      let env = M.union foralls constants
      
          isFixed a = isChar a || M.member a env
      
          getFixedType a | isChar a = Just $ anonymous $ var "char"
          getFixedType a = M.lookup a env
          
          isBound m = M.member m constants || S.member m ctxt
          
          isExists m = M.member m exists
          
      let mfam = case m of 
            Abs{} -> Nothing
            Spine nm _ -> case getFixedType nm of
              Just t -> Just (nm,t)
              Nothing -> Nothing
{-
the check "all isBound (S.toList $ freeVariables s)
is the consequence of including everything in the environment without
any abandon for the purposes of search, in the case that the topological sort fails to notice
a dependency.  
-}
          sameFamily (_, (_,Abs{})) = False
          sameFamily ("pack",_) = "#exists#" == nm
          sameFamily (_,(_,s))  = ( not (isBound fam) || fam == nm) && 
                                  all isBound (S.toList $ freeVariables s)
            where fam = getFamily s
          
      targets <- case mfam of
        Just (nm,t) -> return $ [(nm,t)]
        Nothing -> do
          return $ filter sameFamily $ M.toList env


      {- unfortunately we can no longer make the assumption that searches with no free variables 
         are truly satisfying since the type of a search is no longer the same as the type of the variable, 
         ie. ∀ x : A . x ∈ B

         This is a serious assumption to loose because it prevents us
         from ending proof search when our term has been entirely resolved. 

         How can we get it back?   
            1. one option is to have two different ":@:" rules, one for subtyping, 
               and one for traditional search.  This might not cover enough cases.
 
            2. do a local bidirectional type inference, 
               and check that the types of the resultant are syntactically equivalent.

            3. the third and best option is to do both.  
      -}      
      let 
                 
          mTy = simpleGetType (snd <$> (M.union exists env)) m
          isGoal = if mTy == Just goal then True else vtrace 0 ("MTY: "++show mTy++"\nGTY: "++show (Just goal)) False

          ignorable = if all isFixed $ S.toList $ S.union (freeVariables m) (freeVariables goal)
                      then not sub || isGoal
                      else False
          
      if ignorable 
        then ret $ Just []
        else case targets of
          [] -> ret Nothing
          _  -> inter [] $ sortBy (\a b -> compare (getVal a) (getVal b)) targets
            where ls (nm,target) = leftSearch sub (m,goal) (var nm, target)
                  getVal = snd . fst . snd
                  
                  inter [] [] = throwError "no more options"
                  inter cg [] = F.asum $ reverse cg
                  inter cg ((nm,((sequ,_),targ)):l) = do
                    res <- Just <$> ls (nm,targ)
                    if sequ 
                      then (if not $ null cg then (appendErr "" (F.asum $ reverse cg) <|>) else id) $ 
                           (appendErr "" $ ret res) <|> inter [] l
                      else inter (ret res:cg) l
                      
                      
a .-. s = foldr (\k v -> M.delete k v) a s 

leftSearch sub (m,goal) (x,target) = vtrace 1 ("LS: " ++ show x++" ∈ " ++show target++" >> " ++show m ++" ∈ "++ show goal)
                               $ leftCont x target
  where leftCont n target = case target of
          Spine "#forall#" [a, b] -> do
            x' <- getNewWith "@sla"
            modifyCtxt $ addToTail "-lsF-" Exists x' a
            cons <- leftCont (n `apply` var x') (b `apply` var x')
            return $ cons++[In sub (var x') a]

          Spine "#imp_forall#" [_ , Abs x a b] -> do  
            x' <- getNewWith "@isla"
            modifyCtxt $ addToTail "-lsI-" Exists x' a
            cons <- leftCont (n `apply` tyconM x (var x')) (subst (x |-> var x') b)
            return $ cons++[In sub (var x') a]
          Spine _ _ -> do
            return $ [goal :=: target, m :=: n]
          _ -> error $ "λ does not have type atom: " ++ show target


search :: Type -> Env (Substitution, Term)
search ty = do
  e <- getNewWith "@e"
  sub <- unify $ (∃) e ty $ SCons [In False (var e) ty]
  return $ (sub, subst sub $ var e)

-----------------------------
--- constraint generation ---
-----------------------------

(.=.) a b = lift $ tell $ SCons [a :=: b]
(.@.) a b = lift $ tell $ SCons [In False a b]

(.<.) a b = do
  s <- getNewWith "@sub"
  lift $ tell $ (∀) s a $ SCons [In True (var s) b ]
  
(.>.) = flip (.<.)
  
withKind m = do
  k <- getNewWith "@k"
  addToEnv (∃) k kind $ do
    r <- m $ var k
    var k .@. kind    
    return r

check v x = if x == "13@regm+f" then trace ("FOUND AT: "++ v) x else x

checkType :: Spine -> Type -> TypeChecker Spine
checkType sp ty | ty == kind = withKind $ checkType sp
checkType sp ty = case sp of
  Spine "#hole#" [] -> do
    x' <- getNewWith "@hole"
    
    addToEnv (∃) x' ty $ do
      var x' .@. ty
      return $ var x'
      
  Spine "#ascribe#" (t:v:l) -> do
    (v'',mem) <- regenWithMem v
    t <- withKind $ checkType t
    t'' <- regenAbsVars t
    v' <- checkType v'' t
    r <- getNewWith "@r"
    Spine _ l' <- addToEnv (∀) r t'' $ checkType (Spine r l) ty
    return $ rebuildSpine (rebuildFromMem mem v') l'
    
  Spine "#dontcheck#" [v] -> do
    return v
    
  Spine "#infer#" [_, Abs x tyA tyB ] -> do
    tyA <- withKind $ checkType tyA
    
    x' <- getNewWith "@inf"
    addToEnv (∃) x' tyA $ do
      var x' .@. tyA
      checkType (subst (x |-> var x') tyB) ty

  Spine "#imp_forall#" [_, Abs x tyA tyB] -> do
    tyA <- withKind $ checkType tyA
    tyB <- addToEnv (∀) (check "imp_forall" x) tyA $ checkType tyB ty
    return $ imp_forall x tyA tyB
    
  Spine "#forall#" [_, Abs x tyA tyB] -> do
    tyA <- withKind $ checkType tyA
    forall x tyA <$> (addToEnv (∀) (check "forall" x) tyA $ 
      checkType tyB ty )

  -- below are the only cases where bidirectional type checking is useful 
  Spine "#imp_abs#" [_, Abs x tyA sp] -> case ty of
    Spine "#imp_forall#" [_, Abs x' tyA' tyF'] -> do
      unless ("" == x' || x == x') $ 
        lift $ throwTrace 0 $ "can not show: "++show sp ++ " : "++show ty 
                           ++"since: "++x++ " ≠ "++x'
      tyA <- withKind $ checkType tyA
      tyA' .<. tyA
      addToEnv (∀) (check "impabs1" x) tyA $ do
        imp_abs x tyA <$> checkType sp tyF'
        
    _ -> do
      e <- getNewWith "@e"
      tyA <- withKind $ checkType tyA
      withKind $ \k -> addToEnv (∃) e (forall x tyA k) $ do
        ty .>. imp_forall x tyA (Spine e [var x])
        sp <- addToEnv (∀) (check "impabs2" x) tyA $ checkType sp (Spine e [var x])
        return $ imp_abs x tyA $ sp

  Abs x tyA sp -> case ty of
    Spine "#forall#" [_, Abs x' tyA' tyF'] -> do
      tyA <- withKind $ checkType tyA
      tyA' .<. tyA
      addToEnv (∀) (check "abs1" x) tyA $ do
        Abs x tyA <$> checkType sp (subst (x' |-> var x) tyF')
    _ -> do
      e <- getNewWith "@e"
      tyA <- withKind $ checkType tyA
      withKind $ \k -> addToEnv (∃) e (forall "" tyA k) $ do
        ty .>. forall x tyA (Spine e [var x])
        Abs x tyA <$> (addToEnv (∀) (check "abs2" x) tyA $ checkType sp (Spine e [var x]))
  Spine nm [] | isChar nm -> do
    Spine "char" [] .<. ty
    return sp
  Spine head args -> do
    let chop mty [] = do
          ty .>. mty
          return []
          
        chop mty lst@(a:l) = case mty of 
          
          Spine "#imp_forall#" [ty', Abs nm _ tyv] -> case findTyconInPrefix nm lst of
            Nothing -> do
              x <- getNewWith "@xin"
              addToEnv (∃) x ty' $ do
                var x .@. ty' 
                -- we need to make sure that the type is satisfiable such that we can reapply it!
                (tycon nm (var x):) <$> chop (subst (nm |-> var x) tyv) lst

            Just (val,l) -> do
              val <- checkType val ty'
              (tycon nm val:) <$> chop (subst (nm |-> val) tyv) l
          Spine "#forall#" [ty', c] -> do
            a <- checkType a ty'
            (a:) <$> chop (c `apply` a) l
          _ -> withKind $ \k -> do  
            x <- getNewWith "@xin"
            z <- getNewWith "@zin"
            tybody <- getNewWith "@v"
            let tybodyty = forall z (var x) k
            withKind $ \k' -> addToEnv (∃) x k' $ addToEnv (∃) tybody tybodyty $ do 
              a <- checkType a (var x)
              v <- getNewWith "@v"
              forall v (var x) (Spine tybody [var v]) .>. mty
              (a:) <$> chop (Spine tybody [a]) l

    mty <- (M.lookup head) <$> lift getFullCtxt
    
    case mty of 
      Nothing -> lift $ throwTrace 0 $ "variable: "++show head++" not found in the environment."
                                     ++ "\n\t from "++ show sp
                                     ++ "\n\t from "++ show ty
      Just ty' -> Spine head <$> chop (snd ty') args

checkFullType :: Spine -> Type -> Env (Spine, Constraint)
checkFullType val ty = typeCheckToEnv $ checkType val ty


---------------------------------
--- Generalize Free Variables ---
---------------------------------

{- 
Employ the use order heuristic, where 
variables are ordered by use on the same level in terms.

S A F (F A) = {(F,{A,F}), (A,{})}  [A,F,S]
S F A (F A) = {(F,{A,F}), (A,{F})} [F,A,S]
S F (F A S) = {(F,{}), (A,{}), (S,{A,F})} [S,F,A]
S A (F S A) = {(F,{}), (A,{})} 
-}

buildOrderGraph :: S.Set Name -- the list of variables to be generalized
                -> S.Set Name -- the list of previously seen variables
                -> Spine 
                -> State (M.Map Name (S.Set Name)) (S.Set Name) -- an edge in the graph if a variable has occured before this one.
buildOrderGraph gen prev s = case s of
  Abs nm t v -> do
    prev' <- buildOrderGraph gen prev t
    prev'' <- buildOrderGraph (S.delete nm gen) prev v
    return $ S.union prev' prev''
  Spine "#tycon#" [Spine _ [l]] -> buildOrderGraph gen prev l  
  Spine "#tyconM#" [Spine _ [l]] -> buildOrderGraph gen prev l  
  Spine s [t, l] | elem s ["#exists#", "#forall#", "#imp_forall#", "#imp_abs#"] -> do
    prev1 <- buildOrderGraph gen prev t
    prev2 <- buildOrderGraph gen prev l
    return $ S.union prev1 prev2
    
  Spine nm l -> do
    mp <- get
    prev' <- if S.member nm gen
             then do
               let prevs = mp M.! nm
               put $ M.insert nm (S.union prev prevs) mp
               return $ mempty
             else return prev
      
    prev'' <- foldlM (buildOrderGraph gen) prev' l

    if S.member nm gen
      then do
      mp <- get
      let prevs = mp M.! nm
      put $ M.insert nm (S.union prev'' prevs) mp
      return $ S.insert nm $ S.union prev prev'' 
      else return prev''
           
getGenTys sp = S.filter isGen $ freeVariables sp
  where isGen (c:s) = elem c ['A'..'Z']
        
generateBinding sp = foldr (\a b -> imp_forall a ty_hole b) sp orderedgens
  where genset = getGenTys sp
        genlst = S.toList genset
        (_,graph) = runState (buildOrderGraph genset mempty sp) (M.fromList $ map (,mempty) genlst)
        orderedgens = topoSortComp (\a -> (a, graph M.! a)) genlst

----------------------
--- type inference ---
----------------------
typeInfer :: ContextMap -> ((Bool,Integer),Name,Term,Type) -> Choice (Term, Type, ContextMap)
typeInfer env (seqi,nm,val,ty) = (\r -> (\(a,_,_) -> a) <$> runRWST r (M.union envConsts env) emptyState) $ do
  ty <- return $ alphaConvert mempty mempty ty
  val <- return $ alphaConvert mempty mempty val
  
  (ty,mem') <- regenWithMem ty
  (val,mem) <- vtrace 1 ("ALPHAD TO: "++show val) $ regenWithMem val
  
  (val,constraint) <- vtrace 1 ("REGENED TO: "++show val) $ checkFullType val ty
  
  sub <- appendErr ("which became: "++show val ++ "\n\t :  " ++ show ty) $ 
         unify constraint
  
  let resV = rebuildFromMem mem  $ unsafeSubst sub $ val
      resT = rebuildFromMem mem' $ unsafeSubst sub $ ty

  vtrace 0 ("RESULT: "++nm++" : "++show resV) $
      return $ (resV,resT, M.insert nm (seqi,resV) env)

unsafeSubst s (Spine nm apps) = let apps' = unsafeSubst s <$> apps in case s ! nm of 
  Just nm -> rebuildSpine nm apps'
  _ -> Spine nm apps'
unsafeSubst s (Abs nm tp rst) = Abs nm (unsafeSubst s tp) (unsafeSubst s rst)
  
----------------------------
--- the public interface ---
----------------------------

-- type FlatPred = [((Maybe Name,Bool,Integer,Bool),Name,Type,Kind)]

typeCheckAxioms :: Bool -> [FlatPred] -> Choice (Substitution, Substitution)
typeCheckAxioms verbose lst = do
  
  -- check the closedness of families.  this gets done
  -- after typechecking since family checking needs to evaluate a little bit
  -- in order to allow defs in patterns
  let unsound = not . (^. predSound)
      
      tys = M.fromList $ map (\p -> ( p^.predName, ((p^.predSequential,p^.predPriority),p^.predType))) lst
      uns = S.fromList $ map (^.predName) $ filter unsound $ lst
      
      inferAll :: ((Substitution,ContextMap), [FlatPred], [FlatPred]) -> Choice ([FlatPred],(Substitution, ContextMap))
      inferAll (l, r, []) = return (r,l)
      inferAll (_ , r, p:_) | p^.predName == tipeName = throwTrace 0 $ tipeName++" can not be overloaded"
      inferAll (_ , r, p:_) | p^.predName == atomName = throwTrace 0 $ atomName++" can not be overloaded"
      inferAll ((lv,lt) , r, p:toplst) = do
        let fam = p^.predFamily
            b = p^.predSequential
            i = p^.predPriority
            nm = p^.predName
            val = p^.predValue
            ty = p^.predType
            kind = p^.predKind
            
        (ty,kind,lt) <- appendErr ("can not infer type for: "++nm++" : "++show ty) $ 
                            mtrace verbose ("\nChecking: " ++nm) $ 
                            vtrace 0 ("TY: " ++show ty ++"\nKIND: " ++show kind) $ 
                            vtrace 1 ("TY_ENV: " ++show lt)
                            typeInfer lt ((b,i),nm, generateBinding ty,kind) -- constrain the breadth first search to be local!
                            
        val <- case val of
          Just val -> appendErr ("can not infer type for: \n"++nm++" : "++show ty ++"\nnm = "++show val ) $ 
                      mtrace verbose ("Checking Value: "++nm) $ 
                      vtrace 0 ("\tVAL: " ++show val ++"\n\t:: " ++show ty) $ 
                      Just <$> typeInfer lt ((b,i),nm, val,ty)                    
          Nothing -> return Nothing            
                      
        -- do the family check after ascription removal and typechecking because it can involve computation!
        unless (fam == Nothing || Just (getFamily ty) == fam)
          $ throwTrace 0 $ "not the right family: need "++show fam++" for "++nm ++ " = " ++show ty                    
          
        let resp = p & predType .~ ty 
                     & predKind .~ kind 
        inferAll $ case val of
          Just (val,_,_) -> ((M.insert nm val lv, sub' <$> lt), (resp & predValue .~ Just val) :r , sub <$> toplst) 
            where sub' (b,a) = (b, sub a)
                  sub :: (Show a, Subst a) => a -> a
                  sub = subst $ nm |-> ascribe val (dontcheck ty) 
          _ -> ((lv, lt), resp:r, toplst)

  (lst',(lv,lt)) <- inferAll ((mempty,tys), [], topoSortAxioms True lst)
  
  let doubleCheckAll _ [] = return ()
      doubleCheckAll l (p:r) = do
        let nm = p^.predName
            val = p^.predType
            ty = p^.predKind
        
        let usedvars = freeVariables val `S.union` freeVariables ty `S.union` freeVariables val
        unless (S.isSubsetOf usedvars l)
          $ throwTrace 0 $ "Circular type:"
                        ++"\n\t"++nm++" : "++show val ++" : "++show ty
                        ++"\n\tcontains the following circular type dependencies: "
                        ++"\n\t"++show (S.toList $ S.difference usedvars l)
                        ++ "\nPossible Solution: declare it unsound"
                        ++ "\nunsound "++nm++" : "++show val
        doubleCheckAll (S.insert nm l) r
  
  doubleCheckAll (S.union envSet uns) $ topoSortAxioms False lst' 
  
  return $ (lv, snd <$> lt)

topoSortAxioms :: Bool -> [FlatPred] -> [FlatPred]
topoSortAxioms accountPot axioms = showRes $ topoSortComp (\p -> (p^.predName,) 
                                            $ showGraph (p^.predName)
                                            -- unsound can mean this causes extra cyclical things to occur
                                            $ (if accountPot && p^.predSound then S.union (getImplieds $ p^.predName) else id)
                                            $ S.fromList 
                                            $ filter (not . flip elem (map fst consts)) 
                                            $ S.toList $ freeVariables p ) axioms
                        
  where showRes a = vtrace 0 ("TOP_RESULT: "++show ((^.predName) <$> a)) a
        showGraph n a = vtrace 1 ("TOP_EDGE: "++n++" -> "++show a) a

        nm2familyLst  = catMaybes $ (\p -> (p^.predName,) <$> (p^.predFamily)) <$> axioms
        
        family2nmsMap = foldr (\(fam,nm) m -> M.insert nm (case M.lookup nm m of
                                  Nothing -> S.singleton fam
                                  Just s -> S.insert fam s) m
                                )  mempty nm2familyLst
        
        family2impliedsMap = M.fromList $ (\p -> (p^.predName, 
                                                  mconcat 
                                                  $ catMaybes 
                                                  $ map (`M.lookup` family2nmsMap) 
                                                  $ S.toList 
                                                  $ S.union (getImpliedFamilies $ p^.predType) (fromMaybe mempty $ freeVariables <$> p^.predValue)
                                                 )) <$> axioms
        
        getImplieds nm = fromMaybe mempty (M.lookup nm family2impliedsMap)

getImpliedFamilies s = S.intersection fs $ gif s
  where fs = freeVariables s
        gif (Spine "#imp_forall#" [ty,a]) = (case getFamilyM ty of
          Nothing -> id
          Just f | f == atomName -> id
          Just f -> S.insert f) $ gif ty `S.union` gif a 
        gif (Spine a l) = mconcat $ gif <$> l
        gif (Abs _ ty l) = S.union (gif ty) (gif l)


typeCheckAll :: Bool -> [Decl] -> Choice [Decl]
typeCheckAll verbose preds = do
  
  (valMap, tyMap) <- typeCheckAxioms verbose $ toAxioms True preds
  
  let newPreds (Predicate t nm _ cs) = Predicate t nm (tyMap M.! nm) $ map (\(b,(nm,_)) -> (b,(nm, tyMap M.! nm))) cs
      newPreds (Query nm _) = Query nm (tyMap M.! nm)
      newPreds (Define t nm _ _) = Define t nm (valMap M.! nm) (tyMap M.! nm)
  
  return $ newPreds <$> preds

toAxioms :: Bool -> [Decl] -> [FlatPred]
toAxioms b = concat . zipWith toAxioms' [1..]
  where toAxioms' j (Predicate s nm ty cs) = 
          (FlatPred (PredData (Just $ atomName) False j s) nm Nothing ty tipe)
          :zipWith (\(sequ,(nm',ty')) i -> (FlatPred (PredData (Just nm) sequ i False) nm' Nothing ty' atom)) cs [0..]
        toAxioms' j (Query nm val) = [(FlatPred (PredData Nothing False j False) nm Nothing val atom)]
        toAxioms' j (Define s nm val ty) = [ FlatPred (PredData Nothing False j s) nm (Just val) ty kind]
                                           

  
toSimpleAxioms :: [Decl] -> ContextMap
toSimpleAxioms l = M.fromList $ (\p -> (p^.predName, ((p^.predSequential, p^.predPriority), p^.predType))) 
                   <$> toAxioms False l

solver :: ContextMap -> Type -> Either String [(Name, Term)]
solver axioms tp = case runError $ runRWST (search tp) (M.union envConsts axioms) emptyState of
  Right ((_,tm),_,_) -> Right $ [("query", tm)]
  Left s -> Left $ "reification not possible: "++s

reduceDecsByName :: [Decl] -> [Decl]
reduceDecsByName decs = map snd $ M.toList $ M.fromList $ map (\a -> (a ^. declName,a)) decs
