{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleInstances #-}

module CmpValue where

import           Control.Monad
import           Control.Monad.State
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Short      as BSS
import           Data.Maybe
import           Data.List                  hiding (and, or)
import           Data.Word
import           Prelude                    hiding (EQ, and, or)

import           LLVM.Context
import           LLVM.AST                   hiding (function, Module)
import qualified LLVM.AST.Constant          as C
import           LLVM.AST.IntegerPredicate
import           LLVM.AST.Type              hiding (void, double)
import           LLVM.Internal.Type
import           LLVM.Internal.EncodeAST
import           LLVM.Internal.Coding           hiding (alloca)
import           Foreign.Ptr
import qualified LLVM.Internal.FFI.DataLayout   as FFI
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad

import qualified AST                        as S
import           CmpFuncs
import           CmpMonad

mkBSS = BSS.toShort . BS.pack


type Compile    = StateT CompileState IO
type MyCmpState = CmpState SymKey SymObj
type Instr      = InstrCmpT SymKey SymObj Compile
type Module     = ModuleCmpT SymKey SymObj Compile


data CompileState
    = CompileState
        { context    :: Context
        , dataLayout :: Ptr FFI.DataLayout
        , curRetTyp  :: ValType
        }
initCompileState ctx dl = CompileState ctx dl Void


data SymKey
    = KeyVal
    | KeyFunc [ValType]
    | KeyType
    | KeyDataCons
    deriving (Show, Eq, Ord)


instance Show ([Value] -> Instr Value) where show _ = "Inline"
instance Show (Value -> Instr ()) where show _ = "Inline"
data SymObj
    = ObjVal Value
    | ObjFunc ValType Operand
    | ObjInline ([Value] -> Instr Value)
    | ObjType ValType
    | ObjDataCons { dataTyp :: ValType, dataConsTyp :: ValType, dataEnum :: Word }
    | ObjData     { dataConcTyp :: ValType, dataPrintFn :: (Value -> Instr ()) }
    deriving (Show)


data Value
    = Val { valType :: ValType, valOp :: Operand }
    | Ptr { valType :: ValType, valOp :: Operand }
    deriving (Show, Eq)


data ValType
    = Void
    | I8
    | I32
    | I64
	| F32
	| F64
    | Bool
    | Char
    | String
    | Tuple (Maybe Name) [ValType]
    | Array Word64 ValType
    | Table (Maybe Name) [ValType]
    | Typedef String
    | AnnoTyp String ValType
    deriving (Eq, Ord)


instance Show ValType where
    show t = case t of
        Void        -> "void"
        I8          -> "i8"
        I32         -> "i32"
        I64         -> "i64"
        F32         -> "f32"
        F64         -> "f64"
        Bool        -> "bool"
        Char        -> "char"
        String      -> "string"
        Tuple nm ts -> "(" ++ intercalate ", " (map show ts) ++ ")"
        Array n t   -> "[" ++ show n ++ " " ++ show t ++ "]"
        Table nm ts -> "{" ++ intercalate "; " (map show ts) ++ "}"
        Typedef s   -> s
        AnnoTyp _ t -> show t


fmapValType :: (ValType -> Instr ValType) -> ValType -> Instr ValType  
fmapValType f typ = case typ of
    Tuple nm ts -> f . (Tuple nm) =<< mapM (fmapValType f) ts
    Table nm ts -> f . (Table nm) =<< mapM (fmapValType f) ts
    Array n t   -> f . (Array n) =<< fmapValType f t
    AnnoTyp s t -> f . (AnnoTyp s) =<< fmapValType f t
    t           -> f t


setCurRetTyp :: ValType -> Instr ()
setCurRetTyp typ =
    lift $ modify $ \s -> s { curRetTyp = typ }


getCurRetTyp :: Instr ValType
getCurRetTyp =
    lift (gets curRetTyp)


isChar (AnnoTyp _ t)    = isChar t
isChar x                = x == Char

isString (AnnoTyp _ t)  = isString t
isString x              = x == String

isInt (AnnoTyp _ t)     = isInt t
isInt x                 = x `elem` [I8, I32, I64]

isFloat (AnnoTyp _ t)   = isFloat t
isFloat x               = x `elem` [F32, F64]

isArray (AnnoTyp _ t)   = isArray t
isArray (Array _ _)     = True
isArray _               = False

isTuple (AnnoTyp _ t)   = isTuple t 
isTuple (Tuple _ _)     = True
isTuple _               = False

isTable (AnnoTyp _ t)   = isTable t
isTable (Table _ _)     = True
isTable _               = False

isTypedef (Typedef _)   = True
isTypedef _             = False

isAnnoTyp (AnnoTyp _ _) = True
isAnnoTyp _             = False

isIntegral x            = isInt x || isChar x
isBase x                = isInt x || isFloat x || isChar x
isAggregate x           = isTuple x || isArray x || isTable x


valInt :: ValType -> Integer -> Value
valInt I8 n  = Val I8 (int8 n)
valInt I32 n = Val I32 (int32 n)
valInt I64 n = Val I64 (int64 n)


valBool :: Bool -> Value
valBool b = Val Bool (if b then bit 1 else bit 0)


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
    S.TTuple ts  -> Tuple Nothing (map fromASTType ts)
    S.TIdent sym -> Typedef sym
    S.TAnno s t  -> AnnoTyp s (fromASTType t)


opTypeOf :: ValType -> Instr Type
opTypeOf (Tuple nm ts) =
    if isNothing nm
    then fmap (StructureType False) (mapM opTypeOf ts)
    else do
        let name = fromJust nm
        ensureDef name
        return (NamedTypeReference name)
opTypeOf (Table nm ts) =
    if isNothing nm
    then do
        opTyps <- mapM (opTypeOf) ts
        return $ StructureType False $ i64:i64:(map ptr opTyps)
    else do
        let name = fromJust nm
        ensureDef name
        return (NamedTypeReference name)
opTypeOf (Typedef sym) = do
    res <- look sym KeyType
    case res of
        ObjType t   -> opTypeOf t
        ObjData t _ -> opTypeOf t
opTypeOf typ = case typ of
    Void        -> return VoidType
    I8          -> return i8
    I32         -> return i32
    I64         -> return i64
    F32         -> return (FloatingPointType HalfFP)
    F64         -> return (FloatingPointType DoubleFP)
    Bool        -> return i1
    Char        -> return i32
    String      -> return (ptr i8)
    Array n t   -> fmap (ArrayType $ fromIntegral n) (opTypeOf t)
    AnnoTyp _ t -> opTypeOf t


sizeOf :: Type -> Instr Word64
sizeOf typ =
    lift $ do
        dl <- gets dataLayout
        ctx <- gets context
        ptrTyp <- liftIO $ runEncodeAST ctx (encodeM typ)
        liftIO (FFI.getTypeAllocSize dl ptrTyp)


zeroOf :: ValType -> Instr C.Constant
zeroOf typ = case typ of
    I8          -> return $ toCons (int8 0)
    I32         -> return $ toCons (int32 0)
    I64         -> return $ toCons (int64 0)
    F32         -> return $ toCons (single 0)
    F64         -> return $ toCons (double 0)
    Char        -> return $ toCons (int32 0)
    Bool        -> return $ toCons (bit 0)
    String      -> return $ C.IntToPtr (toCons $ int64 0) (ptr i8)
    Array n t   -> fmap (toCons . array . replicate (fromIntegral n)) (zeroOf t)
    Table nm ts -> fmap (toCons . (struct Nothing False)) $ mapM zeroOf (I64:I64:ts)
    Tuple nm ts -> fmap (toCons . (struct Nothing False)) (mapM zeroOf ts)
    Typedef _   -> zeroOf =<< nakedTypeOf typ
    AnnoTyp _ t -> zeroOf t


nakedTypeOf :: ValType -> Instr ValType
nakedTypeOf typ = case typ of
    AnnoTyp _ t -> nakedTypeOf t
    Typedef sym -> do ObjType t <- look sym KeyType; nakedTypeOf t
    t           -> return t


concreteTypeOf :: ValType -> Instr ValType
concreteTypeOf (Typedef sym) = do
    res <- look sym KeyType
    case res of
        ObjType t   -> concreteTypeOf t
        ObjData _ _ -> return (dataConcTyp res)
concreteTypeOf typ = case typ of
    Table nm ts -> fmap (Table Nothing) (mapM concreteTypeOf ts)
    Tuple nm ts -> fmap (Tuple Nothing) (mapM concreteTypeOf ts)
    Array n t   -> fmap (Array n) (concreteTypeOf t)
    AnnoTyp _ t -> concreteTypeOf t
    t           -> return t


checkTypesMatch :: ValType -> ValType -> Instr ()
checkTypesMatch a b = do
    a' <- skipAnnos a
    b' <- skipAnnos b
    assert (a' == b') ("type mismatch between " ++ show a' ++ " and " ++ show b')


checkConcTypesMatch :: ValType -> ValType -> Instr ()
checkConcTypesMatch a b = do
    a' <- concreteTypeOf a
    b' <- concreteTypeOf b
    assert (a' == b') ("underlying type mismatch between " ++ show a' ++ " and " ++ show b')


skipAnnos :: ValType -> Instr ValType
skipAnnos typ = case typ of
    AnnoTyp _ t -> return t
    Typedef sym -> do ObjType t <- look sym KeyType; skipAnnos t
    Tuple nm ts -> fmap (Tuple nm) (mapM skipAnnos ts)
    Array n t   -> fmap (Array n) (skipAnnos t)
    t           -> return t


ensureTypeDeps :: ValType -> Instr ()
ensureTypeDeps (Array _ t)   = ensureTypeDeps t
ensureTypeDeps (Table nm ts) = do
    maybe (return ()) ensureDef nm
    mapM_ ensureTypeDeps ts
ensureTypeDeps (Tuple nm ts) = do
    maybe (return ()) ensureDef nm
    mapM_ ensureTypeDeps ts
ensureTypeDeps (Typedef sym) = do
    res <- look sym KeyType
    case res of
        ObjType t   -> ensureTypeDeps t
        ObjData t _ -> ensureTypeDeps t
ensureTypeDeps _ = return ()


valGlobal :: Name -> ValType -> Instr (Value, Definition)
valGlobal name typ = do
    opTyp <- opTypeOf typ
    zero <- zeroOf typ
    let (def, loc) = globalDef name opTyp (Just zero)
    let (ext, _) = globalDef name opTyp Nothing
    emitDefn def
    return (Ptr typ loc, ext)


valLocal :: ValType -> Instr Value
valLocal typ = do
    opTyp <- opTypeOf typ
    loc <- alloca opTyp Nothing 0
    return (Ptr typ loc)


valStore :: Value -> Value -> Instr ()
valStore (Ptr typ loc) val = do
    concA <- concreteTypeOf typ
    concB <- concreteTypeOf (valType val)
    assert (concA == concB) "underlying types don't match"
    case val of
        Ptr t l -> store loc 0 =<< load l 0
        Val t o -> store loc 0 o


valLoad :: Value -> Instr Value
valLoad (Val typ op)  = return (Val typ op)
valLoad (Ptr typ loc) = fmap (Val typ) (load loc 0)


valCast :: ValType -> Value -> Instr Value
valCast typ' (Ptr typ loc) = do
    opTyp' <- opTypeOf typ'
    loc' <- bitcast loc (ptr opTyp')
    return (Ptr typ' loc')
