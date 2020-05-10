module Core.Unify

import Core.CaseTree
import Core.Context
import Core.Core
import Core.Env
import Core.GetType
import Core.Normalise
import Core.TT
import public Core.UnifyState
import Core.Value

import Data.IntMap
import Data.List.Views
import Data.NameMap

%default covering

public export
data UnifyMode = InLHS
               | InTerm
               | InMatch
               | InSearch

-- Need to record if we're at the top level or not, because top level things
-- can have Force and Delay inserted, and may have been postponed.
public export
record UnifyInfo where
  constructor MkUnifyInfo
  atTop : Bool
  precise : Bool -- False == generalise to RigW in Pi
  umode : UnifyMode

export
inTerm : UnifyInfo
inTerm = MkUnifyInfo True True InTerm

export
inLHS : UnifyInfo
inLHS = MkUnifyInfo True True InLHS

export
inTermP : Bool -> UnifyInfo
inTermP p = MkUnifyInfo True p InTerm

export
inMatch : UnifyInfo
inMatch = MkUnifyInfo True True InMatch

export
inSearch : UnifyInfo
inSearch = MkUnifyInfo True True InSearch

lam : UnifyInfo -> UnifyInfo
lam = record { precise = True }

inLam : UnifyInfo -> Bool
inLam = precise

lower : UnifyInfo -> UnifyInfo
lower = record { atTop = False }

Eq UnifyMode where
   InLHS == InLHS = True
   InTerm == InTerm = True
   InMatch == InMatch = True
   InSearch == InSearch = True
   _ == _ = False

Eq UnifyInfo where
  x == y = atTop x == atTop y && precise x == precise y && umode x == umode y

Show UnifyMode where
  show InLHS = "InLHS"
  show InTerm = "InTerm"
  show InMatch = "InMatch"
  show InSearch = "InSearch"

-- If we're unifying a Lazy type with a non-lazy type, we need to add an
-- explicit force or delay to the first argument to unification. This says
-- which to add, if any. Can only added at the very top level.
public export
data AddLazy = NoLazy | AddForce LazyReason | AddDelay LazyReason

export
Show AddLazy where
  show NoLazy = "NoLazy"
  show (AddForce _) = "AddForce"
  show (AddDelay _) = "AddDelay"

public export
record UnifyResult where
  constructor MkUnifyResult
  constraints : List Int
  holesSolved : Bool -- did we solve any holes
  namesSolved : List Int -- which ones did we solve (as name indices)
  addLazy : AddLazy

union : UnifyResult -> UnifyResult -> UnifyResult
union u1 u2 = MkUnifyResult (union (constraints u1) (constraints u2))
                            (holesSolved u1 || holesSolved u2)
                            (namesSolved u1 ++ namesSolved u2)
                            NoLazy -- only top level, so assume no annotation

unionAll : List UnifyResult -> UnifyResult
unionAll [] = MkUnifyResult [] False [] NoLazy
unionAll [c] = c
unionAll (c :: cs) = union c (unionAll cs)

constrain : Int -> UnifyResult
constrain c = MkUnifyResult [c] False [] NoLazy

success : UnifyResult
success = MkUnifyResult [] False [] NoLazy

solvedHole : Int -> UnifyResult
solvedHole n = MkUnifyResult [] True [n] NoLazy

public export
interface Unify (tm : List Name -> Type) where
  -- Unify returns a list of ids referring to newly added constraints
  unifyD : Ref Ctxt Defs ->
           Ref UST UState ->
           UnifyInfo ->
           FC -> Env Term vars ->
           tm vars -> tm vars ->
           Core UnifyResult
  -- As unify but at the top level can allow lazy/non-lazy to be mixed in
  -- order to infer annotations
  unifyWithLazyD : Ref Ctxt Defs ->
                   Ref UST UState ->
                   UnifyInfo ->
                   FC -> Env Term vars ->
                   tm vars -> tm vars ->
                   Core UnifyResult
  unifyWithLazyD = unifyD

-- Workaround for auto implicits not working in interfaces
-- In calls to unification, the first argument is the given type, and the second
-- argument is the expected type.
export
unify : Unify tm =>
        {auto c : Ref Ctxt Defs} ->
        {auto u : Ref UST UState} ->
        UnifyInfo ->
        FC -> Env Term vars ->
        tm vars -> tm vars ->
        Core UnifyResult
unify {c} {u} = unifyD c u

export
unifyWithLazy : Unify tm =>
                {auto c : Ref Ctxt Defs} ->
                {auto u : Ref UST UState} ->
                UnifyInfo ->
                FC -> Env Term vars ->
                tm vars -> tm vars ->
                Core UnifyResult
unifyWithLazy {c} {u} = unifyWithLazyD c u

-- Defined in Core.AutoSearch
export
search : {auto c : Ref Ctxt Defs} ->
         {auto u : Ref UST UState} ->
         FC -> RigCount ->
         (defaults : Bool) -> (depth : Nat) ->
         (defining : Name) -> (topTy : Term vars) -> Env Term vars ->
         Core (Term vars)

ufail : FC -> String -> Core a
ufail loc msg = throw (GenericMsg loc msg)

convertError : {auto c : Ref Ctxt Defs} ->
               FC -> Env Term vars -> NF vars -> NF vars -> Core a
convertError loc env x y
    = do defs <- get Ctxt
         empty <- clearDefs defs
         throw (CantConvert loc env !(quote empty env x)
                                    !(quote empty env y))

convertErrorS : {auto c : Ref Ctxt Defs} ->
                Bool -> FC -> Env Term vars -> NF vars -> NF vars -> Core a
convertErrorS s loc env x y
    = if s then convertError loc env y x
           else convertError loc env x y

-- Find all the metavariables required by each of the given names.
-- We'll assume all meta solutions are of the form STerm exp.
chaseMetas : {auto c : Ref Ctxt Defs} ->
             List Name -> NameMap () -> Core (List Name)
chaseMetas [] all = pure (keys all)
chaseMetas (n :: ns) all
    = case lookup n all of
           Just _ => chaseMetas ns all
           _ => do defs <- get Ctxt
                   Just (PMDef _ _ (STerm soln) _ _) <-
                                  lookupDefExact n (gamma defs)
                        | _ => chaseMetas ns (insert n () all)
                   let sns = keys (getMetas soln)
                   chaseMetas (sns ++ ns) (insert n () all)

-- Get all the metavariable names used by the term (recursively, so we
-- can do the occurs check)
getMetaNames : {auto c : Ref Ctxt Defs} ->
               Term vars -> Core (List Name)
getMetaNames tm
    = let metas = getMetas tm in
          chaseMetas (keys metas) empty

postpone : {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST UState} ->
           (blockedMeta : Bool) ->
           FC -> UnifyInfo -> String ->
           Env Term vars -> NF vars -> NF vars -> Core UnifyResult
postpone blockedMetas loc mode logstr env x y
    = do defs <- get Ctxt
         empty <- clearDefs defs
         logC 10 $
              do xq <- quote defs env x
                 yq <- quote defs env y
                 pure (logstr ++ ": " ++ show !(toFullNames xq) ++
                                    " =?= " ++ show !(toFullNames yq))
         xtm <- quote empty env x
         ytm <- quote empty env y
         -- Need to find all the metas in the constraint since solving any one
         -- of them might stop the constraint being blocked.
         metas <-
             if blockedMetas
                then let xmetas = getMetas xtm in
                         chaseMetas (keys (addMetas xmetas ytm)) NameMap.empty
                else pure []
         blocked <- filterM undefinedN metas
         c <- addConstraint (MkConstraint loc (atTop mode) blocked env
                                          xtm
                                          ytm)
         log 10 $ show c ++ " NEW CONSTRAINT " ++ show loc ++
                 " blocked on " ++ show metas
         logTerm 10 "X" xtm
         logTerm 10 "Y" ytm
         pure (constrain c)
  where
    undefinedN : Name -> Core Bool
    undefinedN n
        = do defs <- get Ctxt
             case !(lookupDefExact n (gamma defs)) of
                  Just (Hole _ _) => pure True
                  Just (BySearch _ _ _) => pure True
                  Just (Guess _ _ _) => pure True
                  _ => pure False

postponeS : {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST UState} ->
            Bool -> Bool -> FC -> UnifyInfo -> String -> Env Term vars ->
            NF vars -> NF vars ->
            Core UnifyResult
