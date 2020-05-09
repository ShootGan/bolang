{-# LANGUAGE TupleSections #-}

module CmpVal where

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
import           LLVM.AST.IntegerPredicate
import           LLVM.AST.FloatingPointPredicate (FloatingPointPredicate(OEQ))
import           LLVM.AST.Type              hiding (void, double)
import           LLVM.AST.Typed
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad

import qualified Lexer                      as L
import qualified AST                        as S
import           CmpBuilder
import           Cmp

mkBSS = BSS.toShort . BS.pack


type Compile     = State ValType
initCompileState = Void


setCurRetTyp :: ValType -> Instr ()
setCurRetTyp typ =
    void $ lift $ put typ


getCurRetTyp :: Instr ValType
getCurRetTyp =
    lift get


type MyCmpState = CmpState SymKey SymObj
type Instr      = InstrCmpT SymKey SymObj Compile
type Module     = ModuleCmpT SymKey SymObj Compile


data SymKey
    = KeyVal
    | KeyFunc [ValType]
    | KeyType
    deriving (Show, Eq, Ord)


data SymObj
    = ObjVal Value
    | ObjFunc ValType Operand
    | ObjType ValType
    deriving (Show, Eq)


data Value
    = Val { valType :: ValType, valOp :: Operand }
    | Ptr { valType :: ValType, valOp :: Operand }
    deriving (Show, Eq)


data ValType
    = Void
    | I32
    | I64
	| F32
	| F64
    | Bool
    | Char
    | String
    | Tuple [ValType]
    | Array Int ValType
    | Typedef String
    deriving (Show, Eq, Ord)


isInt x               = x `elem` [I32, I64]
isFloat x             = x `elem` [F32, F64]
isBase x              = isInt x || isFloat x || x `elem` [Bool, String, Char]
isArray (Array _ _)   = True
isArray _             = False
isTuple (Tuple _)     = True
isTuple _             = False
isTypedef (Typedef _) = True
isTypedef _           = False
isIntegral x          = isInt x || x == Char
isAggregate x         = isTuple x || isArray x
isExpr x              = isBase x || isAggregate x || isTypedef x
isExpr _              = False


fromASTType :: S.Type -> ValType
fromASTType typ = case typ of
    S.TBool      -> Bool
    S.TI32       -> I32
    S.TI64       -> I64
    S.TF32       -> F32
    S.TF64       -> F64
    S.TChar      -> Char
    S.TString    -> String
    S.TArray n t -> Array n (fromASTType t)
    S.TTuple ts  -> Tuple (map fromASTType ts)
    S.TIdent sym -> Typedef sym


opTypeOf :: ValType -> Instr Type
opTypeOf typ = case typ of
        Void      -> error "opTypeOf void"
        Bool      -> return i1
        Char      -> return i32
        I32       -> return i32
        I64       -> return i64
        F32       -> return (FloatingPointType HalfFP)
        F64       -> return (FloatingPointType DoubleFP)
        Tuple ts  -> fmap (StructureType False) (mapM opTypeOf ts)
        Array n t -> fmap (ArrayType $ fromIntegral n) (opTypeOf t)
        String    -> return (ptr i8)
        Typedef _ -> opTypeOf =<< getConcreteType typ


zeroOf :: ValType -> Instr C.Constant
zeroOf typ = case typ of
    I32        -> return $ toCons (int32 0)
    I64        -> return $ toCons (int64 0)
    F32        -> return $ toCons (single 0)
    F64        -> return $ toCons (double 0)
    Bool       -> return $ toCons (bit 0)
    Char       -> return $ toCons (int32 0)
    String     -> return $ C.IntToPtr (toCons $ int64 0) (ptr i8)
    Array n t  -> return . toCons . array . replicate n =<< zeroOf t
    Tuple typs -> return . toCons . (struct Nothing False) =<< mapM zeroOf typs
    Typedef _  -> zeroOf =<< getConcreteType typ
    x          -> error (show x)


getConcreteType :: ValType -> Instr ValType
getConcreteType (Tuple ts) =
    fmap Tuple (mapM getConcreteType ts)
getConcreteType (Array n t) =
    fmap (Array n) (getConcreteType t)
getConcreteType (Typedef symbol) = do
    ObjType typ <- look symbol KeyType
    getConcreteType typ
getConcreteType typ =
    return typ


typesMatch :: ValType -> ValType -> Instr Bool
typesMatch a b = do
    ca <- getConcreteType a
    cb <- getConcreteType b
    return (ca == cb)


valGlobal :: Name -> ValType -> Instr (Value, Definition)
valGlobal name typ = do
    opTyp <- opTypeOf typ
    loc <- global name opTyp =<< zeroOf typ
    return (Ptr typ loc, globalDef name opTyp Nothing)


valLocal :: ValType -> Instr Value
valLocal typ = do
    opTyp <- opTypeOf typ
    loc <- alloca opTyp Nothing 0
    return (Ptr typ loc)


valStore :: Value -> Value -> Instr ()
valStore (Ptr typ loc) val = do
    match <- typesMatch typ (valType val)
    assert match "underlying types don't match"
    case val of
        Ptr t l -> store loc 0 =<< load l 0
        Val t o -> store loc 0 o


valLoad :: Value -> Instr Value
valLoad (Val typ op)  = return (Val typ op)
valLoad (Ptr typ loc) = fmap (Val typ) (load loc 0)


valArrayIdx :: Value -> Value -> Instr Value
valArrayIdx (Ptr (Array n t) loc) idx = do
    assert (isInt $ valType idx) "array index isn't int"
    Val _ i <- valLoad idx
    ptr <- gep loc [int64 0, i]
    return (Ptr t ptr)


valArrayConstIdx :: Value -> Int -> Instr Value
valArrayConstIdx (Val (Array n t) op) i =
    fmap (Val t) (extractValue op [fromIntegral i])
valArrayConstIdx (Ptr (Array n t) loc) i =
    fmap (Ptr t) (gep loc [int32 0, int32 (fromIntegral i)])


valArraySet :: Value -> Value -> Value -> Instr ()
valArraySet (Ptr (Array n t) loc) idx val = do
    assert (isInt $ valType idx) "index isn't int"
    assert (valType val == t) "incorrect element type"
    i <- valLoad idx
    ptr <- gep loc [int32 0, valOp i]
    valStore (Ptr t ptr) val


valLen :: Value -> Int
valLen (Ptr (Array n _) _) = n
valLen (Val (Array n _) _) = n
valLen (Ptr (Tuple ts) _)  = length ts
valLen (Val (Tuple ts) _)  = length ts


valTupleIdx :: Value -> Int -> Instr Value
valTupleIdx (Val (Tuple ts) op) i = do
    assert (i >= 0 && i < length ts) "tuple index out of range"
    fmap (Val (ts !! i)) $ extractValue op [fromIntegral i]
valTupleIdx (Ptr (Tuple ts) loc) i = do
    assert (i >= 0 && i < length ts) "tuple index out of range"
    fmap (Ptr (ts !! i)) $ gep loc [int32 0, int32 (fromIntegral i)]
    

valTupleSet :: Value -> Int -> Value -> Instr ()
valTupleSet (Ptr (Tuple ts) loc) i val = do
    ptr <- gep loc [int32 0, int32 (fromIntegral i)]
    valStore (Ptr (ts !! i) ptr) val


valPrint :: String -> Value -> Instr ()
valPrint append val
    | valType val == Bool = do
        Val Bool op <- valLoad val
        str <- globalStringPtr "true\0false" =<< fresh
        idx <- select op (int64 0) (int64 5)
        ptr <- gep (cons str) [idx]
        void $ printf ("%s" ++ append) [ptr]

    | isArray (valType val) = do
        let len = valLen val
        putchar '['
        for (int64 $ fromIntegral len-1) $ \i -> do
            valPrint ", " =<< valArrayIdx val (Val I64 i)
        valPrint ("]" ++ append) =<< valArrayConstIdx val (len-1)

    | isTuple (valType val) = do
        let len = valLen val 
        putchar '('
        forM_ [0..len-1] $ \i -> do
            let app = if i < len-1 then ", " else ")" ++ append
            valPrint app =<< valTupleIdx val i

    | otherwise = do
        Val typ op <- valLoad val
        case typ of
            I32    -> void $ printf ("%d" ++ append) [op]
            I64    -> void $ printf ("%ld" ++ append) [op]
            F32    -> void $ printf ("%f" ++ append) [op]
            F64    -> void $ printf ("%f" ++ append) [op]
            Char   -> void $ printf ("%c" ++ append) [op]
            String -> void $ printf ("\"%s\"" ++ append) [op]
            t      -> cmpErr ("cannot print value with type: " ++ show t)


publicFunction :: String -> [(String, ValType)] -> ValType -> ([Value] ->  Instr ()) -> Instr ()
publicFunction symbol params retty f = do 
    retOpTyp <- opTypeOf retty
    let (paramSymbols, paramTyps) = unzip params
    checkSymKeyUndefined symbol (KeyFunc paramTyps)

    let paramNames = map mkName paramSymbols
    let paramFnNames = map (ParameterName . mkBSS) paramSymbols
    paramOpTyps <- mapM opTypeOf paramTyps

    name <- freshName (mkBSS symbol)

    pushSymTab
    oldRetTyp <- getCurRetTyp
    setCurRetTyp retty
    op <- InstrCmpT $ IRBuilderT . lift $ function name (zip paramOpTyps paramFnNames) retOpTyp $ \argOps ->
        getInstrCmp $ do
            forM_ (zip3 paramSymbols paramTyps argOps) $ \(sym, ty, op) -> do
                checkUndefined sym
                arg <- valLocal ty
                valStore arg (Val ty op)
                addSymObj sym KeyVal (ObjVal arg)

            f [Val t o | (t, o) <- zip paramTyps argOps]

    setCurRetTyp oldRetTyp
    popSymTab

    addDeclared name
    addExported name
    addSymObj symbol (KeyFunc paramTyps) (ObjFunc retty op)
    addSymObjReq symbol (KeyFunc paramTyps) name
    addDef name $ funcDef name (zip paramOpTyps paramNames) retOpTyp []