valCast typ' (Val typ op) = do
    opTyp' <- opTypeOf typ'
    op' <- bitcast op opTyp'
    return (Val typ' op')


valArrayIdx :: Value -> Value -> Instr Value
valArrayIdx (Ptr (Array n t) loc) idx = do
    assert (isInt $ valType idx) "array index isn't int"
    Val _ i <- valLoad idx
    ptr <- gep loc [int64 0, i]
    return (Ptr t ptr)


valArrayConstIdx :: Value -> Word64 -> Instr Value
valArrayConstIdx val i = do
    Array n t <- nakedTypeOf (valType val)
    case val of
        Ptr typ loc -> fmap (Ptr t) $ gep loc [int64 0, int64 (fromIntegral i)]
        Val typ op  -> fmap (Val t) $ extractValue op [fromIntegral i]


valArraySet :: Value -> Value -> Value -> Instr ()
valArraySet (Ptr typ loc) idx val = do
    Array n t <- nakedTypeOf typ
    assert (isInt $ valType idx) "index isn't int"
    assert (valType val == t) "incorrect element type"
    i <- valLoad idx
    ptr <- gep loc [int32 0, valOp i]
    valStore (Ptr t ptr) val


valLen :: Value -> Instr Word64
valLen val = do
    typ <- concreteTypeOf (valType val)
    case typ of
        Array n t   -> return n
        Tuple nm ts -> return $ fromIntegral (length ts)


