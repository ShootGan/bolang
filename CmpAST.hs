{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}

module CmpAST where

import           Control.Monad
import           Control.Monad.Except       hiding (void)
import           Control.Monad.State
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Short      as BSS
import           Data.Maybe
import qualified Data.Map                   as Map
import qualified Data.Set                   as Set
import           Data.List                  hiding (and, or)
import           Data.Word
import           Prelude                    hiding (EQ, and, or)

import           LLVM.AST                   hiding (function, Module)
import qualified LLVM.AST.Constant          as C
import           LLVM.AST.Global
import           LLVM.AST.IntegerPredicate
import qualified LLVM.AST.FloatingPointPredicate as F
import           LLVM.AST.Type              hiding (void, double)
import           LLVM.AST.Typed
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad

import qualified Lexer                      as L
import qualified AST                        as S
import           CmpFuncs
import           CmpValue
import           CmpMonad


compile :: MyCmpState -> S.AST -> Either CmpError ([Definition], MyCmpState) 
compile state ast = do
    let (res, _) = runState (runModuleCmpT emptyModuleBuilder state cmp) initCompileState
    fmap (\((_, defs), state') -> (defs, state')) res
    where
        cmp :: Module ()
        cmp =
            void $ function "main" [] VoidType $ \_ -> do
                getInstrCmp (mapM_ cmpTopStmt ast)


cmpTopStmt :: S.Stmt -> Instr ()
cmpTopStmt stmt@(S.Set _ _ _)      = cmpStmt stmt
cmpTopStmt stmt@(S.Print _ _)      = cmpStmt stmt
cmpTopStmt stmt@(S.CallStmt _ _ _) = cmpStmt stmt
cmpTopStmt stmt@(S.Switch _ _ _)   = cmpStmt stmt

cmpTopStmt (S.Typedef pos symbol astTyp) = do
    checkUndefined symbol

    let typ    = fromASTType astTyp
    let typdef = Typedef symbol
    zero  <- fmap cons (zeroOf typ)
    conc  <- getConcreteType typ

    if isTuple typ then do
        name <- freshName (mkBSS symbol)
        opTyp <- opTypeOf typ
        addAction name (typedef name $ Just opTyp)
        addSymObj symbol KeyType $ ObjType (Named name typ)
        addSymObjReq symbol KeyType name
    else
        addSymObj symbol KeyType (ObjType typ)

    addSymObj symbol (KeyFunc [])    $ ObjVal (Val typdef zero)
    addSymObj symbol (KeyFunc [typ]) $ ObjInline (\[Val _ op] -> Val typdef op)
    unless (conc == typ) $ 
        addSymObj symbol (KeyFunc [conc]) $ ObjInline (\[Val _ op] -> Val typdef op)


cmpTopStmt (S.Datadef pos symbol datas) = withPos pos $ do
    checkUndefined symbol
    (nameStrs, nameStrLens) <- fmap unzip $ forM (map S.dataSymbol datas) $ \sym -> do
        checkUndefined sym
        return (sym ++ "\0", fromIntegral $ length sym + 1)

    let numIdxs = fromIntegral (length nameStrLens)
    let (_, idxs) = foldl (\(n, a) l -> (n+l, a ++ [n])) (0, []) nameStrLens

    strName <- freshName $ mkBSS (symbol ++ "str")
    idxName <- freshName $ mkBSS (symbol ++ "idx")

    let (strDef, strOp) = stringDef strName (concat nameStrs)
    let (idxDef, idxOp) = globalDef idxName (ArrayType numIdxs i64) $ Just $ C.Array i64 $ map (C.Int 64) idxs

    addAction strName (emitDefn strDef)
    addAction idxName (emitDefn idxDef)

    addSymObj symbol KeyType $ ObjData (Val String strOp) (Ptr (Array numIdxs I64) idxOp) 
    addSymObjReq symbol KeyType strName
    addSymObjReq symbol KeyType idxName

    forM_ (zip datas [0..]) $ \(d, i) -> cmpData d i
    where
        cmpData :: S.Data -> Integer -> Instr ()
        cmpData (S.DataIdent p sym) i = do
            checkUndefined sym
            addSymObj sym (KeyFunc []) $ ObjVal $ Val (Typedef symbol) (int64 i)
            

