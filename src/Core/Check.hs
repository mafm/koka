-----------------------------------------------------------------------------
-- Copyright 2012 Microsoft Corporation.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the file "license.txt" at the root of this distribution.
-----------------------------------------------------------------------------
{-    Typechecker for Core-F 
-}
-----------------------------------------------------------------------------

module Core.Check (checkCore) where

import Control.Monad
import Lib.Trace
import Lib.PPrint
import Common.Failure
import Common.Name
import Common.Unique
import Common.Error
import Common.Range

import Core.Core hiding (check)
import qualified Core.Core as Core
import qualified Core.Pretty as PrettyCore

import Kind.Kind
import Type.Type
import Type.TypeVar
import Type.Assumption
import Type.Pretty
import Type.Kind
import Type.Unify( unify, runUnify )
import Type.Operations( instantiate )

import qualified Data.Set as S

checkCore :: Env -> Int -> Gamma -> DefGroups -> Error () 
checkCore prettyEnv uniq gamma  defGroups
  = case checkDefGroups defGroups (return ()) of
      Check c -> case c uniq (CEnv gamma prettyEnv) of 
                   Ok x _  -> return x
                   Err doc -> warningMsg (rangeNull, doc)
       

{--------------------------------------------------------------------------
  Checking monad
--------------------------------------------------------------------------}  
newtype Check a = Check (Int -> CheckEnv -> Result a)

data CheckEnv = CEnv{ gamma :: Gamma, prettyEnv :: Env }

data Result a = Ok a Int 
              | Err Doc

instance Functor Check where
  fmap f (Check c)  = \u env -> case c u env of Ok x u' -> Ok (f x) u'
                                                Err doc -> Err doc

instance Applicative Check where
  pure  = return
  (<*>) = ap                    

instance Monad Check where
  return x      = Check (\u g -> Ok x u)
  fail s        = Check (\u g -> Err (text s))
  (Check c) >>= f  = Check (\u g -> case c u of 
                                      Ok x u' -> case f x of 
                                                   Check d -> d u' g
                                      err -> err)

instance HasUnique Check where
  updateUnique f = Check (\u g -> Ok u (f u))
  setUnique  i   = Check (\u g -> Ok () i)

extendGamma :: [(Name,NameInfo)] -> Check a -> Check a
extendGamma ex (Check c) = Check (\u env -> c u env{ gamma = (gammaExtends ex (gamma env)) })

getGamma :: Check Gamma
getGamma
  = Check (\u env -> Ok (gamma env) u)

lookupVar :: Name -> Check Scheme
lookupVar name
  = do gamma <- getGamma
       case gammaLookupQ name of
         [info] -> return (infoType info)
         []     -> fail ("unknown variable: " ++ show name)
         _      -> fail ("cannot pick overloaded variable: " ++ show name)

failDoc :: (Env -> Doc) -> Check a
failDoc fdoc
  = Check (\u env -> Err (show (fdoc (prettyEnv env))))


{--------------------------------------------------------------------------
  Definition groups 

  To check a recursive definition group, we assume the type for each 
  definition is correct, add all of those to the environment, then check 
  each definition
--------------------------------------------------------------------------}

checkDefGroups :: DefGroups -> Check a -> Check a
checkDefGroups [] body
  = body
checkDefGroups (dgroup:dgroups) body 
  = checkDefGroup dgroup (checkDefGroups dgroups body)

checkDefGroup :: DefGroup -> Check a -> Check a
checkDefGroup defGroup body  
  = let defs = case defGroup of
                DefRec defs   -> defs
                DefNonRec def -> [def]
        env  = map coreDefInfo defs
    in extendGamma env $
       do mapM_ checkDef defs
          body

checkDef :: Def -> Check () 
checkDef d@(Def name tp expr) 
  = do tp' <- check expr 
       match "checking annotation on definition" (prettyDef d) tp tp'

coreNameInfo :: TName -> NameInfo
coreNameInfo tname = coreNameInfoX tname True

coreNameInfoX tname isVal
  = (getName tname, createNameInfo (getName tname) isVal rangeNull (typeOf tname))

{--------------------------------------------------------------------------
  Expressions   
--------------------------------------------------------------------------}