valTupleIdx :: Word32 -> Value -> Instr Value
valTupleIdx i tup = do
    Tuple nm ts <- nakedTypeOf (valType tup)
    assert (i >= 0 && fromIntegral i < length ts) "tuple index out of range"
    let t = ts !! fromIntegral i
    case tup of
        Ptr _ loc -> fmap (Ptr t) (gep loc [int32 0, int32 (fromIntegral i)])
        Val _ op  -> fmap (Val t) (extractValue op [i])
    

valTupleSet :: Value -> Word32 -> Value -> Instr ()
valTupleSet (Ptr typ loc) i val = do
    Tuple nm ts <- nakedTypeOf typ
    ptr <- gep loc [int32 0, int32 (fromIntegral i)]
    valStore (Ptr (ts !! fromIntegral i) ptr) val


valsEqual :: Value -> Value -> Instr Value
valsEqual a b = do
    typA <- skipAnnos (valType a)
    typB <- skipAnnos (valType b)
    assert (typA == typB) ("equality: type mismatch between " ++ show typA ++ " and " ++ show typB)
    typ <- concreteTypeOf (valType a)
    fmap (Val Bool) $ valsEqual' typ a b
    where
        valsEqual' :: ValType -> Value -> Value -> Instr Operand
        valsEqual' typ a b
            | isIntegral typ || typ == Bool = do
                Val _ opA <- valLoad a
                Val _ opB <- valLoad b
                icmp EQ opA opB

        valsEqual' typ a b = error $ show (typ, a, b)