cmpTopStmt (S.Assign pos pattern expr) =
    assignPattern pattern =<< cmpExpr expr
    where
        assignPattern ::  S.Pattern -> Value -> Instr ()
        assignPattern (S.PatTuple p patterns) val
            | isTuple (valType val) = withPos p $ do
                len <- valLen val
                assert (fromIntegral (length patterns) == len) "incorrect tuple length"
                forM_ (zip patterns [0..]) $ \(pattern, i) ->
                    assignPattern pattern =<< valTupleIdx val i

        assignPattern (S.PatArray p patterns) val 
            | isArray (valType val) = withPos p $ do
                forM_ (zip patterns [0..]) $ \(pattern, i) ->
                    assignPattern pattern =<< valArrayConstIdx val i

        assignPattern (S.PatIdent p symbol) val = withPos p $ do
            checkUndefined symbol
            name <- freshName (mkBSS symbol)
            (new, ext) <- valGlobal name (valType val)
            valStore new val

            addSymObj symbol KeyVal (ObjVal new)
            addSymObjReq symbol KeyVal name
            addAction name (emitDefn ext)
            addDeclared name
            addExported name

        assignPattern pat _ =
            withPos (S.pos pat) (cmpErr "invalid assignment pattern")

cmpTopStmt (S.Func pos symbol params mretty block) = withPos pos $ do
    let paramTyps    = map (fromASTType . S.paramType) params
    let paramSymbols = map S.paramName params
    let retTyp       = maybe Void fromASTType mretty
    publicFunction symbol (zip paramSymbols paramTyps) retTyp $ \args ->
        mapM_ cmpStmt block
        

cmpStmt :: S.Stmt -> Instr ()
cmpStmt (S.CallStmt pos symbol args) = void $ cmpExpr (S.Call pos symbol args)

cmpStmt (S.Assign pos pattern expr) = do
    val <- cmpExpr expr
    typ <- getConcreteType (valType val)
    assignPattern pattern (val { valType = typ })
    where
        assignPattern ::  S.Pattern -> Value -> Instr ()
        assignPattern (S.PatTuple p patterns) val
            | isTuple (valType val) = withPos p $ do
                len <- valLen val
                assert (fromIntegral (length patterns) == len) "incorrect tuple length"
                forM_ (zip patterns [0..]) $ \(pattern, i) ->
                    assignPattern pattern =<< valTupleIdx val i

        assignPattern (S.PatArray p patterns) val 
            | isArray (valType val) = withPos p $ do
                forM_ (zip patterns [0..]) $ \(pattern, i) ->
                    assignPattern pattern =<< valArrayConstIdx val i

        assignPattern (S.PatIdent p symbol) val = withPos p $ do
            checkUndefined symbol
            new <- valLocal (valType val)
            valStore new val
            addSymObj symbol KeyVal (ObjVal new)

        assignPattern pat _ =
            withPos (S.pos pat) (cmpErr "invalid assignment pattern")

cmpStmt (S.Set pos index expr) = withPos pos $ do
    val <- cmpExpr expr
    idx <- idxPtr index
    assert (valType val == valType idx) "type mismatch"
    valStore idx val
    where
        idxPtr :: S.Index -> Instr Value
        idxPtr (S.IndIdent p symbol) = withPos p $ do
            ObjVal loc@(Ptr _ _) <- look symbol KeyVal
            return loc

        idxPtr (S.IndArray p ind exp) = withPos p $ do
            arr <- idxPtr ind
            idx <- cmpExpr exp
            valArrayIdx arr idx

        idxPtr (S.IndTuple p ind i) = withPos p $ do
            tup <- idxPtr ind
            valTupleIdx tup i

cmpStmt (S.Switch pos expr []) = return ()
cmpStmt (S.Switch pos expr cases) = withPos pos $ do
    exit <- fresh
    cndNames <- replicateM (length cases) (freshName "case")
    stmtNames <- replicateM (length cases) (freshName "case_stmt")

    let nextNames = tail cndNames ++ [exit]
    let (caseExprs, stmts) = unzip cases

    br (head cndNames)
    pushSymTab

    forM_ (zip5 caseExprs cndNames stmtNames nextNames stmts) $
        \(caseExpr, cndName, stmtName, nextName, stmt) -> do
            emitBlockStart cndName
            if isJust caseExpr then do
                val <- cmpExpr expr
                cas <- cmpExpr (fromJust caseExpr)
                Val Bool cnd <- valsEqual val cas
                condBr cnd stmtName nextName
            else
                br stmtName
            emitBlockStart stmtName
            cmpStmt stmt
            br exit

    popSymTab
    br exit
    emitBlockStart exit

