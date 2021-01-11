{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module Resolver where
-- Walks an AST and resolves all symbols into unique names depending on scope.

import Prelude hiding (fail)
import Control.Monad.State hiding (fail)
import Control.Monad.Fail
import Control.Monad.Except hiding (void, fail)
import Data.Maybe
import Data.Char
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified AST as S
import qualified SymTab
import qualified Type as T
import Error
import Monad


type Name = String


data ResolverState
    = ResolverState
        { nameSupply  :: Map.Map Name Int
        , symbolTable :: SymTab.SymTab S.Symbol Int Name
        }
    deriving Show


initResolverState
    = ResolverState
        { nameSupply  = Map.empty
        , symbolTable = SymTab.initSymTab
        }


fresh :: BoM ResolverState m => S.Symbol -> m Name
fresh symbol = do
    names <- gets nameSupply
    let i = maybe 0 (+1) (Map.lookup symbol names)
    modify $ \s -> s { nameSupply = Map.insert symbol i names }
    return (symbol ++ "_" ++ show i)


lookupSym :: BoM ResolverState m => S.Symbol -> m Name
lookupSym symbol = do
    symTab <- gets symbolTable
    fmap (Map.! 0) $ maybe (fail $ symbol ++ " doesn't exist") return (SymTab.lookupSym symbol symTab)


checkSymUndef :: BoM ResolverState m => S.Symbol -> m ()
checkSymUndef symbol = do
    symTab <- gets symbolTable
    case SymTab.lookupSym symbol [head symTab] of
        Just _  -> fail (symbol ++ " already defined")
        Nothing -> return ()


addSymDef :: BoM ResolverState m => S.Symbol -> Name -> m ()
addSymDef symbol name =
    modify $ \s -> s { symbolTable = SymTab.insert symbol 0 name (symbolTable s) }


pushScope :: BoM ResolverState m => m ()
pushScope =
    modify $ \s -> s { symbolTable = SymTab.push (symbolTable s) }


popScope :: BoM ResolverState m => m ()
popScope  =
    modify $ \s -> s { symbolTable = SymTab.pop (symbolTable s) }


resolveAST :: (MonadIO m, MonadFail m) => ResolverState -> S.AST -> m (Either CmpError (S.AST, ResolverState))
resolveAST state ast =
    runBoMT state f
    where
        f = do
            stmts <- mapM resStmt (S.astStmts ast)
            return (ast { S.astStmts = stmts })


resPattern :: BoM ResolverState m => S.Pattern -> m S.Pattern
resPattern pattern = case pattern of
    S.PatIgnore pos       -> return pattern
    S.PatLiteral cons     -> return pattern
    S.PatIdent pos symbol -> do
        checkSymUndef symbol
        name <- fresh symbol
        addSymDef symbol name
        return (S.PatIdent pos name)
    _ -> fail (show pattern)


resIndex :: BoM ResolverState m => S.Index -> m S.Index
resIndex index = case index of
    S.IndIdent pos symbol -> fmap (S.IndIdent pos) (lookupSym symbol)


resType :: BoM ResolverState m => T.Type -> m T.Type
resType typ = case typ of
    T.Char     -> return typ
    T.Table ts -> fmap T.Table (mapM resType ts)
        

resParam :: BoM ResolverState m => S.Param -> m S.Param
resParam (S.Param pos symbol typ) = do
    checkSymUndef symbol
    name <- fresh symbol
    addSymDef symbol name
    typ' <- resType typ
    return (S.Param pos name typ')


resStmt :: BoM ResolverState m => S.Stmt -> m S.Stmt
resStmt stmt = case stmt of
    S.Assign pos pattern expr -> do
        resPat <- resPattern pattern
        resExp <- resExpr expr
        return (S.Assign pos resPat resExp)
    S.Set pos index expr -> do
        resInd <- resIndex index
        resExp <- resExpr expr
        return (S.Set pos resInd resExp)
    S.Print pos exprs -> fmap (S.Print pos) (mapM resExpr exprs)
    S.Block pos stmts -> do
        pushScope
        resStmts <- mapM resStmt stmts
        popScope
        return (S.Block pos resStmts)
    S.CallStmt pos symbol exprs -> do
        name <- lookupSym symbol
        fmap (S.CallStmt pos name) (mapM resExpr exprs)
    S.Return pos mexpr -> do
        fmap (S.Return pos) $ case mexpr of
            Nothing -> return Nothing
            Just ex -> fmap Just (resExpr ex)
    S.While pos cnd stmts -> do
        resCnd <- resExpr cnd
        pushScope
        resStmts <- mapM resStmt stmts
        popScope
        return (S.While pos resCnd resStmts)
    S.Switch pos cnd cases -> do
        resCnd <- resExpr cnd
        pushScope
        resCases <- forM cases $ \(pat, stmt) -> do
            pat' <- resPattern pat
            stmt' <- resStmt stmt
            return (pat', stmt')
        popScope
        return (S.Switch pos resCnd resCases)
    S.Extern pos symbol params mretty -> do
        checkSymUndef symbol
        addSymDef symbol symbol
        pushScope
        mretty' <- maybe (return Nothing) (fmap Just . resType) mretty
        params' <- mapM resParam params
        popScope
        return (S.Extern pos symbol params' mretty')
    S.Func pos symbol params mretty stmts -> do
        checkSymUndef symbol
        name <- fresh symbol
        addSymDef symbol name
        pushScope
        params' <- mapM resParam params
        mretty' <- maybe (return Nothing) (fmap Just . resType) mretty
        stmts'  <- mapM resStmt stmts
        popScope
        return (S.Func pos name params' mretty' stmts')
    _ -> fail ("resolver case: " ++ show stmt)


resExpr :: BoM ResolverState m => S.Expr -> m S.Expr
resExpr (S.Ident pos symbol) = fmap (S.Ident pos) (lookupSym symbol)
resExpr expr = case expr of
    S.Cons c           -> return expr
    S.Tuple pos exprs  -> fmap (S.Tuple pos) (mapM resExpr exprs)
    S.Array pos exprs  -> fmap (S.Array pos) (mapM resExpr exprs)
    S.Table pos exprss -> fmap (S.Table pos) (mapM (mapM resExpr) exprss)
    S.Len pos expr     -> fmap (S.Len pos) (resExpr expr)
    S.Append pos a b -> do
        a' <- resExpr a
        b' <- resExpr b
        return (S.Append pos a' b')
    S.Call pos symbol exprs -> do
        name <- lookupSym symbol
        fmap (S.Call pos name) (mapM resExpr exprs)
    S.Conv pos typ exprs  -> do
        typ' <- resType typ
        fmap (S.Conv pos typ') (mapM resExpr exprs)
    S.Subscript pos expr ind -> do
        expr' <- resExpr expr
        fmap (S.Subscript pos expr') (resExpr ind)
    S.Infix pos op a b    -> do
        a' <- resExpr a
        b' <- resExpr b
        return (S.Infix pos op a' b')
    _ -> fail (show expr)