valAnd :: [Value] -> Instr Value
valAnd [val] = do
    assert (valType val == Bool) "non-bool in and expression"
    valLoad val
valAnd (v:vs) = do
    Val Bool op  <- valAnd [v]
    Val Bool ops <- valAnd vs
    fmap (Val Bool) (and ops op)



valTablePrint :: String -> Value -> Instr ()
valTablePrint append val = do
    Table nm ts <- nakedTypeOf (valType val)
    printf "{" []
    Val _ struct <- valLoad val
    len <- extractValue struct [0]
    forM_ (zip ts [0..]) $ \(typ, i) -> do
        pi8 <- extractValue struct [2+i]
        opTyp <- opTypeOf typ
        pArr <- bitcast pi8 (ptr opTyp)
        lenm1 <- sub len (int64 1)
        for lenm1 $ \j -> do
            pElem <- gep pArr [j]
            valPrint ", " (Ptr typ pElem)

        pElem <- gep pArr [lenm1]
        valPrint "; " (Ptr typ pElem)

    printf ("}" ++ append) []
    return ()


valPrint :: String -> Value -> Instr ()
valPrint append val
    | isAnnoTyp (valType val) = do
        let AnnoTyp s t = valType val
        printf (s ++ "=") []
        valPrint append (val{ valType = t })

    | valType val == Bool = do
        Val Bool op <- valLoad val
        str <- globalStringPtr "true\0false" =<< fresh
        idx <- select op (int64 0) (int64 5)
        ptr <- gep (cons str) [idx]
        void $ printf ("%s" ++ append) [ptr]

    | isArray (valType val) = do
        len <- valLen val
        putchar '['
        for (int64 $ fromIntegral len-1) $ \i -> do
            valPrint ", " =<< valArrayIdx val (Val I64 i)
        valPrint ("]" ++ append) =<< valArrayConstIdx val (len-1)

    | isTuple (valType val) = do
        len <- valLen val 
        putchar '('
        forM_ [0..len-1] $ \i -> do
            let app = if i < len-1 then ", " else ")" ++ append
            valPrint app =<< valTupleIdx (fromIntegral i) val

    | isTable (valType val) =
        valTablePrint append val

    | isTypedef (valType val) = do
        let Typedef symbol = valType val
        obj <- look symbol KeyType
        case obj of
            ObjType typ -> do
                void $ printf symbol []
                conc <- concreteTypeOf typ

                if isTuple conc then do
                    tup@(Tuple nm ts) <- nakedTypeOf typ
                    valPrint append (val { valType = tup })
                else do
                    void $ printf (symbol ++ "(") []
                    valPrint (")" ++ append) (val { valType = conc })

            ObjData t f -> do
                f val
                void (printf append [])

    | otherwise = do
        Val typ op <- valLoad val
        void $ case typ of
            I8     -> printf ("%d" ++ append) [op]
            I32    -> printf ("%d" ++ append) [op]
            I64    -> printf ("%ld" ++ append) [op]
            F32    -> printf ("%f" ++ append) [op]
            F64    -> printf ("%f" ++ append) [op]
            Char   -> printf ("%c" ++ append) [op]
            String -> printf ("\"%s\"" ++ append) [op]
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
    addAction name $ emitDefn $ funcDef name (zip paramOpTyps paramNames) retOpTyp []


