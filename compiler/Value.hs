{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
module Value where

import Prelude hiding (or, and)
import GHC.Float
import Data.Maybe
import Data.List hiding (or, and)
import Control.Monad
import Control.Monad.State hiding (void)
import Control.Monad.Trans

import qualified LLVM.AST as LL
import qualified LLVM.AST.Type as LL
import LLVM.Internal.EncodeAST
import LLVM.Internal.Coding hiding (alloca)
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Instruction
import qualified LLVM.Internal.FFI.DataLayout as FFI
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as P
import qualified LLVM.AST.FloatingPointPredicate as P

import qualified AST as S
import Monad
import State
import Funcs
import Type
import Typeof
import Trace


valResolveContextual :: InsCmp CompileState m => Value -> m Value
valResolveContextual val = trace "valResolveContextual" $ case val of
    Exp (S.Int p n)   -> valInt I64 n
    Exp (S.Float p f) -> valFloat F64 f
    Exp (S.Null p)    -> zeroOf $ ADT [("", Void)]
    Ptr _ _           -> return val
    Val _ _           -> return val
    _                 -> error ("can't resolve contextual: " ++ show val)

valLoad :: InsCmp s m => Value -> m Value
valLoad (Val typ op)  = trace "valLoad" $ return (Val typ op)
valLoad (Ptr typ loc) = trace "valLoad" $ Val typ <$> load loc 0


valStore :: InsCmp CompileState m => Value -> Value -> m ()
valStore (Ptr typ loc) val = trace traceMsg $ do
    case val of
        Ptr t l -> store loc 0 =<< load l 0
        Val t o -> store loc 0 o
    where
        traceMsg = "valStore " ++ show typ


valSelect :: InsCmp CompileState m => Value -> Value -> Value -> m Value
valSelect cnd t f = trace "valSelect" $ do
    assertBaseType (==Bool) (valType cnd)
    assert (valType t == valType f) "Types do not match"
    return . Val (valType t) =<< select (valOp cnd) (valOp t) (valOp f)


valLocal :: InsCmp CompileState m => Type -> m Value
valLocal typ = trace ("valLocal " ++ show typ) $ do
    opTyp <- opTypeOf typ
    Ptr typ <$> alloca opTyp Nothing 0
    

valMalloc :: InsCmp CompileState m => Type -> Value -> m Value
valMalloc typ len = trace ("valMalloc " ++ show typ) $ do
    lenTyp <- assertBaseType isInt (valType len)
    pi8 <- malloc =<< mul (valOp len) . valOp =<< sizeOf typ
    Ptr typ <$> (bitcast pi8 . LL.ptr =<< opTypeOf typ)


valsInfix :: InsCmp CompileState m => S.Op -> Value -> Value -> m Value
valsInfix operator a b = trace ("valsInfix " ++ show operator) $ case (a, b) of
    (Exp _, Exp _) -> return $ Exp $ exprInfix operator (let Exp ea = a in ea) (let Exp eb = b in eb)

    (Exp (S.Int _ i), _) -> do
        assertBaseType isInt (valType b)
        val <- valInt (valType b) i
        valsInfix operator val b

    (_, Exp (S.Int _ i)) -> do
        assertBaseType isInt (valType a)
        val <- valInt (valType a) i
        valsInfix operator a val

    (_, Exp _) -> err ""

    (Exp _, _) -> err ""

    _ -> do
        Val _ opA <- valLoad a
        Val _ opB <- valLoad b

        resm <- lookm (show operator) $ KeyFunc [valType a, valType b]
        case resm of
            Just (ObjFunc retty op) -> Val retty <$> call op [ (opA, []), (opB, []) ]
            Nothing                 -> do
                baseA <- baseTypeOf (valType a)
                baseB <- baseTypeOf (valType b)
                assert (baseA == baseB) "Base types do not match"

                case baseA of
                    Bool              -> boolInfix (valType a) operator opA opB
                    Char              -> intInfix (valType a) operator opA opB
                    _ | isInt baseA   -> intInfix (valType a) operator opA opB
                    _ | isFloat baseA -> floatInfix (valType a) operator opA opB
                    _                 -> err ("Operator " ++ show operator ++ " undefined for types")

    where 
        exprInfix operator exprA exprB = case (operator, exprA, exprB) of
            (S.Plus, S.Int p a, S.Int _ b) -> S.Int p (a + b)

        boolInfix :: InsCmp CompileState m => Type -> S.Op -> LL.Operand -> LL.Operand -> m Value
        boolInfix typ operator opA opB = case operator of
            S.OrOr   -> Val typ <$> or opA opB
            S.AndAnd -> Val typ <$> and opA opB
            _        -> error ("bool infix: " ++ show operator)
        
        intInfix :: InsCmp CompileState m => Type -> S.Op -> LL.Operand -> LL.Operand -> m Value
        intInfix typ operator opA opB = case operator of
            S.Plus   -> Val typ  <$> add opA opB
            S.Minus  -> Val typ  <$> sub opA opB
            S.Times  -> Val typ  <$> mul opA opB
            S.Divide -> Val typ  <$> sdiv opA opB
            S.GT     -> Val Bool <$> icmp P.SGT opA opB
            S.LT     -> Val Bool <$> icmp P.SLT opA opB
            S.GTEq   -> Val Bool <$> icmp P.SGE opA opB
            S.LTEq   -> Val Bool <$> icmp P.SLE opA opB
            S.EqEq   -> Val Bool <$> icmp P.EQ opA opB
            S.NotEq  -> Val Bool <$> icmp P.NE opA opB
            S.Modulo -> Val typ  <$> srem opA opB
            _        -> error ("int infix: " ++ show operator)

        floatInfix :: InsCmp CompileState m => Type -> S.Op -> LL.Operand -> LL.Operand -> m Value
        floatInfix typ operator opA opB = case operator of
            S.Plus   -> Val typ <$> fadd opA opB
            S.Minus  -> Val typ <$> fsub opA opB
            S.Times  -> Val typ <$> fmul opA opB
            S.Divide -> Val typ <$> fdiv opA opB
            S.EqEq   -> Val Bool <$> fcmp P.OEQ opA opB
            _        -> error ("float infix: " ++ show operator)
        

valNot :: InsCmp CompileState m => Value -> m Value
valNot val = trace "valNot" $ do
    assertBaseType (== Bool) (valType val)
    Val (valType val) <$> (icmp P.EQ (bit 0) . valOp =<< valLoad val)


valPtrIdx :: InsCmp s m => Value -> Value -> m Value
valPtrIdx (Ptr typ loc) idx = trace "valPtrIdx" $ do
    Val I64 i <- valLoad idx
    Ptr typ <$> gep loc [i]


valArrayIdx :: InsCmp CompileState m => Value -> Value -> m Value
valArrayIdx (Ptr (Array n t) loc) idx = trace "valArrayIdx" $ do
    Val idxTyp idx <- valLoad idx
    assert (isInt idxTyp) "array index isn't an integer"
    Ptr t <$> gep loc [int64 0, idx]


valArrayConstIdx :: InsCmp CompileState m => Value -> Int -> m Value
valArrayConstIdx val i = trace "valArrayConstIdx" $ do
    assert (not $ valIsContextual val) "contextual 172"
    Array n t <- assertBaseType isArray (valType val)
    case val of
        Ptr _ loc -> Ptr t <$> gep loc [int64 0, int64 (fromIntegral i)]
        Val _ op  -> Val t <$> extractValue op [fromIntegral i]


valMemCpy :: InsCmp CompileState m => Value -> Value -> Value -> m ()
valMemCpy (Ptr dstTyp dst) (Ptr srcTyp src) len = trace "valMemCpy" $ do
    assert (dstTyp == srcTyp) "Types do not match"
    assertBaseType isInt (valType len)

    pDstI8 <- bitcast dst (LL.ptr LL.i8)
    pSrcI8 <- bitcast src (LL.ptr LL.i8)

    sz <- sizeOf dstTyp
    let sz' = trace (show $ valOp sz) sz

    void $ memcpy pDstI8 pSrcI8 . valOp =<< valsInfix S.Times len sz'