check :: Expr -> Check Type
check expr 
  = case expr of
      Lam pars eff body
        -> do tpRes <- extendGamma (map coreNameInfo pars) (check body)
              return (typeFun [(name,tp) | TName name tp <- pars] eff tpRes)
      Var tname info
        -> typeOf tname
      Con tname info
        -> typeOf tname
      App fun args
        -> do tpFun <- check fun
              tpArgs <- mapM check args
              case splitFunType tpFun of
                Nothing -> fail "expecting function type in application"
                Just (tpPars,eff,tpRes) 
                  -> do sequence_ [match "comparing formal and actual argument" (prettyExpr expr) formal actual | ((argname,formal),actual) <- zip tpPars tpArgs]
                        return tpRes
      TypeLam x tp
        -> do tp' <- check tp
              return (TForall x tp')
      TypeApp e tps
        -> do tpTForall <- check e
              let (tvars,_,tp) = splitPredType tpTForall  
              -- We can use actual equality for kinds, because any kind variables will have been
              -- substituted when doing kind application (above)
              when (length tps /= length tvars || any [getKind t /= getKind tp | (t,tp) <- zip tvars tps]) $
                failDoc (\env -> text "kind error in type application:" <+> prettyExpr expr env)
              return (subNew (zip tvars tps) |-> tp) 
      Lit lit 
        -> return (typeOf lit)  

      Let defGroups body
        -> checkDefGroups defGroups (check body)
      
      Case exprs branches
        -> do tpScrutinees <- mapM check exprs
              tpBranches   <- mapM (checkBranch tpScrutinees) branches
              mapConseqM (match "verifying that all branches have the same type" (prettyExpr expr)) tpBranches
              return (head tpBranches)
        where
          mapConseqM f [tp1:tp2:tps]
            = do f tp1 tp2
                 mapConseqM (tp2:tps)
          mapConseqM f _ 
            = return ()

{--------------------------------------------------------------------------
  Type of a branch 
--------------------------------------------------------------------------}

checkBranch :: [Type] -> Branch -> Check Type
checkBranch tpScrutinees b@(Branch patterns guard expr) 
  = do mapM_ checkPattern (zip tpScrutinees patterns)
       let vars = [coreNameInfo tname | tname <- S.toList (bv patterns)]
       extendGamma vars $
        do tp <- check guard
           match "verify that the guard is a boolean expression" (prettyExpr guard) tp typeBool
           check expr

checkPattern :: (Type,Pattern) -> Check ()
checkPattern (tpScrutinee,pat)
  = case pat of
      PatCon tname args  -> do constrArgs <- findConstrArgs (prettyPattern pat) tpScrutinee (getName tname)
                               mapM_  checkPattern  (zip constrArgs args)
      PatVar tname       -> match "comparing constructor argument to case annotation" (prettyPattern pat) tpScrutinee (typeOf tname)
      PatWild            -> return ()


{--------------------------------------------------------------------------
  Util 
--------------------------------------------------------------------------}

-- Find the types of the arguments of a constructor,
-- given the type of the result of the constructor
findConstrArgs :: (Env -> Doc) -> Type -> Name -> Check [Type]
findConstrArgs fdoc tpScrutinee con 
  = do tpCon <- lookupVar con
       -- Until we add qualifiers to constructor types, the list of predicates
       -- returned by instantiate' must always be empty
       tpConInst <- instantiate rangeNull tpCon
       let Just (tpArgs, eff, tpRes) = splitFunType tpConInst
       ures <- runUnify (unify tpRes tpScrutinee)
       case ures of
        (Left error, _)  -> showCheck "comparing scrutinee with branch type" "cannot unify" tpRes tpScrutinee fdoc
        (Right _, subst) -> return $ (subst |-> tpArgs)


-- In Core, when we are comparing types, we are interested in exact 
-- matches only.
match :: String -> (Env -> Doc) -> Type -> Type -> Check ()
match when fdoc a b 
  = do ures <- runUnify (unify a b)
       case ures of
         (Left error, _)  -> showCheck "cannot unify" when a b fdoc
         (Right subst, _) -> if subIsNull subst 
                              then return () 
                              else showCheck "non-empty substitution" when a b fdoc 

-- Print unification error
showCheck :: String -> String -> Type -> Type -> (Env -> Doc) -> Check a 
showCheck err when a b fdoc 
  = failDoc (\env -> 
      let [docA,docB] = niceTypes env [a,b]
      in align $ vcat [ text err 
                       , text "     " <> docA
                       , text "  =~ " <> docB
                       , text "when" <+> text when 
                       , indent 2 (fdoc env)
                       ])

prettyExpr e env = PrettyCore.prettyExpr env e
prettyPattern e env = PrettyCore.prettyPattern env e
prettyDef d env     = PrettyCore.prettyDef env d