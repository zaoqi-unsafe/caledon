{-# LANGUAGE
 FlexibleInstances,
 BangPatterns,
 FlexibleContexts,
 TemplateHaskell,
 NoMonomorphismRestriction
 #-}
module AST where

import qualified Data.Foldable as F
import Data.Functor
import qualified Data.Set as S
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import Data.List

import Control.Lens


type Name = String

data Spine = Spine Name [Type]
           | Abs Name Type Spine 
           deriving (Eq)
                    
instance Monoid Spine where 
  mempty  = undefined
  mappend = undefined
instance Monoid Bool where 
  mempty  = undefined
  mappend = undefined

type Kind = Spine
type Type = Spine
type Term = Spine
data Decl = Predicate { _declIsSound :: !Bool
                      , _declName :: !Name
                      , _declType :: !Type
                      , _declConstructors :: ![(Bool,(Name,Type))] 
                      }
          | Query { _declName :: !Name
                  , _declType :: !Type
                  }
          | Define { _declIsSound :: !Bool
                   , _declName :: !Name
                   , _declValue :: !Term
                   , _declType :: !Type
                   }
          deriving (Eq)


data PredData = PredData { _dataFamily :: Maybe Name
                         , _dataSequential :: Bool
                         , _dataPriority :: Integer
                         , _dataSound :: Bool
                         } 
              deriving Show
data FlatPred = FlatPred { _predData :: PredData
                         , _predName :: Name
                         , _predValue :: Maybe Term
                         , _predType :: Type
                         , _predKind :: Kind
                         }
instance Show FlatPred where
  show (FlatPred a b c d e) = "FlatPred ("
                              ++show a++")  ("
                              ++show b++")  ("
                              ++show c++")  ("
                              ++show d++")  ("
                              ++show e++")  ("
                         
$(makeLenses ''PredData)
$(makeLenses ''FlatPred)
$(makeLenses ''Decl)

predFamily = predData . dataFamily
predSequential = predData . dataSequential
predPriority = predData . dataPriority
predSound = predData . dataSound

-------------------------
---  Constraint types ---
-------------------------

data Quant = Forall | Exists deriving (Eq) 

infix 2 :=:  
infixr 1 :&:

-- we can make this data structure mostly strict since the only time we don't 
-- traverse it is when we fail, and in order to fail, we always have to traverse
-- the lhs!
data SCons = In !Bool !Term !Type 
           | !Spine :=: !Spine
           deriving (Eq)
data Constraint = SCons [SCons]
                  -- we don't necessarily have to traverse the rhs of a combination
                  -- so we can make it lazy
                | !Constraint :&: Constraint 
                | Bind !Quant !Name !Type !Constraint
                deriving (Eq)


instance FV SCons where
  freeVariables t = case t of
    In _ t1 t2 -> S.union (freeVariables t1) (freeVariables t2) 
    t1 :=: t2 -> S.union (freeVariables t1) (freeVariables t2) 
    
instance FV Constraint where
  freeVariables t = case t of
    SCons l -> foldr (S.union . freeVariables) mempty l
    Bind _ n t l -> S.union (freeVariables t) (S.delete n $ freeVariables l)
    t1 :&: t2 -> S.union (freeVariables t1) (freeVariables t2)     
        
    
-------------------------
---  Pretty Printing  ---
-------------------------
isTycon "#tycon#" = True
isTycon "#tyconM#" = True
isTycon _ = False

showWithParens t = if (case t of
                          Abs{} -> True
                          Spine "#infer#" _ -> True
                          Spine "#imp_abs#" _ -> True
                          Spine "#forall#" _ -> True
                          Spine "#exists#" _ -> True
                          Spine "#imp_forall#" _ -> True
                          Spine "#ascribe#" _ -> True
                          Spine t _ | isTycon t -> False
                          Spine _ _ -> False
                      ) then "("++show t++")" else show t 

isOperator [] = False
isOperator ('#':_) = False
isOperator (a:_) = not $ elem a ('_':['a'..'z']++['A'..'Z']++['0'..'9'])

instance Show Spine where
  show (Spine ['\'',c,'\''] []) = show c
  show (Spine "#infer#" [_, Abs nm t t']) = "<"++nm++" : "++show t++"> "++show t'
  show (Spine "#ascribe#" (ty:v:l)) = "( "++showWithParens v++ " : " ++ show ty++" ) "++show (Spine "" l)  
  show (Spine "#forall#" [_,Abs nm t t']) | not (S.member nm $ freeVariables t') = showWithParens t++ " → " ++ show t'
  show (Spine "#imp_forall#" [_,Abs nm t t']) | not (S.member nm $ freeVariables t') = showWithParens t++ " ⇒ " ++ show t'
  show (Spine "#forall#" [_,Abs nm t t']) = "["++nm++" : "++show t++"] "++show t'  
  show (Spine "#imp_forall#" [_,Abs nm t t']) = "{"++nm++" : "++show t++"} "++show t'  
  show (Spine "#tycon#" [Spine nm [t]]) = "{"++nm++" = "++show t++"}"
  show (Spine "#tyconM#" [Spine nm [t]]) = "{? "++nm++" = "++show t++"}"
  show (Spine "#exists#" [_,Abs nm t t']) = "∃ "++nm++" : "++show t++". "++show t' 
  show (Spine "#imp_abs#" [_,Abs nm ty t]) = "?λ "++nm++" : "++showWithParens ty++" . "++show t
  show (Spine nm l@[_ , Abs _ _ _]) | isOperator nm = "("++nm++") "++show (Spine "" l)
  show (Spine nm (t:t':l)) | isOperator nm = "( "++showWithParens t++" "++nm++" "++ show t'++" )"++show (Spine "" l)
  show (Spine h l) = h++concatMap showWithParens l
     where showWithParens t = " "++if case t of
                          Abs{} -> True
                          Spine t _ | isTycon t -> False
                          Spine _ lst -> not $ null lst
                      then "("++show t++")" else show t 
  show (Abs nm ty t) = "λ "++nm++" : "++showWithParens ty++" . "++show t



instance Show Decl where
  show a = case a of
    Predicate s nm ty [] -> showDef s ++ nm ++ " : " ++ show ty
    Predicate s nm ty (a:cons) ->
      showDef s++ nm ++ " : " ++ show ty++showSingle a ++ concatMap (\x-> showSingle x) cons
      where showSingle (b,(nm,ty)) = (if b then "\n  >| " else "\n   | ") ++nm ++ " = " ++ show ty
    Query nm val -> "query " ++ nm ++ " = " ++ show val
    Define s nm val ty -> showDef s ++ nm ++ " : " ++ show ty ++"\n as "++show val
    where showDef True = "defn "
          showDef False = "unsound "


instance Show Quant where
  show Forall = "∀"
  show Exists = "∃"  
  
instance Show SCons where
  show (a :=: b) = show a++" ≐ "++show b
  show (In True a b) = show a++" ∈ˢ "++show b
  show (In False a b) = show a++" ∈ "++show b
  
instance Show Constraint where
  show (SCons []) = " ⊤ "
  show (SCons l) = concat $ intersperse " ∧ " $ map show l
  show (a :&: b) = show a++" ∧ "++show b
  
  show (Bind q n ty c) = show q++" "++ n++" : "++show ty++" . "++showWithParens c
    where showWithParens Bind{} = show c
          showWithParens _ = "( "++show c++" )"

-----------------------------
--- Constraint Properties ---          
-----------------------------          
instance Monoid Constraint where
  mempty = SCons []
  mappend (SCons []) b = b
  mappend a (SCons []) = a
  mappend (SCons a) (SCons b) = SCons $ a++b
  mappend a b = a :&: b

{-# RULES
 "mappendmempty" mappend mempty = id
 #-}

{-# RULES
 "memptymappend" flip mappend mempty = id
 #-}


----------------------
--- Free Variables ---
----------------------
class FV a where         
  freeVariables :: a -> S.Set Name
instance (FV a, F.Foldable f) => FV (f a) where
  freeVariables m = F.foldMap freeVariables m
instance FV Spine where
  freeVariables t = case t of
    Abs nm t p -> (S.delete nm $ freeVariables p) `mappend` freeVariables t
    Spine t [Spine nm [v]] | isTycon t -> freeVariables v
    Spine "#dontcheck#" [v] -> freeVariables v
    Spine ['\'',_,'\''] [] -> mempty
    Spine head others -> mappend (S.singleton head) $ mconcat $ map freeVariables others


instance FV FlatPred where
  freeVariables p = freeVariables (p^.predType) `S.union` freeVariables (p^.predKind)
                    `S.union` freeVariables (p^.predValue)
  
--------------------------------
--- Builtin Spines and types ---
--------------------------------
infixr 0 ~>
infixr 0 ~~>
(~>) = forall ""
(~~>) = imp_forall ""

var !nm = Spine nm []

atomName = "prop"
tipeName = "type"
kindName = "#kind#"

atom = var atomName
ty_hole = var "#hole#"
tipe = var tipeName
kind = var kindName  -- can be either a type or an atom
ascribe a t = Spine ("#ascribe#") [t, a]
dontcheck t = Spine ("#dontcheck#") [t]
forall x tyA v = Spine ("#forall#") [tyA, Abs x tyA v]
exists x tyA v = Spine ("#exists#") [tyA, Abs x tyA v]
pack e tau imp tp interface = Spine "pack" [tp, Abs imp tp interface, tau, e]
open cl (imp,ty) (p,iface) cty inexp = Spine "#open#" [cl, ty,Abs imp ty iface, Abs imp ty (Abs p iface cty), Abs imp ty (Abs p iface inexp)] 
infer x tyA v = Spine ("#infer#") [tyA, Abs x tyA v]

imp_forall x tyA v = Spine ("#imp_forall#") [tyA, Abs x tyA v]
imp_abs x tyA v = Spine ("#imp_abs#") [tyA, Abs x tyA v]
tycon nm val = Spine "#tycon#" [Spine nm [val]]
tyconM nm val = Spine "#tyconM#" [Spine nm [val]]


consts0 = [ (atomName , tipe)
          ]
          
consts1 = [ ("#forall#", forall "a" atom $ (var "a" ~> atom) ~> atom)
          , ("#imp_forall#", forall "a" atom $ (var "a" ~> atom) ~> atom)
          , ("#exists#", forall "a" atom $ (var "a" ~> atom) ~> atom)
          , (kindName , kind)
          , (tipeName , kind)

          ]
         
consts2 = [ ("#ascribe#", forall "a" atom $ (var "a") ~> (var "a"))
          , ("pack", forall "tp" atom 
                   $ forall "iface" (var "tp" ~> atom) 
                   $ forall "tau" (var "tp") 
                   $ forall "e" (Spine "iface" [var "tau"]) 
                   $ exists "z" (var "tp") (Spine "iface" [var "z"]))
          , ("open", forall "a" atom 
                   $ forall "f" (var "a" ~> atom) 
                   $ forall "tau" kind
                   $ exists "z" (var "a") (Spine "f" [var "z"])
                   ~> (forall "z" (var "a") 
                       $ Spine "f" [var "z"] ~> var "tau")
                   ~> var "tau")
          , ("#imp_abs#", forall "a" atom $ forall "foo" (var "a" ~> atom) $ imp_forall "z" (var "a") (Spine "foo" [var "z"]))            
          , ("#hole#" , imp_forall "a" kind (var "a"))
          ]

consts = consts0 ++ consts1 ++ consts2

anonymous ty = ((False,10000),ty)
anonymousINF ty = ((False,10000),ty)
anonymous0 ty = ((True,-10),ty)
anonymous1 ty = ((False,-8),ty)

envSet = S.fromList $ map fst consts

toNCCchar c = Spine ['\'',c,'\''] []
toNCCstring s = foldr cons nil $ map toNCCchar s
  where char = Spine "char" []
        nil = Spine "nil" [ tycon "A" char]
        cons a l = Spine "cons" [tycon "A" char, a,l]

envConsts = M.union (anonymous0 <$> M.fromList consts0) 
            $ M.union (anonymous1 <$> M.fromList consts1) 
                      (anonymousINF <$> M.fromList consts2)

isChar  ['\'',_,'\''] = True
isChar _ = False