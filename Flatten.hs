{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module Flatten where
-- Walks an AST and resolves all symbols into unique names depending on scope.

import Control.Monad.State 
import qualified Data.Set as Set 
import qualified Data.Map as Map 
import qualified AST as S
import qualified Type as T
import Monad
import Error

type FlatSym = String


data SymKey
    = KeyType
    | KeyVar
    | KeyFunc
    | KeyExtern
    deriving (Show, Eq, Ord)


data SymObj
    = ObjTypeDef TextPos T.Type
    | ObjVarDef  TextPos S.Expr
    | ObjFuncDef S.Stmt
    | ObjExtern  S.Stmt
    deriving ()


data FlattenState
    = FlattenState
        { imports    :: [[S.ModuleName]]
        , typeDefs   :: Map.Map FlatSym (TextPos, T.Type)
        , varDefs    :: [S.Stmt]
        , funcDefs   :: [S.Stmt]
        , externDefs :: [S.Stmt]
        }


initFlattenState 
    = FlattenState
        { imports    = []
        , typeDefs   = Map.empty
        , varDefs    = []
        , funcDefs   = []
        , externDefs = []
        }


flattenASTs :: BoM FlattenState m => [S.AST] -> m ()
flattenASTs asts = do
    ast <- combineASTs asts
    flattenAST ast


combineASTs :: BoM s m => [S.AST] -> m S.AST
combineASTs asts = do
    let modNames = Set.toList $ Set.fromList $ map S.astModuleName asts
    when (length modNames /= 1) $ fail ("differing module names in asts: " ++ show modNames)

    return S.AST {
        S.astModuleName = head modNames,
        S.astImports    = Set.toList $ Set.fromList $ concat (map S.astImports asts),
        S.astStmts      = concat (map S.astStmts asts)
        }
        

flattenAST :: BoM FlattenState m => S.AST -> m ()
flattenAST ast = do
    mapM_ gatherTopStmt (S.astStmts ast)
    mapM_ checkTypedefCircles =<< fmap Map.keys (gets typeDefs)
    modify $ \s -> s { imports = S.astImports ast }
    where
        moduleName = maybe "main" id (S.astModuleName ast)
        
        gatherTopStmt :: BoM FlattenState m => S.Stmt -> m ()
        gatherTopStmt stmt = case stmt of
            S.Func _ _ _ _ _ -> modify $ \s -> s { funcDefs   = stmt:(funcDefs s) }
            S.Extern _ _ _ _ -> modify $ \s -> s { externDefs = stmt:(externDefs s) }
            S.Assign _ _ _   -> modify $ \s -> s { varDefs    = stmt:(varDefs s) }
            S.Typedef pos sym typ -> do
                b <- fmap (Map.member sym) (gets typeDefs)
                when b $ fail (sym ++ " already defined")
                modify $ \s -> s { typeDefs = Map.insert sym (pos, typ) (typeDefs s) }

            _ -> fail "invalid top-level statement"

        checkTypedefCircles :: BoM FlattenState m => FlatSym -> m ()
        checkTypedefCircles flat = do
            checkTypedefCircles' flat Set.empty
            where
                checkTypedefCircles' :: BoM FlattenState m => FlatSym -> Set.Set FlatSym -> m ()
                checkTypedefCircles' flat visited = do
                    when (Set.member flat visited) $
                        fail ("circular type dependency: " ++ flat)
                    res <- fmap (Map.lookup flat) (gets typeDefs)
                    case res of
                        Just (pos, T.Typedef f) -> checkTypedefCircles' f (Set.insert flat visited)
                        _                       -> return ()


prettyFlatAST :: FlattenState -> IO ()
prettyFlatAST flatAST = do
    putStrLn "typeDefs:"
    forM_ (Map.toList $ typeDefs flatAST) $ \(flat, obj) ->
        putStrLn $ take 100 ("\t" ++ flat ++ ": " ++ show obj)