cmpStmt (S.Return pos mexpr) = withPos pos $ do
    retTyp <- getCurRetTyp
    if isNothing mexpr then do
        assert (retTyp == Void) "must return expression"
        retVoid
    else do
        val <- valLoad =<< cmpExpr (fromJust mexpr)
        assert (retTyp == valType val) "incorrect return type" 
        ret (valOp val)
    return ()

cmpStmt (S.Print pos exprs) = withPos pos $
    prints =<< mapM cmpExpr exprs
    where
        prints :: [Value] -> Instr ()
        prints []     = return ()
        prints [val]  = valPrint "\n" val
        prints (v:vs) = valPrint ", " v >> prints vs


cmpExpr :: S.Expr -> Instr Value
cmpExpr (S.Int pos i)   = return $ Val I64 (int64 i)
cmpExpr (S.Float pos f) = return $ Val F64 (double f)
cmpExpr (S.Bool pos b)  = return $ Val Bool (bit $ if b then 1 else 0)
cmpExpr (S.Char pos c)  = return $ Val Char (int32 $ fromIntegral $ fromEnum c)

cmpExpr (S.String pos s) = do
    name <- freshName (mkBSS "string")
    str <- globalStringPtr s name
    addExported name
    return $ Val String (cons str)

cmpExpr (S.Call pos symbol args) = withPos pos $ do
    vals <- mapM valLoad =<< mapM cmpExpr args
    res <- look symbol $ KeyFunc (map valType vals)
    case res of
        ObjFunc typ op -> fmap (Val typ) $ call op $ map (,[]) (map valOp vals)
        ObjVal val     -> return val
        ObjInline f    -> return (f vals)

cmpExpr (S.Ident pos symbol) = do
    ObjVal val <- look symbol KeyVal
    return val

cmpExpr (S.Array pos exprs) = do
    vals <- mapM cmpExpr exprs
    let n = fromIntegral (length vals)
    assert (n > 0) "can't deduce array type"
    let t = valType (head vals)
    arr <- valLocal (Array n t)
    forM_ (zip vals [0..]) $ \(val, i) ->
        valArraySet arr (Val I64 $ int64 i) val
    return arr

cmpExpr (S.Tuple pos exprs) = do
    vals <- mapM cmpExpr exprs
    tup <- valLocal $ Tuple (map valType vals)
    forM_ (zip vals [0..]) $ \(val, i) -> valTupleSet tup i val
    return tup

cmpExpr (S.ArrayIndex pos arrExpr idxExpr) = do
    arr <- cmpExpr arrExpr
    idx <- cmpExpr idxExpr
    valArrayIdx arr idx

cmpExpr (S.Infix pos S.EqEq exprA exprB) = withPos pos $ do
    valA <- cmpExpr exprA
    valB <- cmpExpr exprB
    valsEqual valA valB
cmpExpr (S.Infix pos operator exprA exprB) = do
    valA <- valLoad =<< cmpExpr exprA
    valB <- valLoad =<< cmpExpr exprB
    cmpInfix operator valA valB
    where
        res typ = fmap (Val typ)

        invalid :: Instr a
        invalid = cmpErr "invalid infix"

        cmpInfix :: S.Op -> Value -> Value -> Instr Value
        cmpInfix operator (Val typA opA) (Val typB opB)
            | typA == typB && isIntegral typA = case operator of
                S.Plus   -> res typA (add opA opB)
                S.Minus  -> res typA (sub opA opB)
                S.Times  -> res typA (mul opA opB)
                S.Divide -> res typA (sdiv opA opB)
                S.Mod    -> res typA (srem opA opB)
                S.LT     -> res Bool (icmp SLT opA opB)
                S.GT     -> res Bool (icmp SGT opA opB)
                S.LTEq   -> res Bool (icmp SLE opA opB)
                S.GTEq   -> res Bool (icmp SGT opA opB)
                _        -> invalid

            | typA == typB && isFloat typA = case operator of
                S.Plus   -> res typA (fadd opA opB)
                S.Minus  -> res typA (fsub opA opB)
                S.Times  -> res typA (fmul opA opB)
                S.Divide -> res typA (fdiv opA opB)
                S.Mod    -> res typA (frem opA opB)
                S.LT     -> res Bool (fcmp F.OLT opA opB)
                S.GT     -> res Bool (fcmp F.OGT opA opB)
                S.LTEq   -> res Bool (fcmp F.OLE opA opB)
                S.GTEq   -> res Bool (fcmp F.OGE opA opB)
                _        -> invalid

            | typA == Bool && typB == Bool = case operator of
                S.AndAnd -> res Bool (and opA opB)
                S.OrOr   -> res Bool (or opA opB)
                _        -> invalid

            | otherwise =
                invalid