postponeS b s loc mode logstr env x y
    = if s then postpone b loc (lower mode) logstr env y x
           else postpone b loc mode logstr env x y

unifyArgs : (Unify tm, Quote tm) =>
            {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST UState} ->
            UnifyInfo -> FC -> Env Term vars ->
            List (tm vars) -> List (tm vars) ->
            Core UnifyResult
unifyArgs mode loc env [] [] = pure success
unifyArgs mode loc env (cx :: cxs) (cy :: cys)
    = do -- Do later arguments first, since they may depend on earlier
         -- arguments and use their solutions.
         cs <- unifyArgs mode loc env cxs cys
         res <- unify (lower mode) loc env cx cy
         pure (union res cs)
unifyArgs mode loc env _ _ = ufail loc ""

-- Get the variables in an application argument list; fail if any arguments
-- are not variables, fail if there's any repetition of variables
-- We use this to check that the pattern unification rule is applicable
-- when solving a metavariable applied to arguments
getVars : List Nat -> List (NF vars) -> Maybe (List (Var vars))
getVars got [] = Just []
getVars got (NApp fc (NLocal r idx v) [] :: xs)
    = if inArgs idx got then Nothing
         else do xs' <- getVars (idx :: got) xs
                 pure (MkVar v :: xs')
  where
    -- Save the overhead of the call to APPLY, and the fact that == on
    -- Nat is linear time in Idris 1!
    inArgs : Nat -> List Nat -> Bool
    inArgs n [] = False
    inArgs n (n' :: ns)
        = if toIntegerNat n == toIntegerNat n' then True else inArgs n ns
getVars got (NAs _ _ _ p :: xs) = getVars got (p :: xs)
getVars _ (_ :: xs) = Nothing

-- Make a sublist representing the variables used in the application.
-- We'll use this to ensure that local variables which appear in a term
-- are all arguments to a metavariable application for pattern unification
toSubVars : (vars : List Name) -> List (Var vars) ->
            (newvars ** SubVars newvars vars)
toSubVars [] xs = ([] ** SubRefl)
toSubVars (n :: ns) xs
     -- If there's a proof 'First' in 'xs', then 'n' should be kept,
     -- otherwise dropped
     -- (Remember: 'n' might be shadowed; looking for 'First' ensures we
     -- get the *right* proof that the name is in scope!)
     = let (_ ** svs) = toSubVars ns (dropFirst xs) in
           if anyFirst xs
              then (_ ** KeepCons svs)
              else (_ ** DropCons svs)
  where
    anyFirst : List (Var (n :: ns)) -> Bool
    anyFirst [] = False
    anyFirst (MkVar First :: xs) = True
    anyFirst (MkVar (Later p) :: xs) = anyFirst xs

{- Applying the pattern unification rule is okay if:
   * Arguments are all distinct local variables
   * The metavariable name doesn't appear in the unifying term
   * The local variables which appear in the term are all arguments to
     the metavariable application (not checked here, checked with the
     result of `patternEnv`)

   Return the subset of the environment used in the arguments
   to which the metavariable is applied. If this environment is enough
   to check the term we're unifying with, and that term doesn't use the
   metavariable name, we can safely apply the rule.

   Also, return the list of arguments the metavariable was applied to, to
   make sure we use them in the right order when we build the solution.
-}
patternEnv : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             {vars : _} ->
             Env Term vars -> List (Closure vars) ->
             Core (Maybe (newvars ** (List (Var newvars),
                                     SubVars newvars vars)))
patternEnv {vars} env args
    = do defs <- get Ctxt
         empty <- clearDefs defs
         args' <- traverse (evalArg empty) args
         case getVars [] args' of
              Nothing => pure Nothing
              Just vs =>
                 let (newvars ** svs) = toSubVars _ vs in
                     pure (Just (newvars **
                                     (updateVars vs svs, svs)))
  where
    -- Update the variable list to point into the sub environment
    -- (All of these will succeed because the SubVars we have comes from
    -- the list of variable uses! It's not stated in the type, though.)
    updateVars : List (Var vars) -> SubVars newvars vars -> List (Var newvars)
    updateVars [] svs = []
    updateVars (MkVar p :: ps) svs
        = case subElem p svs of
               Nothing => updateVars ps svs
               Just p' => p' :: updateVars ps svs

getVarsBelowTm : Nat -> List (Term vars) -> Maybe (List (Var vars))
getVarsBelowTm max [] = Just []
getVarsBelowTm max (Local fc r idx v :: xs)
    = if idx >= max then Nothing
         else do xs' <- getVarsBelowTm idx xs
                 pure (MkVar v :: xs')
getVarsBelowTm _ (_ :: xs) = Nothing

export
patternEnvTm : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               {vars : _} ->
               Env Term vars -> List (Term vars) ->
               Core (Maybe (newvars ** (List (Var newvars),
                                       SubVars newvars vars)))
patternEnvTm {vars} env args
    = do defs <- get Ctxt
         empty <- clearDefs defs
         case getVarsBelowTm 1000000 args of
              Nothing => pure Nothing
              Just vs =>
                 let (newvars ** svs) = toSubVars _ vs in
                     pure (Just (newvars **
                                     (updateVars vs svs, svs)))
  where
    -- Update the variable list to point into the sub environment
    -- (All of these will succeed because the SubVars we have comes from
    -- the list of variable uses! It's not stated in the type, though.)
    updateVars : List (Var vars) -> SubVars newvars vars -> List (Var newvars)
    updateVars [] svs = []
    updateVars (MkVar p :: ps) svs
        = case subElem p svs of
               Nothing => updateVars ps svs
               Just p' => p' :: updateVars ps svs

-- Check that the metavariable name doesn't occur in the solution.
-- If it does, normalising might help. If it still does, that's an error.
occursCheck : {auto c : Ref Ctxt Defs} ->
              FC -> Env Term vars -> UnifyInfo ->
              Name -> Term vars -> Core (Maybe (Term vars))
occursCheck fc env mode mname tm
    = do solmetas <- getMetaNames tm
         let False = mname `elem` solmetas
             | _ => do defs <- get Ctxt
                       tmnf <- normalise defs env tm
                       solmetas <- getMetaNames tmnf
                       if mname `elem` solmetas
                          then do failOnStrongRigid False
                                     (throw (CyclicMeta fc env mname tmnf))
                                     tmnf
                                  pure Nothing
                          else pure $ Just tmnf
         pure $ Just tm
  where
    -- Throw an occurs check failure if the name appears 'strong rigid',
    -- that is, under a constructor form rather than a function, in the
    -- term
    failOnStrongRigid : Bool -> Core () -> Term vars -> Core ()
    failOnStrongRigid bad err (Meta _ n _ _)
        = if bad && n == mname
             then err
             else pure ()
    failOnStrongRigid bad err tm
        = case getFnArgs tm of
               (f, []) => pure ()
               (Ref _ Func _, _) => pure () -- might reduce away, just block
               (Ref _ _ _, args) => traverse_ (failOnStrongRigid True err) args
               (f, args) => traverse_ (failOnStrongRigid bad err) args

-- Instantiate a metavariable by binding the variables in 'newvars'
-- and returning the term
-- If the type of the metavariable doesn't have enough arguments, fail, because
-- this wasn't valid for pattern unification
instantiate : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              {newvars : _} ->
              FC -> UnifyInfo -> Env Term vars ->
              (metavar : Name) -> (mref : Int) -> (numargs : Nat) ->
              (mdef : GlobalDef) ->
              List (Var newvars) -> -- Variable each argument maps to
              Term vars -> -- original, just for error message
              Term newvars -> -- shrunk environment
              Core ()
instantiate {newvars} loc mode env mname mref num mdef locs otm tm
    = do logTerm 5 ("Instantiating in " ++ show newvars) tm
--          let Hole _ _ = definition mdef
--              | def => ufail {a=()} loc (show mname ++ " already resolved as " ++ show def)
         case fullname mdef of
              PV pv pi => throw (PatternVariableUnifies loc env (PV pv pi) otm)
              _ => pure ()
         let ty = type mdef -- assume all pi binders we need are there since
                            -- it was built from an environment, so no need
                            -- to normalise
         defs <- get Ctxt
         rhs <- mkDef [] newvars (snocList newvars)
                     (rewrite appendNilRightNeutral newvars in locs)
                     (rewrite appendNilRightNeutral newvars in tm)
                     ty
         logTerm 5 ("Instantiated: " ++ show mname) ty
         log 5 ("From vars: " ++ show newvars)
         logTerm 5 "Definition" rhs
         let simpleDef = MkPMDefInfo (SolvedHole num) (isSimple rhs)
         let newdef = record { definition =
                                 PMDef simpleDef [] (STerm rhs) (STerm rhs) []
                             } mdef
         addDef (Resolved mref) newdef
         removeHole mref
  where
    isSimple : Term vs -> Bool
    isSimple (Local _ _ _ _) = True
    isSimple (Ref _ _ _) = True
    isSimple (Meta _ _ _ _) = True
    isSimple (Bind _ _ (Lam _ _ _) sc) = isSimple sc
    isSimple (PrimVal _ _) = True
    isSimple (TType _) = True
    isSimple _ = False

    updateLoc : {v : Nat} -> List (Var vs) -> .(IsVar name v vs') ->
                Maybe (Var vs)
    updateLoc [] el = Nothing
    updateLoc (p :: ps) First = Just p
    updateLoc (p :: ps) (Later prf) = updateLoc ps prf

    -- Since the order of variables is not necessarily the same in the solution,
    -- this is to make sure the variables point to the right argument, given
    -- the argument list we got from the application of the hole.
    updateLocs : List (Var vs) -> Term vs -> Maybe (Term vs)
    updateLocs locs (Local fc r idx p)
        = do MkVar p' <- updateLoc locs p
             Just (Local fc r _ p')
    updateLocs {vs} locs (Bind fc x b sc)
        = do b' <- updateLocsB b
             sc' <- updateLocs
                       (MkVar First :: map (\ (MkVar p) => (MkVar (Later p))) locs)
                       sc
             Just (Bind fc x b' sc')
      where
        updateLocsB : Binder (Term vs) -> Maybe (Binder (Term vs))
        updateLocsB (Lam c p t) = Just (Lam c p !(updateLocs locs t))
        updateLocsB (Let c v t) = Just (Let c !(updateLocs locs v) !(updateLocs locs t))
        -- Make 'pi' binders have multiplicity W when we infer a Rig1 metavariable,
        -- since this is the most general thing to do if it's unknown.
        updateLocsB (Pi rig p t) = if isLinear rig
            then  do t' <- updateLocs locs t
                     pure $ if inLam mode
                        then (Pi linear p t')
                        else (Pi top p t')
            else Just (Pi rig p !(updateLocs locs t))
        updateLocsB (PVar c p t) = Just (PVar c p !(updateLocs locs t))
        updateLocsB (PLet c v t) = Just (PLet c !(updateLocs locs v) !(updateLocs locs t))
        updateLocsB (PVTy c t) = Just (PVTy c !(updateLocs locs t))

    updateLocs locs (App fc f a)
        = Just (App fc !(updateLocs locs f) !(updateLocs locs a))
    updateLocs locs tm = Just tm

    mkDef : (got : List Name) -> (vs : List Name) -> SnocList vs ->
            List (Var (vs ++ got)) -> Term (vs ++ got) ->
            Term ts -> Core (Term got)
    mkDef got [] Empty locs tm ty
        = do let Just tm' = updateLocs (reverse locs) tm
                    | Nothing => ufail loc ("Can't make solution for " ++ show mname)
             pure tm'
    mkDef got vs rec locs tm (Bind _ _ (Let _ _ _) sc)
        = mkDef got vs rec locs tm sc
    mkDef got (vs ++ [v]) (Snoc rec) locs tm (Bind bfc x (Pi c _ ty) sc)
        = do defs <- get Ctxt
             sc' <- mkDef (v :: got) vs rec
                       (rewrite appendAssociative vs [v] got in locs)
                       (rewrite appendAssociative vs [v] got in tm)
                       sc
             pure (Bind bfc v (Lam c Explicit (Erased bfc False)) sc')
    mkDef got (vs ++ [v]) (Snoc rec) locs tm ty
        = ufail loc $ "Can't make solution for " ++ show mname

export
solveIfUndefined : {vars : _} ->
                   {auto c : Ref Ctxt Defs} ->
                   {auto u : Ref UST UState} ->
                   Env Term vars -> Term vars -> Term vars -> Core Bool
solveIfUndefined env (Meta fc mname idx args) soln
    = do defs <- get Ctxt
         Just (Hole _ _) <- lookupDefExact (Resolved idx) (gamma defs)
              | pure False
         case !(patternEnvTm env args) of
              Nothing => pure False
              Just (newvars ** (locs, submv)) =>
                  case shrinkTerm soln submv of
                       Nothing => pure False
                       Just stm =>
                          do Just hdef <- lookupCtxtExact (Resolved idx) (gamma defs)
                                  | Nothing => throw (InternalError "Can't happen: no definition")
                             instantiate fc inTerm env mname idx (length args) hdef locs soln stm
                             pure True
solveIfUndefined env metavar soln
    = pure False

isDefInvertible : {auto c : Ref Ctxt Defs} ->
                  Int -> Core Bool
isDefInvertible i
    = do defs <- get Ctxt
         Just gdef <- lookupCtxtExact (Resolved i) (gamma defs)
              | Nothing => pure False
         pure (invertible gdef)

mutual
  unifyIfEq : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              {vars : _} ->
              (postpone : Bool) ->
              FC -> UnifyInfo -> Env Term vars -> NF vars -> NF vars ->
              Core UnifyResult
  unifyIfEq post loc mode env x y
        = do defs <- get Ctxt
             if !(convert defs env x y)
                then pure success
                else if post
                        then postpone True
                                      loc mode ("Postponing unifyIfEq " ++
                                                 show (atTop mode)) env x y
                        else convertError loc env x y

  getArgTypes : Defs -> (fnType : NF vars) -> List (Closure vars) ->
                Core (Maybe (List (NF vars)))
  getArgTypes defs (NBind _ n (Pi _ _ ty) sc) (a :: as)
     = do Just scTys <- getArgTypes defs !(sc defs a) as
               | Nothing => pure Nothing
          pure (Just (ty :: scTys))
  getArgTypes _ _ [] = pure (Just [])
  getArgTypes _ _ _ = pure Nothing

  headsConvert : {auto c : Ref Ctxt Defs} ->
                 Env Term vars ->
                 Maybe (List (NF vars)) -> Maybe (List (NF vars)) ->
                 Core Bool
  headsConvert env (Just vs) (Just ns)
      = case (reverse vs, reverse ns) of
             (v :: _, n :: _) =>
                do logNF 10 "Converting" env v
                   logNF 10 "......with" env n
                   defs <- get Ctxt
                   convert defs env v n
             _ => pure False
  headsConvert env _ _
      = do log 10 "Nothing to convert"
           pure True

  unifyInvertible : {auto c : Ref Ctxt Defs} ->
                    {auto u : Ref UST UState} ->
                    {vars : _} ->
                    (swaporder : Bool) ->
                    UnifyInfo -> FC -> Env Term vars ->
                    (metaname : Name) -> (metaref : Int) ->
                    (margs : List (Closure vars)) ->
                    (margs' : List (Closure vars)) ->
                    Maybe ClosedTerm ->
                    (List (Closure vars) -> NF vars) ->
                    List (Closure vars) ->
                    Core UnifyResult
  unifyInvertible swap mode fc env mname mref margs margs' nty con args'
      = do defs <- get Ctxt
           -- Get the types of the arguments to ensure that the rightmost
           -- argument types match up
           Just vty <- lookupTyExact (Resolved mref) (gamma defs)
                | Nothing => ufail fc ("No such metavariable " ++ show mname)
           vargTys <- getArgTypes defs !(nf defs env (embed vty)) (margs ++ margs')
           nargTys <- maybe (pure Nothing)
                            (\ty => getArgTypes defs !(nf defs env (embed ty)) args')
                            nty
           -- If the rightmost arguments have the same type, or we don't
           -- know the types of the arguments, we'll get on with it.
           if !(headsConvert env vargTys nargTys)
              then
                -- Unify the rightmost arguments, with the goal of turning the
                -- hole application into a pattern form
                case (reverse margs', reverse args') of
                     (h :: hargs, f :: fargs) =>
                        tryUnify
                          (if not swap then
                              do log 10 "Unifying invertible"
                                 ures <- unify mode fc env h f
                                 log 10 $ "Constraints " ++ show (constraints ures)
                                 uargs <- unify mode fc env
                                       (NApp fc (NMeta mname mref margs) (reverse hargs))
                                       (con (reverse fargs))
                                 pure (union ures uargs)
                             else
                              do log 10 "Unifying invertible"
                                 ures <- unify mode fc env f h
                                 log 10 $ "Constraints " ++ show (constraints ures)
                                 uargs <- unify mode fc env
                                       (con (reverse fargs))
                                       (NApp fc (NMeta mname mref margs) (reverse hargs))
                                 pure (union ures uargs))
                          (postponeS True swap fc mode "Postponing hole application [1]" env
                                (NApp fc (NMeta mname mref margs) margs')
                                (con args'))
                     _ => postponeS True swap fc mode "Postponing hole application [2]" env
                                (NApp fc (NMeta mname mref margs) margs')
                                (con args')
              else -- TODO: Cancellable function applications
                   postpone True fc mode "Postponing hole application [3]" env
                            (NApp fc (NMeta mname mref margs) margs') (con args')

  -- Unify a hole application - we have already checked that the hole is
  -- invertible (i.e. it's a determining argument to a proof search where
  -- it is a constructor or something else invertible in each case)
  unifyHoleApp : {auto c : Ref Ctxt Defs} ->
                 {auto u : Ref UST UState} ->
                 {vars : _} ->
                 (swaporder : Bool) ->
                 UnifyInfo -> FC -> Env Term vars ->
                 (metaname : Name) -> (metaref : Int) ->
                 (margs : List (Closure vars)) ->
                 (margs' : List (Closure vars)) ->
                 NF vars ->
                 Core UnifyResult
  unifyHoleApp swap mode loc env mname mref margs margs' (NTCon nfc n t a args')
      = do defs <- get Ctxt
           mty <- lookupTyExact n (gamma defs)
           unifyInvertible swap (lower mode) loc env mname mref margs margs' mty (NTCon nfc n t a) args'
  unifyHoleApp swap mode loc env mname mref margs margs' (NDCon nfc n t a args')
      = do defs <- get Ctxt
           mty <- lookupTyExact n (gamma defs)
           unifyInvertible swap (lower mode) loc env mname mref margs margs' mty (NTCon nfc n t a) args'
  unifyHoleApp swap mode loc env mname mref margs margs' (NApp nfc (NLocal r idx p) args')
      = unifyInvertible swap (lower mode) loc env mname mref margs margs' Nothing
                        (NApp nfc (NLocal r idx p)) args'
  unifyHoleApp swap mode loc env mname mref margs margs' tm@(NApp nfc (NMeta n i margs2) args2')
      = do defs <- get Ctxt
           Just mdef <- lookupCtxtExact (Resolved i) (gamma defs)
                | Nothing => throw (UndefinedName nfc mname)
           let inv = isPatName n || invertible mdef
           if inv
              then unifyInvertible swap (lower mode) loc env mname mref margs margs' Nothing
                                   (NApp nfc (NMeta n i margs2)) args2'
              else postponeS True swap loc mode "Postponing hole application" env
                             (NApp loc (NMeta mname mref margs) margs') tm
    where
      isPatName : Name -> Bool
      isPatName (PV _ _) = True
      isPatName _ = False

  unifyHoleApp swap mode loc env mname mref margs margs' tm
      = postponeS True swap loc mode "Postponing hole application" env
                 (NApp loc (NMeta mname mref margs) margs') tm

  postponePatVar : {auto c : Ref Ctxt Defs} ->
                   {auto u : Ref UST UState} ->
                   {vars : _} ->
                   (swaporder : Bool) ->
                   UnifyInfo -> FC -> Env Term vars ->
                   (metaname : Name) -> (metaref : Int) ->
                   (margs : List (Closure vars)) ->
                   (margs' : List (Closure vars)) ->
                   (soln : NF vars) ->
                   Core UnifyResult
  postponePatVar swap mode loc env mname mref margs margs' tm
      = do let x = NApp loc (NMeta mname mref margs) margs'
           defs <- get Ctxt
           if !(convert defs env x tm)
              then pure success
              else postponeS False -- it's not the metavar that's blocked
                             swap loc mode "Not in pattern fragment" env
                             x tm

  solveHole : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              {vars : _} ->
              FC -> UnifyInfo -> Env Term vars ->
              (metaname : Name) -> (metaref : Int) ->
              (margs : List (Closure vars)) ->
              (margs' : List (Closure vars)) ->
              List (Var newvars) ->
              SubVars newvars vars ->
              (solfull : Term vars) -> -- Original solution
              (soln : Term newvars) -> -- Solution with shrunk environment
              (solnf : NF vars) ->
              Core UnifyResult
  solveHole loc mode env mname mref margs margs' locs submv solfull stm solnf
      = do defs <- get Ctxt
           empty <- clearDefs defs
           -- if the terms are the same, this isn't a solution
           -- but they are already unifying, so just return
           if solutionHeadSame solnf
              then pure success
              else -- Rather than doing the occurs check here immediately,
                   -- we'll wait until all metavariables are resolved, and in
                   -- the meantime look out for cycles when normalising (which
                   -- is cheap enough because we only need to look out for
                   -- metavariables)
                   do Just hdef <- lookupCtxtExact (Resolved mref) (gamma defs)
                           | Nothing => throw (InternalError ("Can't happen: Lost hole " ++ show mname))
                      instantiate loc mode env mname mref (length margs) hdef locs solfull stm
                      pure $ solvedHole mref
    where
      -- Only need to check the head metavar is the same, we've already
      -- checked the rest if they are the same (and we couldn't instantiate it
      -- anyway...)
      solutionHeadSame : NF vars -> Bool
      solutionHeadSame (NApp _ (NMeta _ shead _) _) = shead == mref
      solutionHeadSame _ = False

  unifyHole : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              {vars : _} ->
              (swaporder : Bool) ->
              UnifyInfo -> FC -> Env Term vars ->
              FC -> (metaname : Name) -> (metaref : Int) ->
              (args : List (Closure vars)) ->
              (args' : List (Closure vars)) ->
              (soln : NF vars) ->
              Core UnifyResult
  unifyHole swap mode loc env fc mname mref margs margs' tmnf
      = do defs <- get Ctxt
           empty <- clearDefs defs
           let args = margs ++ margs'
           logC 10 (do args' <- traverse (evalArg empty) args
                       qargs <- traverse (quote empty env) args'
                       qtm <- quote empty env tmnf
                       pure $ "Unifying: " ++ show mname ++ " " ++ show qargs ++
                              " with " ++ show qtm) -- first attempt, try 'empty', only try 'defs' when on 'retry'?
           case !(patternEnv env args) of
                Nothing =>
                  do Just hdef <- lookupCtxtExact (Resolved mref) (gamma defs)
                        | _ => postponePatVar swap mode loc env mname mref margs margs' tmnf
                     let Hole _ _ = definition hdef
                        | _ => postponePatVar swap mode loc env mname mref margs margs' tmnf
                     if invertible hdef
                        then unifyHoleApp swap mode loc env mname mref margs margs' tmnf
                        else postponePatVar swap mode loc env mname mref margs margs' tmnf
                Just (newvars ** (locs, submv)) =>
                  do Just hdef <- lookupCtxtExact (Resolved mref) (gamma defs)
                         | _ => postponePatVar swap mode loc env mname mref margs margs' tmnf
                     let Hole _ _ = definition hdef
                         | _ => postponeS True swap loc mode "Delayed hole" env
                                          (NApp loc (NMeta mname mref margs) margs')
                                          tmnf
                     tm <- quote empty env tmnf
                     Just tm <- occursCheck loc env mode mname tm
                         | _ => postponeS True swap loc mode "Occurs check failed" env
                                          (NApp loc (NMeta mname mref margs) margs')
                                          tmnf

                     case shrinkTerm tm submv of
                          Just stm => solveHole fc mode env mname mref
                                                margs margs' locs submv
                                                tm stm tmnf
                          Nothing =>
                            do tm' <- normalise defs env tm
                               case shrinkTerm tm' submv of
                                    Nothing => postponeS True swap loc mode "Can't shrink" env
                                               (NApp loc (NMeta mname mref margs) margs')
                                               tmnf
                                    Just stm => solveHole fc mode env mname mref
                                                          margs margs' locs submv
                                                          tm stm tmnf

  -- Unify an application with something else
  unifyApp : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             {vars : _} ->
             (swaporder : Bool) -> -- swap the order when postponing
                                   -- (this is to preserve second arg being expected type)
             UnifyInfo -> FC -> Env Term vars -> FC ->
             NHead vars -> List (Closure vars) -> NF vars ->
             Core UnifyResult
  unifyApp swap mode loc env fc (NMeta n i margs) args tm
      = unifyHole swap mode loc env fc n i margs args tm
  unifyApp swap mode loc env fc hd args (NApp mfc (NMeta n i margs) margs')
      = unifyHole swap mode loc env mfc n i margs margs' (NApp fc hd args)
  -- Postpone if a name application against an application, unless they are
  -- convertible
  unifyApp swap mode loc env fc (NRef nt n) args tm
      = do log 10 $ "Name against app, unifyIfEq"
           if not swap
              then unifyIfEq True loc mode env (NApp fc (NRef nt n) args) tm
              else unifyIfEq True loc mode env tm (NApp fc (NRef nt n) args)
  unifyApp swap mode loc env xfc (NLocal rx x xp) [] (NApp yfc (NLocal ry y yp) [])
      = do gam <- get Ctxt
           if x == y then pure success
             else postponeS True swap loc mode "Postponing var"
                            env (NApp xfc (NLocal rx x xp) [])
                                (NApp yfc (NLocal ry y yp) [])
  -- A local against something canonical (binder or constructor) is bad
  unifyApp swap mode loc env xfc (NLocal rx x xp) args y@(NBind _ _ _ _)
      = convertErrorS swap loc env (NApp xfc (NLocal rx x xp) args) y
  unifyApp swap mode loc env xfc (NLocal rx x xp) args y@(NDCon _ _ _ _ _)
      = convertErrorS swap loc env (NApp xfc (NLocal rx x xp) args) y
  unifyApp swap mode loc env xfc (NLocal rx x xp) args y@(NTCon _ _ _ _ _)
      = convertErrorS swap loc env (NApp xfc (NLocal rx x xp) args) y
  unifyApp swap mode loc env xfc (NLocal rx x xp) args y@(NPrimVal _ _)
      = convertErrorS swap loc env (NApp xfc (NLocal rx x xp) args) y
  unifyApp swap mode loc env xfc (NLocal rx x xp) args y@(NType _)
      = convertErrorS swap loc env (NApp xfc (NLocal rx x xp) args) y
  -- If they're already convertible without metavariables, we're done,
  -- otherwise postpone
  unifyApp False mode loc env fc hd args tm
      = do gam <- get Ctxt
           if !(convert gam env (NApp fc hd args) tm)
              then pure success
              else postponeS True False loc mode "Postponing constraint"
                             env (NApp fc hd args) tm
  unifyApp True mode loc env fc hd args tm
      = do gam <- get Ctxt
           if !(convert gam env tm (NApp fc hd args))
              then pure success
              else postponeS True True loc mode "Postponing constraint"
                             env (NApp fc hd args) tm

  unifyBothApps : {auto c : Ref Ctxt Defs} ->
                  {auto u : Ref UST UState} ->
                  {vars : _} ->
                  UnifyInfo -> FC -> Env Term vars ->
                  FC -> NHead vars -> List (Closure vars) ->
                  FC -> NHead vars -> List (Closure vars) ->
                  Core UnifyResult
  unifyBothApps mode loc env xfc (NLocal xr x xp) [] yfc (NLocal yr y yp) []
      = if x == y
           then pure success
           else convertError loc env (NApp xfc (NLocal xr x xp) [])
                                     (NApp yfc (NLocal yr y yp) [])
  -- Locally bound things, in a term (not LHS). Since we have to unify
  -- for *all* possible values, we can safely unify the arguments.
  unifyBothApps mode@(MkUnifyInfo p t InTerm) loc env xfc (NLocal xr x xp) xargs yfc (NLocal yr y yp) yargs
      = if x == y
           then unifyArgs mode loc env xargs yargs
           else postpone True loc mode "Postponing local app"
                         env (NApp xfc (NLocal xr x xp) xargs)
                             (NApp yfc (NLocal yr y yp) yargs)
  unifyBothApps mode loc env xfc (NLocal xr x xp) xargs yfc (NLocal yr y yp) yargs
      = do log 10 $ "Both local apps, unifyIfEq"
           unifyIfEq True loc mode env (NApp xfc (NLocal xr x xp) xargs)
                                       (NApp yfc (NLocal yr y yp) yargs)
  -- If they're both holes, solve the one with the bigger context
  unifyBothApps mode loc env xfc (NMeta xn xi xargs) xargs' yfc (NMeta yn yi yargs) yargs'
      = do invx <- isDefInvertible xi
           if xi == yi && (invx || umode mode == InSearch)
                               -- Invertible, (from auto implicit search)
                               -- so we can also unify the arguments.
              then unifyArgs mode loc env (xargs ++ xargs')
                                          (yargs ++ yargs')
              else do xlocs <- localsIn xargs
                      ylocs <- localsIn yargs
                      -- Solve the one with the bigger context, and if they're
                      -- equal, the one that's applied to fewest things (because
                      -- then they arguments get substituted in)
                      let xbigger = xlocs > ylocs
                                      || (xlocs == ylocs &&
                                           length xargs' <= length yargs')
                      if (xbigger || umode mode == InMatch) && not (pv xn)
                        then unifyApp False mode loc env xfc (NMeta xn xi xargs) xargs'
                                            (NApp yfc (NMeta yn yi yargs) yargs')
                        else unifyApp True mode loc env yfc (NMeta yn yi yargs) yargs'
                                           (NApp xfc (NMeta xn xi xargs) xargs')
    where
      pv : Name -> Bool
      pv (PV _ _) = True
      pv _ = False

      localsIn : List (Closure vars) -> Core Nat
      localsIn [] = pure 0
      localsIn (c :: cs)
          = do defs <- get Ctxt
               case !(evalClosure defs c) of
                 NApp _ (NLocal _ _ _) _ => pure $ S !(localsIn cs)
                 _ => localsIn cs

  unifyBothApps mode loc env xfc (NMeta xn xi xargs) xargs' yfc fy yargs'
      = unifyApp False mode loc env xfc (NMeta xn xi xargs) xargs'
                                        (NApp yfc fy yargs')
  unifyBothApps mode loc env xfc fx xargs' yfc (NMeta yn yi yargs) yargs'
      = if umode mode /= InMatch
           then unifyApp True mode loc env xfc (NMeta yn yi yargs) yargs'
                                               (NApp xfc fx xargs')
           else unifyApp False mode loc env xfc fx xargs'
                                        (NApp yfc (NMeta yn yi yargs) yargs')
  unifyBothApps mode@(MkUnifyInfo p t InSearch) loc env xfc fx@(NRef xt hdx) xargs yfc fy@(NRef yt hdy) yargs
      = if hdx == hdy
           then unifyArgs mode loc env xargs yargs
           else unifyApp False mode loc env xfc fx xargs (NApp yfc fy yargs)
  unifyBothApps mode@(MkUnifyInfo p t InMatch) loc env xfc fx@(NRef xt hdx) xargs yfc fy@(NRef yt hdy) yargs
      = if hdx == hdy
           then do logC 5 (do defs <- get Ctxt
                              xs <- traverse (quote defs env) xargs
                              ys <- traverse (quote defs env) yargs
                              pure ("Matching args " ++ show xs ++ " " ++ show ys))
                   unifyArgs mode loc env xargs yargs
           else unifyApp False mode loc env xfc fx xargs (NApp yfc fy yargs)
  unifyBothApps mode loc env xfc fx ax yfc fy ay
      = unifyApp False mode loc env xfc fx ax (NApp yfc fy ay)

  -- Comparing multiplicities when converting pi binders
  subRig : RigCount -> RigCount -> Bool
  subRig x y = (isLinear x && isRigOther y) || -- we can pass a linear function if a general one is expected
               x == y -- otherwise, the multiplicities need to match up

  unifyBothBinders: {auto c : Ref Ctxt Defs} ->
                    {auto u : Ref UST UState} ->
                    {vars : _} ->
                    UnifyInfo -> FC -> Env Term vars ->
                    FC -> Name -> Binder (NF vars) ->
                    (Defs -> Closure vars -> Core (NF vars)) ->
                    FC -> Name -> Binder (NF vars) ->
                    (Defs -> Closure vars -> Core (NF vars)) ->
                    Core UnifyResult
  unifyBothBinders mode loc env xfc x (Pi cx ix tx) scx yfc y (Pi cy iy ty) scy
      = do defs <- get Ctxt
           if not (subRig cx cy)
             then convertError loc env
                    (NBind xfc x (Pi cx ix tx) scx)
                    (NBind yfc y (Pi cy iy ty) scy)
             else
               do empty <- clearDefs defs
                  tx' <- quote empty env tx
                  logC 10 $ (do ty' <- quote empty env ty
                                pure ("Unifying arg types " ++ show tx' ++ " and " ++ show ty'))
                  ct <- unify (lower mode) loc env tx ty
                  xn <- genVarName "x"
                  let env' : Env Term (x :: _)
                           = Pi cy Explicit tx' :: env
                  case constraints ct of
                      [] => -- No constraints, check the scope
                         do tscx <- scx defs (toClosure defaultOpts env (Ref loc Bound xn))
                            tscy <- scy defs (toClosure defaultOpts env (Ref loc Bound xn))
                            tmx <- quote empty env tscx
                            tmy <- quote empty env tscy
                            unify (lower mode) loc env' (refsToLocals (Add x xn None) tmx)
                                                (refsToLocals (Add x xn None) tmy)
                      cs => -- Constraints, make new guarded constant
                         do txtm <- quote empty env tx
                            tytm <- quote empty env ty
                            c <- newConstant loc erased env
                                   (Bind xfc x (Lam cy Explicit txtm) (Local xfc Nothing _ First))
                                   (Bind xfc x (Pi cy Explicit txtm)
                                       (weaken tytm)) cs
                            tscx <- scx defs (toClosure defaultOpts env (Ref loc Bound xn))
                            tscy <- scy defs (toClosure defaultOpts env (App loc c (Ref loc Bound xn)))
                            tmx <- quote empty env tscx
                            tmy <- quote empty env tscy
                            cs' <- unify (lower mode) loc env' (refsToLocals (Add x xn None) tmx)
                                                       (refsToLocals (Add x xn None) tmy)
                            pure (union ct cs')
  unifyBothBinders mode loc env xfc x (Lam cx ix tx) scx yfc y (Lam cy iy ty) scy
      = do defs <- get Ctxt
           if not (subRig cx cy)
             then convertError loc env
                    (NBind xfc x (Lam cx ix tx) scx)
                    (NBind yfc y (Lam cy iy ty) scy)
             else
               do empty <- clearDefs defs
                  tx' <- quote empty env tx
                  ct <- unify (lower mode) loc env tx ty
                  xn <- genVarName "x"
                  let env' : Env Term (x :: _)
                           = Lam cx Explicit tx' :: env
                  txtm <- quote empty env tx
                  tytm <- quote empty env ty

                  tscx <- scx defs (toClosure defaultOpts env (Ref loc Bound xn))
                  tscy <- scy defs (toClosure defaultOpts env (Ref loc Bound xn))
                  tmx <- quote empty env tscx
                  tmy <- quote empty env tscy
                  cs' <- unify (lower (lam mode)) loc env' (refsToLocals (Add x xn None) tmx)
                                                   (refsToLocals (Add x xn None) tmy)
                  pure (union ct cs')

  unifyBothBinders mode loc env xfc x bx scx yfc y by scy
      = convertError loc env
                  (NBind xfc x bx scx)
                  (NBind yfc y by scy)

  dumpArg : {auto c : Ref Ctxt Defs} ->
            Env Term vars -> Closure vars -> Core ()
  dumpArg env (MkClosure opts loc lenv tm)
      = do defs <- get Ctxt
           empty <- clearDefs defs
           logTerm 0 "Term: " tm
           nf <- evalClosure empty (MkClosure opts loc lenv tm)
           logNF 0 "  " env nf
  dumpArg env cl
      = do defs <- get Ctxt
           empty <- clearDefs defs
           nf <- evalClosure empty cl
           logNF 0 "  " env nf

  export
  unifyNoEta : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               {vars : _} ->
               UnifyInfo -> FC -> Env Term vars ->
               NF vars -> NF vars ->
               Core UnifyResult
  unifyNoEta mode loc env (NDCon xfc x tagx ax xs) (NDCon yfc y tagy ay ys)
      = do gam <- get Ctxt
           if tagx == tagy
             then
                  do ust <- get UST
                     -- Constantly checking the log setting appears to have
                     -- a bit of overhead, but I'm keeping this here because it
                     -- may prove useful again...
                     {-
                     when (logging ust) $
                        do log 0 $ "Constructor " ++ show !(toFullNames x) ++ " " ++ show loc
                           log 0 "ARGUMENTS:"
                           defs <- get Ctxt
                           traverse_ (dumpArg env) xs
                           log 0 "WITH:"
                           traverse_ (dumpArg env) ys
                     -}
                     unifyArgs mode loc env xs ys
             else convertError loc env
                       (NDCon xfc x tagx ax xs)
                       (NDCon yfc y tagy ay ys)
  unifyNoEta mode loc env (NTCon xfc x tagx ax xs) (NTCon yfc y tagy ay ys)
      = if x == y
           then do ust <- get UST
                   -- see above
                   {-
                   when (logging ust) $
                      do log 0 $ "Constructor " ++ show !(toFullNames x) ++ " " ++ show loc
                         log 0 "ARGUMENTS:"
                         defs <- get Ctxt
                         traverse_ (dumpArg env) xs
                         log 0 "WITH:"
                         traverse_ (dumpArg env) ys
                   -}
                   unifyArgs mode loc env xs ys
             -- TODO: Type constructors are not necessarily injective.
             -- If we don't know it's injective, need to postpone the
             -- constraint. But before then, we need some way to decide
             -- what's injective...
--                then postpone True loc mode env (quote empty env (NTCon x tagx ax xs))
--                                           (quote empty env (NTCon y tagy ay ys))
           else convertError loc env
                     (NTCon xfc x tagx ax xs)
                     (NTCon yfc y tagy ay ys)
  unifyNoEta mode loc env (NDelayed xfc _ x) (NDelayed yfc _ y)
      = unify (lower mode) loc env x y
  unifyNoEta mode loc env (NDelay xfc _ xty x) (NDelay yfc _ yty y)
      = unifyArgs mode loc env [xty, x] [yty, y]
  unifyNoEta mode loc env (NForce xfc _ x axs) (NForce yfc _ y ays)
      = do cs <- unify (lower mode) loc env x y
           cs' <- unifyArgs mode loc env axs ays
           pure (union cs cs')
  unifyNoEta mode loc env (NApp xfc fx axs) (NApp yfc fy ays)
      = unifyBothApps (lower mode) loc env xfc fx axs yfc fy ays
  unifyNoEta mode loc env (NApp xfc hd args) y
      = unifyApp False (lower mode) loc env xfc hd args y
  unifyNoEta mode loc env y (NApp yfc hd args)
      = if umode mode /= InMatch
           then unifyApp True mode loc env yfc hd args y
           else do log 10 $ "Unify if Eq due to something with app"
                   unifyIfEq True loc mode env y (NApp yfc hd args)
  -- Only try stripping as patterns as a last resort
  unifyNoEta mode loc env x (NAs _ _ _ y) = unifyNoEta mode loc env x y
  unifyNoEta mode loc env (NAs _ _ _ x) y = unifyNoEta mode loc env x y
  unifyNoEta mode loc env x y
      = do defs <- get Ctxt
           empty <- clearDefs defs
           log 10 $ "Nothing else worked, unifyIfEq"
           unifyIfEq (isDelay x || isDelay y) loc mode env x y
    where
      -- If one of them is a delay, and they're not equal, we'd better
      -- postpone and come back to it so we can insert the implicit
      -- Force/Delay later
      isDelay : NF vars -> Bool
      isDelay (NDelayed _ _ _) = True
      isDelay _ = False

  -- Try to get the type of the application inside the given term, to use in
  -- eta expansion. If there's no application, return Nothing
  getEtaType : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               Env Term vars -> Term vars ->
               Core (Maybe (Term vars))
  getEtaType env (Bind fc n b sc)
      = do Just ty <- getEtaType (b :: env) sc
               | Nothing => pure Nothing
           pure (shrinkTerm ty (DropCons SubRefl))
  getEtaType env (App fc f _)
      = do fty <- getType env f
           logGlue 10 "Function type" env fty
           case !(getNF fty) of
                NBind _ _ (Pi _ _ ty) sc =>
                    do defs <- get Ctxt
                       empty <- clearDefs defs
                       pure (Just !(quote empty env ty))
                _ => pure Nothing
  getEtaType env _ = pure Nothing

  isHoleApp : NF vars -> Bool
  isHoleApp (NApp _ (NMeta _ _ _) _) = True
  isHoleApp _ = False

  export
  Unify NF where
    unifyD _ _ mode loc env (NBind xfc x bx scx) (NBind yfc y by scy)
        = unifyBothBinders mode loc env xfc x bx scx yfc y by scy
    unifyD _ _ mode loc env tmx@(NBind xfc x (Lam cx ix tx) scx) tmy
        = do defs <- get Ctxt
             logNF 10 "EtaR" env tmx
             logNF 10 "...with" env tmy
             if isHoleApp tmy
                then unifyNoEta (lower mode) loc env tmx tmy
                else do empty <- clearDefs defs
                        ety <- getEtaType env !(quote empty env tmx)
                        case ety of
                             Just argty =>
                               do etay <- nf defs env
                                             (Bind xfc x (Lam cx Explicit argty)
                                                     (App xfc
                                                          (weaken !(quote empty env tmy))
                                                          (Local xfc Nothing 0 First)))
                                  logNF 10 "Expand" env etay
                                  unify mode loc env tmx etay
                             _ => unifyNoEta mode loc env tmx tmy
    unifyD _ _ mode loc env tmx tmy@(NBind yfc y (Lam cy iy ty) scy)
        = do defs <- get Ctxt
             logNF 10 "EtaL" env tmx
             logNF 10 "...with" env tmy
             if isHoleApp tmx
                then unifyNoEta (lower mode) loc env tmx tmy
                else do empty <- clearDefs defs
                        ety <- getEtaType env !(quote empty env tmy)
                        case ety of
                             Just argty =>
                               do etax <- nf defs env
                                             (Bind yfc y (Lam cy Explicit argty)
                                                     (App yfc
                                                          (weaken !(quote empty env tmx))
                                                          (Local yfc Nothing 0 First)))
                                  logNF 10 "Expand" env etax
                                  unify (lower mode) loc env etax tmy
                             _ => unifyNoEta (lower mode) loc env tmx tmy
    unifyD _ _ mode loc env tmx tmy = unifyNoEta mode loc env tmx tmy

    unifyWithLazyD _ _ mode loc env (NDelayed _ _ tmx) (NDelayed _ _ tmy)
       = unify (lower mode) loc env tmx tmy
    unifyWithLazyD _ _ mode loc env (NDelayed _ r tmx) tmy
       = do vs <- unify (lower mode) loc env tmx tmy
            pure (record { addLazy = AddForce r } vs)
    unifyWithLazyD _ _ mode loc env tmx (NDelayed _ r tmy)
       = do vs <- unify (lower mode) loc env tmx tmy
            pure (record { addLazy = AddDelay r } vs)
    unifyWithLazyD _ _ mode loc env tmx tmy
       = unify mode loc env tmx tmy

  export
  Unify Term where
    unifyD _ _ mode loc env x y
          = do defs <- get Ctxt
               empty <- clearDefs defs
               if !(convert empty env x y)
                  then do log 10 $ "Skipped unification (equal already): "
                                 ++ show x ++ " and " ++ show y
                          pure success
                  else do xnf <- nf defs env x
                          ynf <- nf defs env y
                          unify mode loc env xnf ynf
    unifyWithLazyD _ _ mode loc env x y
          = do defs <- get Ctxt
               empty <- clearDefs defs
               if !(convert empty env x y)
                  then do log 10 $ "Skipped unification (equal already): "
                                 ++ show x ++ " and " ++ show y
                          pure success
                  else do xnf <- nf defs env x
                          ynf <- nf defs env y
                          unifyWithLazy mode loc env xnf ynf

  export
  Unify Closure where
    unifyD _ _ mode loc env x y
        = do defs <- get Ctxt
             empty <- clearDefs defs
             if !(convert empty env x y)
                then pure success
                else do xnf <- evalClosure defs x
                        ynf <- evalClosure defs y
                        unify mode loc env xnf ynf

export
setInvertible : {auto c : Ref Ctxt Defs} ->
                FC -> Name -> Core ()
setInvertible fc n
    = do defs <- get Ctxt
         Just gdef <- lookupCtxtExact n (gamma defs)
              | Nothing => throw (UndefinedName fc n)
         addDef n (record { invertible = True } gdef)
         pure ()

public export
data SolveMode = Normal -- during elaboration: unifies and searches
               | Defaults -- unifies and searches for default hints only
               | MatchArgs -- match rather than unify
               | LastChance -- as normal, but any failure throws rather than delays

Eq SolveMode where
  Normal == Normal = True
  Defaults == Defaults = True
  LastChance == LastChance = True
  _ == _ = False

retry : {auto c : Ref Ctxt Defs} ->
        {auto u : Ref UST UState} ->
        UnifyInfo -> Int -> Core UnifyResult
retry mode c
    = do ust <- get UST
         case lookup c (constraints ust) of
              Nothing => pure success
              Just Resolved => pure success
              Just (MkConstraint loc withLazy blocked env x y)
                => if umode mode /= InTerm ||
                         !(anyM definedN blocked) || isNil blocked
                      -- only go if any of the blocked names are defined now
                      then
                        catch
                           (do logTermNF 5 ("Retrying " ++ show c ++ " " ++ show (umode mode)) env x
                               logTermNF 5 "....with" env y
                               log 5 $ if withLazy
                                          then "(lazy allowed)"
                                          else "(no lazy)"
                               cs <- if withLazy
                                        then unifyWithLazy mode loc env x y
                                        else unify (lower mode) loc env x y
                               case constraints cs of
                                 [] => do log 5 $ "Success " ++ show (addLazy cs)
                                          deleteConstraint c
                                          pure cs
                                 _ => do log 5 $ "Constraints " ++ show (addLazy cs)
                                         pure cs)
                          (\err => throw (WhenUnifying loc env x y err))
                      else
                        do log 10 $ show c ++ " still blocked on " ++ show blocked
                           logTermNF 10 "X" env x
                           logTermNF 10 "Y" env y
                           pure (constrain c)
              Just (MkSeqConstraint loc env xs ys)
                  => do cs <- unifyArgs mode loc env xs ys
                        case constraints cs of
                             [] => do deleteConstraint c
                                      pure cs
                             _ => pure cs
  where
    definedN : Name -> Core Bool
    definedN n
        = do defs <- get Ctxt
             Just gdef <- lookupCtxtExact n (gamma defs)
                  | _ => pure False
             case definition gdef of
                  Hole _ _ => pure (invertible gdef)
                  BySearch _ _ _ => pure False
                  Guess _ _ _ => pure False
                  _ => pure True

delayMeta : LazyReason -> Nat -> Term vars -> Term vars -> Term vars
delayMeta r (S k) ty (Bind fc n b sc)
    = Bind fc n b (delayMeta r k (weaken ty) sc)
delayMeta r envb ty tm = TDelay (getLoc tm) r ty tm

forceMeta : LazyReason -> Nat -> Term vars -> Term vars
forceMeta r (S k) (Bind fc n b sc)
    = Bind fc n b (forceMeta r k sc)
forceMeta r envb tm = TForce (getLoc tm) r tm

-- Retry the given constraint, return True if progress was made
retryGuess : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST UState} ->
             UnifyInfo -> (smode : SolveMode) -> (hole : (Int, (FC, Name))) ->
             Core Bool
retryGuess mode smode (hid, (loc, hname))
    = do defs <- get Ctxt
         case !(lookupCtxtExact (Resolved hid) (gamma defs)) of
           Nothing => pure False
           Just def =>
             case definition def of
               BySearch rig depth defining =>
                  handleUnify
                     (do tm <- search loc rig (smode == Defaults) depth defining
                                      (type def) []
                         let gdef = record { definition = PMDef defaultPI [] (STerm tm) (STerm tm) [] } def
                         logTermNF 5 ("Solved " ++ show hname) [] tm
                         addDef (Resolved hid) gdef
                         removeGuess hid
                         pure True)
                     (\err => case err of
                                DeterminingArg _ n i _ _ =>
                                    do logTerm 5 ("Failed (det " ++ show hname ++ " " ++ show n ++ ")")
                                                 (type def)
                                       setInvertible loc (Resolved i)
                                       pure False -- progress made!
                                _ => do logTermNF 5 ("Search failed at " ++ show rig ++ " for " ++ show hname)
                                                  [] (type def)
                                        case smode of
                                             LastChance =>
                                                 throw !(normaliseErr err)
                                             _ => pure False) -- Postpone again
               Guess tm envb [constr] =>
                 do let umode = case smode of
                                     MatchArgs => inMatch
                                     _ => mode
                    cs <- retry umode constr
                    case constraints cs of
                         [] => do tm' <- case addLazy cs of
                                           NoLazy => pure tm
                                           AddForce r => pure $ forceMeta r envb tm
                                           AddDelay r =>
                                              do ty <- getType [] tm
                                                 logTerm 5 "Retry Delay" tm
                                                 pure $ delayMeta r envb !(getTerm ty) tm
                                  let gdef = record { definition = PMDef (MkPMDefInfo NotHole True)
                                                                         [] (STerm tm') (STerm tm') [] } def
                                  logTerm 5 ("Resolved " ++ show hname) tm'
                                  addDef (Resolved hid) gdef
                                  removeGuess hid
                                  pure (holesSolved cs)
                         newcs => do tm' <- case addLazy cs of
                                           NoLazy => pure tm
                                           AddForce r => pure $ forceMeta r envb tm
                                           AddDelay r =>
                                              do ty <- getType [] tm
                                                 logTerm 5 "Retry Delay (constrained)" tm
                                                 pure $ delayMeta r envb !(getTerm ty) tm
                                     let gdef = record { definition = Guess tm' envb newcs } def
                                     addDef (Resolved hid) gdef
                                     pure False
               Guess tm envb constrs =>
                 do let umode = case smode of
                                     MatchArgs => inMatch
                                     _ => mode
                    cs' <- traverse (retry umode) constrs
                    let csAll = unionAll cs'
                    case constraints csAll of
                         -- All constraints resolved, so turn into a
                         -- proper definition and remove it from the
                         -- hole list
                         [] => do let gdef = record { definition = PMDef (MkPMDefInfo NotHole True)
                                                                         [] (STerm tm) (STerm tm) [] } def
                                  logTerm 5 ("Resolved " ++ show hname) tm
                                  addDef (Resolved hid) gdef
                                  removeGuess hid
                                  pure (holesSolved csAll)
                         newcs => do let gdef = record { definition = Guess tm envb newcs } def
                                     addDef (Resolved hid) gdef
                                     pure False
               _ => pure False

export
solveConstraints : {auto c : Ref Ctxt Defs} ->
                   {auto u : Ref UST UState} ->
                   UnifyInfo -> (smode : SolveMode) -> Core ()
solveConstraints umode smode
    = do ust <- get UST
         progress <- traverse (retryGuess umode smode) (toList (guesses ust))
         when (or (map Delay progress)) $
               solveConstraints umode Normal

export
solveConstraintsAfter : {auto c : Ref Ctxt Defs} ->
                        {auto u : Ref UST UState} ->
                        Int -> UnifyInfo -> (smode : SolveMode) -> Core ()
solveConstraintsAfter start umode smode
    = do ust <- get UST
         progress <- traverse (retryGuess umode smode)
                              (filter afterStart (toList (guesses ust)))
         when (or (map Delay progress)) $
               solveConstraintsAfter start umode Normal
  where
    afterStart : (Int, a) -> Bool
    afterStart (x, _) = x >= start

-- Replace any 'BySearch' with 'Hole', so that we don't keep searching
-- fruitlessly while elaborating the rest of a source file
export
giveUpConstraints : {auto c : Ref Ctxt Defs} ->
                    {auto u : Ref UST UState} ->
                    Core ()
giveUpConstraints
    = do ust <- get UST
         traverse_ constraintToHole (toList (guesses ust))
  where
    constraintToHole : (Int, (FC, Name)) -> Core ()
    constraintToHole (hid, (_, _))
        = do defs <- get Ctxt
             case !(lookupDefExact (Resolved hid) (gamma defs)) of
                  Just (BySearch _ _ _) =>
                         updateDef (Resolved hid) (const (Just (Hole 0 False)))
                  Just (Guess _ _ _) =>
                         updateDef (Resolved hid) (const (Just (Hole 0 False)))
                  _ => pure ()

-- Check whether any of the given hole references have the same solution
-- (up to conversion)
export
checkArgsSame : {auto u : Ref UST UState} ->
                {auto c : Ref Ctxt Defs} ->
                List Int -> Core Bool
checkArgsSame [] = pure False
checkArgsSame (x :: xs)
    = do defs <- get Ctxt
         Just (PMDef _ [] (STerm def) _ _) <-
                    lookupDefExact (Resolved x) (gamma defs)
              | _ => checkArgsSame xs
         s <- anySame def xs
         if s
            then pure True
            else checkArgsSame xs
  where
    anySame : Term [] -> List Int -> Core Bool
    anySame tm [] = pure False
    anySame tm (t :: ts)
        = do defs <- get Ctxt
             Just (PMDef _ [] (STerm def) _ _) <-
                        lookupDefExact (Resolved t) (gamma defs)
                 | _ => anySame tm ts
             if !(convert defs [] tm def)
                then pure True
                else anySame tm ts

export
checkDots : {auto u : Ref UST UState} ->
            {auto c : Ref Ctxt Defs} ->
            Core ()
checkDots
    = do ust <- get UST
         hs <- getCurrentHoles
         traverse_ checkConstraint (reverse (dotConstraints ust))
         hs <- getCurrentHoles
         ust <- get UST
         put UST (record { dotConstraints = [] } ust)
  where
    checkConstraint : (Name, DotReason, Constraint) -> Core ()
    checkConstraint (n, reason, MkConstraint fc wl blocked env x y)
        = do logTermNF 10 "Dot" env y
             logTermNF 10 "  =" env x
             -- A dot is okay if the constraint is solvable *without solving
             -- any additional holes*
             ust <- get UST
             handleUnify
               (do defs <- get Ctxt
                   Just olddef <- lookupDefExact n (gamma defs)
                        | Nothing => throw (UndefinedName fc n)

                   -- Check that what was given (x) matches what was
                   -- solved by unification (y).
                   -- In 'InMatch' mode, only metavariables in 'x' can
                   -- be solved, so everything in the dotted metavariable
                   -- must be complete.
                   cs <- unify inMatch fc env x y
                   defs <- get Ctxt
                   Just ndef <- lookupDefExact n (gamma defs)
                        | Nothing => throw (UndefinedName fc n)

                   -- If the name standing for the dot wasn't solved
                   -- earlier, but is now (even with another metavariable)
                   -- this is bad (it most likely means there's a non-linear
                   -- variable)
                   let hBefore = case olddef of
                                      Hole _ _ => True -- dot not solved
                                      _ => False
                   let h = case ndef of
                                Hole _ _ => True -- dot not solved
                                _ => False

                   -- If any of the things we solved have the same definition,
                   -- we've sneaked a non-linear pattern variable in
                   argsSame <- checkArgsSame (namesSolved cs)
                   when (not (isNil (constraints cs))
                            || (hBefore && not h) || argsSame) $
                      throw (InternalError "Dot pattern match fail"))
               (\err =>
                    case err of
                         InternalError _ =>
                           do defs <- get Ctxt
                              Just dty <- lookupTyExact n (gamma defs)
                                   | Nothing => throw (UndefinedName fc n)
                              logTermNF 5 "Dot type" [] dty
                              -- Clear constraints so we don't report again
                              -- later
                              put UST (record { dotConstraints = [] } ust)
                              throw (BadDotPattern fc env reason
                                      !(normaliseHoles defs env x)
                                      !(normaliseHoles defs env y))
                         _ => do put UST (record { dotConstraints = [] } ust)
                                 throw err)
    checkConstraint _ = pure ()
