{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Compile where

import Data.List
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Short as BSS
import Control.Monad
import Control.Monad.State
import Control.Monad.IO.Class
import Control.Monad.Fail hiding (fail)
import Control.Monad.Except hiding (void, fail)
import Foreign.Ptr

import LLVM.AST.Name
import qualified LLVM.AST as LL
import qualified LLVM.AST.Type as LL
import qualified LLVM.AST.Constant as C
import qualified LLVM.Internal.FFI.DataLayout as FFI
import LLVM.AST.Global
import LLVM.IRBuilder.Instruction       
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Module
import LLVM.IRBuilder.Monad
import LLVM.Context

import qualified AST as S
import qualified Flatten as F
import Monad
import Type
import Error
import Value
import State
import Print
import Funcs
import Table
import Tuple
import ADT

compileFlatState
    :: BoM s m
    => Context
    -> Ptr FFI.DataLayout
    -> Map.Map S.Path CompileState
    -> F.FlattenState
    -> S.Symbol
    -> m ([LL.Definition], CompileState)
compileFlatState ctx dl imports flatState modName = do
    res <- runBoMT (initCompileState ctx dl imports modName) (runModuleCmpT emptyModuleBuilder cmp)
    case res of
        Left err                 -> throwError err
        Right ((_, defs), state) -> return (defs, state)
    where
        cmp :: (MonadFail m, Monad m, MonadIO m) => ModuleCmpT CompileState m ()
        cmp = void $ func "main" [] LL.VoidType $ \_ -> do
                forM_ (Map.toList $ F.typeDefs flatState) $ \(flat, (pos, typ)) ->
                    cmpTypeDef (S.Typedef pos flat typ)
                mapM_ cmpFuncHdr (F.funcDefs flatState)
                mapM_ cmpExternDef (F.externDefs flatState)
                mapM_ cmpVarDef (F.varDefs flatState)
                mapM_ cmpFuncDef (F.funcDefs flatState)


cmpTypeDef :: InsCmp CompileState m => S.Stmt -> m ()
cmpTypeDef (S.Typedef pos sym typ)
    | isADT typ = withPos pos $ adtTypeDef sym typ
cmpTypeDef (S.Typedef pos sym typ) = withPos pos $ do
    let typdef = Typedef sym

    -- Add zero, base and def constructors
    forM_ [KeyFunc [], KeyFunc [typ], KeyFunc [typdef]] $ \key -> do
        checkSymKeyUndef sym key
        addObj sym key (ObjConstructor typdef)

    -- use named type
    if isTuple typ || isTable typ
    then do
        name <- myFresh sym
        addSymKeyDec sym KeyType name . DecType =<< opTypeOf typ
        checkSymKeyUndef sym KeyType
        addObj sym KeyType $ ObType typ (Just name)
    else do
        checkSymKeyUndef sym KeyType
        addObj sym KeyType $ ObType typ Nothing

    if isTuple typ
    then do
        let Tuple xs = typ
        let ts = map snd xs
        if length ts > 0
        then do
            checkSymKeyUndef sym (KeyFunc ts)
            addObj sym (KeyFunc ts) (ObjConstructor typdef)
        else return ()
    else return ()



cmpVarDef :: InsCmp CompileState m => S.Stmt -> m ()
cmpVarDef (S.Assign pos (S.PatIdent p sym) expr) = do
    val <- cmpExpr expr

    checkSymKeyUndef sym KeyVar
    name <- myFresh sym

    assert (not $ valIsContextual val) "contextual 124"
    let typ = valType val
    opTyp <- opTypeOf typ

    if isCons (valOp val)
    then do
        loc <- Ptr typ <$> global name opTyp (toCons $ valOp val)
        addObj sym KeyVar (ObjVal loc)
    else do
        initialiser <- zeroOf typ
        loc <- Ptr typ <$> global name opTyp (toCons $ valOp initialiser)
        valStore loc val
        addObj sym KeyVar (ObjVal loc)

    addSymKeyDec sym KeyVar name (DecVar opTyp)
    addDeclared name


cmpExternDef :: InsCmp CompileState m => S.Stmt -> m ()
cmpExternDef (S.Extern pos sym params retty) = do
    checkSymUndef sym 
    let name = LL.mkName sym
    let paramTypes = map S.paramType params

    pushSymTab
    paramOpTypes <- forM params $ \(S.Param p s t) -> do
        checkSymKeyUndef s KeyVar
        addObj s KeyVar $ ObjVal (valBool False)
        opTypeOf t

    returnOpType <- opTypeOf retty
    popSymTab

    addSymKeyDec sym (KeyFunc paramTypes) name (DecExtern paramOpTypes returnOpType False)
    let op = fnOp name paramOpTypes returnOpType False
    addObj sym (KeyFunc paramTypes) (ObjExtern paramTypes retty op)


cmpFuncHdr :: InsCmp CompileState m => S.Stmt -> m ()
cmpFuncHdr (S.Func pos "main" params retty blk) = return ()
cmpFuncHdr (S.Func pos sym params retty blk)    = withPos pos $ do
    let key = KeyFunc (map S.paramType params)
    checkSymKeyUndef sym key
    name <- myFresh sym

    paramOpTypes <- mapM (opTypeOf . S.paramType) params
    returnOpType <- opTypeOf retty
    let op = fnOp name paramOpTypes returnOpType False
    addObj sym key (ObjFunc retty op) 
    

cmpFuncDef :: (MonadFail m, Monad m, MonadIO m) => S.Stmt -> InstrCmpT CompileState m ()
cmpFuncDef (S.Func pos "main" params retty blk) = withPos pos $ do
    assert (params == [])  "main cannot have parameters"
    assert (retty == Void) "main must return void"
    pushSymTab >> mapM_ cmpStmt blk >> popSymTab
cmpFuncDef (S.Func pos sym params retty blk) = withPos pos $ do
    returnOpType <- opTypeOf retty
    paramOpTypes <- mapM (opTypeOf . S.paramType) params
    let paramTypes = map S.paramType params
    let paramNames = map (ParameterName . mkBSS . S.paramName) params
    let paramSyms  = map S.paramName params

    ObjFunc _ op <- look sym (KeyFunc paramTypes)
    let LL.ConstantOperand (C.GlobalReference _ name) = op
    let Name nameStr = name

    addSymKeyDec sym (KeyFunc paramTypes) name (DecFunc paramOpTypes returnOpType)
    addDeclared name

    pushSymTab
    curRetty <- gets curRetType
    modify $ \s -> s { curRetType = retty }
    void $ InstrCmpT . IRBuilderT . lift $ func name (zip paramOpTypes paramNames) returnOpType $ \paramOps -> do
        forM_ (zip3 paramTypes paramOps paramSyms) $ \(typ, op, sym) -> do
            checkSymKeyUndef sym KeyVar
            loc <- valLocal typ
            valStore loc (Val typ op)
            addObj sym KeyVar (ObjVal loc)

        mapM_ cmpStmt blk
        hasTerm <- hasTerminator
        retty <- gets curRetType
        if hasTerm
        then return ()
        else if retty == Void
        then retVoid
        else unreachable

    modify $ \s -> s { curRetType = curRetty }
    popSymTab


cmpStmt :: InsCmp CompileState m => S.Stmt -> m ()
cmpStmt stmt = case stmt of
    S.Print pos exprs -> cmpPrint stmt
    S.Block stmts -> pushSymTab >> mapM_ cmpStmt stmts >> popSymTab

    S.CallStmt pos sym exprs -> withPos pos $ do
        vals <- mapM (valLoad <=< cmpExpr) exprs
        assert (not $ any valIsContextual vals) "contextual 224"

        res <- look sym $ KeyFunc (map valType vals)
        op <- case res of
            ObjFunc _ op     -> return op
            ObjExtern _ _ op -> return op

        void $ call op [(o, []) | o <- map valOp vals]

    S.Assign pos pat expr -> withPos pos $ do
        matched <- cmpPattern pat =<< cmpExpr expr
        if_ (valOp matched) (return ()) (void trap) 

    S.Set pos ind expr -> withPos pos $ do
        val <- cmpExpr expr
        case ind of
            S.IndIdent p sym -> do
                ObjVal loc <- look sym KeyVar
                valStore loc val

    S.Return pos Nothing -> withPos pos $ do
        curRetty <- gets curRetType
        assert (curRetty == Void) "must return a value"
        retVoid
        emitBlockStart =<< fresh

    S.Return pos (Just expr) -> withPos pos $ do
        retty <- gets curRetType
        ret . valOp =<< valLoad =<< valAsType retty =<< cmpExpr expr
        emitBlockStart =<< fresh

    S.If pos cnd blk melse -> withPos pos $ do
        pushSymTab
        val <- valLoad =<< cmpCondition cnd

        case melse of
            Nothing                   -> if_ (valOp val) (cmpStmt blk) (return ())
            Just blk2@(S.Block stmts) -> if_ (valOp val) (cmpStmt blk) (cmpStmt blk2)

        popSymTab

    S.While pos cnd blk -> withPos pos $ do
        cond <- freshName "while_cond"
        body <- freshName "while_body"
        exit <- freshName "while_exit"

        br cond
        emitBlockStart cond
        val <- valLoad =<< cmpCondition cnd
        condBr (valOp val) body exit
        
        emitBlockStart body
        pushSymTab
        mapM_ cmpStmt blk
        popSymTab
        br cond
        emitBlockStart exit

    S.Switch pos expr cases -> withPos pos $ do
        val <- cmpExpr expr

        exitName <- freshName "switch_exit"
        trapName <- freshName "switch_trap"
        cndNames <- replicateM (length cases) (freshName "case")
        stmtNames <- replicateM (length cases) (freshName "case_stmt")
        let nextNames = cndNames ++ [trapName]

        br (head nextNames)
        forM_ (zip4 cases cndNames stmtNames (tail nextNames)) $
            \((pat, stmt), cndName, stmtName, nextName) -> do
                emitBlockStart cndName
                pushSymTab
                matched <- valLoad =<< cmpPattern pat val
                condBr (valOp matched) stmtName nextName
                emitBlockStart stmtName
                cmpStmt stmt
                popSymTab
                br exitName

        emitBlockStart trapName
        void trap 
        br exitName
        emitBlockStart exitName

    _ -> error "stmt"


-- must return Val unless local variable
cmpExpr :: InsCmp CompileState m =>  S.Expr -> m Value
cmpExpr expr = case expr of
    e | exprIsContextual e     -> return (Exp expr)
    S.Bool pos b               -> return (valBool b)
    S.Char pos c               -> return (valChar c)
    S.Conv pos typ []          -> zeroOf typ
    S.Conv pos typ [S.Null p]  -> withPos pos (adtNull typ)
    S.Conv pos typ exprs       -> withPos pos $ valConstruct typ =<< mapM cmpExpr exprs
    S.Ident pos sym            -> withPos pos $ look sym KeyVar >>= \(ObjVal loc) -> return loc
    S.Prefix pos S.Not   expr  -> withPos pos $ valNot =<< cmpExpr expr
    S.Prefix pos S.Minus expr  -> withPos pos $ valsInfix S.Minus (Exp (S.Int undefined 0)) =<< cmpExpr expr
    S.Append pos exprA exprB   -> withPos pos $ valLoad =<< join (liftM2 tableAppend (cmpExpr exprA) (cmpExpr exprB))

    S.Infix pos op exprA exprB -> do
        let m = cmpExpr $ S.Call pos (show op) [exprA, exprB]
        catchError m $ \e -> withPos pos $ join $ liftM2 (valsInfix op) (cmpExpr exprA) (cmpExpr exprB)
            
    S.String pos s -> do
        loc <- globalStringPtr s =<< fresh
        let pi8 = C.BitCast loc (LL.ptr LL.i8)
        let i64 = toCons $ int64 $ fromIntegral (length s)
        let stc = struct Nothing False [i64, i64, pi8]
        return $ Val (Table [Char]) stc

    S.Call pos sym exprs -> withPos pos $ do
        vals <- mapM valResolveContextual =<< mapM cmpExpr exprs
        res <- look sym $ KeyFunc (map valType vals)

        case res of
            ObjFunc Void _         -> err "cannot use void function as expression"
            ObjExtern _ Void _     -> err "cannot use void function as expression"
            ObjConstructor typ     -> valConstruct typ vals
            ObjADTFieldCons adtTyp -> do
                adtConstructField sym adtTyp vals

            ObjFunc retty op       -> do
                vals' <- mapM valLoad vals
                Val retty <$> call op [(o, []) | o <- map valOp vals']
            ObjExtern _ retty op     -> do
                vals' <- mapM valLoad vals
                Val retty <$> call op [(o, []) | o <- map valOp vals']

    S.Len pos expr -> withPos pos $ valLoad =<< do
        val <- cmpExpr expr
        assert (not $ valIsContextual val) "contextual 362"
        typ <- baseTypeOf (valType val)
        case typ of
            Table _ -> tableLen val
            _       -> err ("cannot take length of type " ++ show typ)

    S.Tuple pos [expr] -> withPos pos (cmpExpr expr)
    S.Tuple pos exprs -> withPos pos $ do
        vals <- mapM cmpExpr exprs
        assert (not $ any valIsContextual vals) "contextual 371"
        tup <- valLocal $ Tuple [ ("", valType v) | v <- vals ]
        zipWithM_ (tupleSet tup) [0..] vals
        valLoad tup

    S.Subscript pos aggExpr idxExpr -> withPos pos $ valLoad =<< do
        agg <- cmpExpr aggExpr
        idx <- case idxExpr of
            S.Int p n -> return (valI64 n)
            _         -> cmpExpr idxExpr

        assert (not $ valIsContextual agg) "contextual 382"
        assert (not $ valIsContextual idx) "contextual 383"

        idxType <- baseTypeOf (valType idx)
        aggType <- baseTypeOf (valType agg)

        assert (isInt idxType) "index type isn't an integer"

        case aggType of
            Table [t] -> tupleIdx 0 =<< tableGetElem agg idx

    S.Range pos expr mstart mend -> withPos pos $ do
        val <- cmpExpr expr
        assert (not $ valIsContextual val) "contextual 395"
        base <- baseTypeOf (valType val)
        case base of
            Table ts -> do
                start <- maybe (return (valI64 0)) cmpExpr mstart
                valLoad =<< tableRange val start =<< maybe (tableLen val) cmpExpr mend
    
    S.Table pos exprss -> withPos pos $ valLoad =<< do
        valss <- mapM (mapM cmpExpr) exprss
        let rowLen = length (head valss)

        rowTypes <- forM valss $ \vals -> do
            assert (not $ any valIsContextual vals) "contextual 407"

            assert (length vals == rowLen) $ "mismatched table row length of " ++ show (length vals)
            let typ = valType (head vals)
            mapM_ (checkTypesMatch typ) (map valType vals)
            return typ

        rows <- forM (zip rowTypes [0..]) $ \(t, r) -> do
            mal <- valMalloc t (valI64 rowLen)
            forM_ [0..rowLen - 1] $ \i -> do
                ptr <- valPtrIdx mal (valI64 i) 
                valStore ptr ((valss !! r) !! i)
            return mal

        tab <- valLocal (Table rowTypes)
        tableSetLen tab (valI64 rowLen)
        tableSetCap tab (valI64 rowLen)
        zipWithM_ (tableSetRow tab) [0..] rows
        return tab

    S.Member pos exp sym -> withPos pos $ tupleMember sym =<< cmpExpr exp 

    _ -> err ("invalid expression: " ++ show expr)


cmpCondition :: InsCmp CompileState m => S.Condition -> m Value
cmpCondition cnd = do
    val <- case cnd of
        S.CondExpr expr -> cmpExpr expr
        S.CondMatch pat expr -> cmpPattern pat =<< cmpExpr expr

    assert (not $ valIsContextual val) "contextual 430"

    assertBaseType (== Bool) (valType val)
    return val



cmpPattern :: InsCmp CompileState m => S.Pattern -> Value -> m Value
cmpPattern pat val = case pat of
    S.PatIgnore pos -> return (valBool True)

    S.PatLiteral (S.Null pos) -> withPos pos $ do
        assert (not $ valIsContextual val) "contextual 450"
        ADT xs <- assertBaseType isADT (valType val)

        let is = [ i | (("", Void), i) <- zip xs [0..] ]
        assert (length is == 1) "adt type does not support a unique null value"
        let i = head is

        en <- adtEnum val
        valsInfix S.EqEq en (valI64 i)

    S.PatLiteral expr -> valsInfix S.EqEq val =<< cmpExpr expr

    S.PatGuarded pos pat expr -> withPos pos $ do
        match <- cmpPattern pat =<< valLoad val
        guard <- cmpExpr expr
        assert (not $ valIsContextual guard) "contextual 465"
        assertBaseType (== Bool) (valType guard)
        valsInfix S.AndAnd match guard

    S.PatIdent pos sym -> withPos pos $ do
        checkSymKeyUndef sym KeyVar
        val' <- valResolveContextual val
        loc <- valLocal (valType val')
        valStore loc val'
        addObj sym KeyVar (ObjVal loc)
        return (valBool True)

    S.PatTuple pos pats -> withPos pos $ do
        b <- valIsTuple val
        assert b "expression isn't a tuple"
        len <- tupleLength val
        assert (len == length pats) "tuple pattern length mismatch"

        bs <- forM (zip pats [0..]) $ \(p, i) ->
            cmpPattern p =<< tupleIdx i val

        foldM (valsInfix S.AndAnd) (valBool True) bs

    S.PatArray pos pats -> withPos pos $ do
        assert (not $ valIsContextual val) "contextual 487"
        base <- baseTypeOf (valType val)
        case base of
            Table ts -> do
                len   <- tableLen val
                lenEq <- valsInfix S.EqEq len (valI64 $ length pats)

                assert (length ts == 1) "patterns don't support multiple rows (yet)"
                bs <- forM (zip pats [0..]) $ \(p, i) ->
                    cmpPattern p =<< tupleIdx 0 =<< tableGetElem val (valI64 i)

                foldM (valsInfix S.AndAnd) (valBool True) (lenEq:bs)
            _ -> error (show base)

    S.PatSplit pos pat@(S.PatArray p pats) rest -> withPos pos $ do
        initMatched <- cmpPattern pat =<< tableRange val (valI64 0) (valI64 $ length pats)
        restMatched <- cmpPattern rest =<< tableRange val (valI64 $ length pats) =<< tableLen val
        valsInfix S.AndAnd initMatched restMatched

    S.PatSplit pos (S.PatLiteral (S.String p s)) rest -> withPos pos $ do
        let charPats = map (S.PatLiteral . S.Char p) s
        let arrPat   = S.PatArray p charPats
        cmpPattern (S.PatSplit pos arrPat rest) val

    S.PatTyped pos typ pat -> withPos pos $ do
        -- switch(tok)                 <- val
        --    string(s); do_stuff(s)   <- use raw type
        --    TokSym(s); do_stuff(s)   <- use field name
        assert (not $ valIsContextual val) "contextual 515"
        ADT xs <- assertBaseType isADT (valType val)

        let is = [ i | ((s, t), i) <- zip xs [0..], (s == "" && t == typ) || (Typedef s == typ) ]
        assert (length is == 1) "invalid ATD field identifier"
        let i = head is

        en <- adtEnum val
        b <- valsInfix S.EqEq en (valI64 i)

        loc <- valLocal $ ADT [xs !! i]
        adtSetPi8 loc =<< adtPi8 val
        val <- adtDeref loc
        valsInfix S.AndAnd b =<< cmpPattern pat val
    
    _ -> error (show pat)



cmpPrint :: InsCmp CompileState m => S.Stmt -> m ()
cmpPrint (S.Print pos exprs) = withPos pos $ do
    prints =<< mapM valResolveContextual =<< mapM cmpExpr exprs
    where
        prints :: InsCmp CompileState m => [Value] -> m ()
        prints []     = void $ printf "\n" []
        prints [val]  = valPrint "\n" val
        prints (v:vs) = valPrint ", " v >> prints vs


valConstruct :: InsCmp CompileState m => Type -> [Value] -> m Value
valConstruct typ []    = zeroOf typ
valConstruct typ [val] = do
    val' <- valResolveContextual val

    if valType val' == typ then do
        valLoad val'
    else do
        val' <- valLoad val
        base <- baseTypeOf typ
        case base of
            I32 -> case val' of
                Val I64 op -> Val base <$> trunc op LL.i32
                Val I8 op  -> Val base <$> sext op LL.i32

            I64 -> case val' of
                Val Char op -> Val base <$> sext op LL.i64

            Char -> case val' of
                Val I64 op -> Val base <$> trunc op LL.i8
                Val I32 op -> Val base <$> trunc op LL.i8
                _          -> error (show val')

            ADT _   -> adtConstruct typ val'
            _           -> do
                pureType    <- pureTypeOf typ
                pureValType <- pureTypeOf (valType val')
                checkTypesMatch pureType pureValType
                Val typ <$> valOp <$> valLoad val'
valConstruct typ vals = tupleConstruct typ vals


valAsType :: InsCmp CompileState m => Type -> Value -> m Value
valAsType typ val = case val of
    Val _ _              -> checkTypesMatch typ (valType val) >> return val
    Ptr _ _              -> checkTypesMatch typ (valType val) >> return val
    Exp (S.Int _ n)      -> valInt typ n
    Exp (S.Null _)       -> adtNull typ
    Exp (S.Table _ [[]]) -> assertBaseType isTable typ >> zeroOf typ
    Exp (S.Tuple _ es)   -> do
        Tuple xs <- assertBaseType isTuple typ

        assert (length es == length xs) ("does not satisfy " ++ show typ)
        vals <- forM (zip xs es) $ \((s, t), e) ->
            valAsType t =<< cmpExpr e 

        tup <- valLocal typ
        zipWithM_ (tupleSet tup) [0..] =<< zipWithM (valAsType . snd) xs vals
        return tup
