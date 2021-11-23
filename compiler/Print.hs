{-# LANGUAGE FlexibleContexts #-}
module Print where

import Control.Monad

import LLVM.IRBuilder.Monad
import LLVM.IRBuilder.Instruction
import LLVM.IRBuilder.Constant
import qualified LLVM.AST.Type as LL

import qualified AST as S
import Value
import State
import Monad
import Funcs
import Table
import Tuple
import Type 
import ADT


valPrint :: InsCmp CompileState m => String -> Value -> m ()
valPrint append val = case valType val of
    t | isInt t   -> void . printf ("%ld" ++ append) . (:[]) . valOp =<< valLoad val
    t | isFloat t -> void . printf ("%f" ++ append) . (:[]) . valOp =<< valLoad val
    Char          -> void . printf ("%c" ++ append) . (:[]) . valOp =<< valLoad val

    Bool -> do
        op <- valOp <$> valLoad val
        str <- globalStringPtr "true\0false" =<< fresh
        void . printf ("%s" ++ append) . (:[]) =<< gep (cons str) . (:[]) =<< select op (int64 0) (int64 5)

    Typedef s -> do
        printf (s ++ "(") []
        base <- baseTypeOf (valType val)
        case val of
            Ptr t loc -> valPrint (")" ++ append) (Ptr base loc)
            Val t op  -> valPrint (")" ++ append) (Val base op)

    typ@(ADT [(s, t)]) -> do
        if s /= ""
        then void $ printf (s ++ "(") []
        else void $ printf (show typ ++ "(") []
        valPrint (")" ++ append) =<< adtDeref val

    ADT xs -> do
        en <- adtEnum val
        valPrint append en

    Tuple xs -> do
        printf "(" []
        forM_ (zip xs [0..]) $ \((s, t), i) -> do
            let app = if i < length xs - 1 then ", " else ""
            valPrint app =<< tupleIdx i val
        void $ printf (")" ++ append) []

    Table [Char] -> do
        row <- tableRow 0 val
        len <- tableLen val
        void $ printf ("%-.*s" ++ append) [valOp len, valLoc row]

    Table ts -> do
        return ()
        printf "[" []
        let nrows = (length ts)
        len <- tableLen val
        lenZero <- valsInfix S.LTEq len (valI64 0)

        if_ (valOp lenZero)
            (void $ printf ("]" ++ append) [])
            (tablePrintHelper ts val len)

    Array n t -> do
        printf "[%d| " $ (:[]) $ valOp (valI64 n)
        for (int64 $ fromIntegral n-1) $ \i ->
            valPrint ", " =<< valArrayIdx val (Val I64 i)
        valPrint ("]" ++ append) =<< valArrayConstIdx val (n-1)

    _ -> error ("print: " ++ show (valType val))
    where
        tablePrintHelper ts val len = forM_ [0..length ts - 1] $ \i -> do
            row <- tableRow i val
            n <- valsInfix S.Minus len =<< valInt I64 1
            for (valOp n) $ \j -> valPrint ", " =<< valPtrIdx row (Val I64 j)
            if i < length ts - 1
            then valPrint "; " =<< valPtrIdx row n
            else valPrint ("]" ++ append) =<< valPtrIdx row n