{-# LANGUAGE FlexibleContexts #-}
module Table where

import Data.Word
import Control.Monad

import qualified LLVM.AST.Type as LL
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Instruction

import qualified AST as S
import Monad
import Value
import CompileState
import Funcs
import Type 


valTableLen :: InsCmp CompileState m => Value -> m Value
valTableLen tab = do
    Table _ <- baseTypeOf (valType tab)
    case tab of
        Ptr _ loc -> fmap (Ptr I64) $ gep loc [int32 0, int32 0]
        Val _ op  -> fmap (Val I64) $ extractValue op [0]


valTableCap :: InsCmp CompileState m => Value -> m Value
valTableCap tab = do
    Table _ <- baseTypeOf (valType tab)
    case tab of
        Ptr _ loc -> fmap (Ptr I64) $ gep loc [int32 0, int32 1]
        Val _ op  -> fmap (Val I64) $ extractValue op [1]


valTableRow :: InsCmp CompileState m => Word32 -> Value -> m Value
valTableRow i tab = do
    Table ts <- baseTypeOf (valType tab)
    assert (fromIntegral i < length ts) "table row index >= num rows"
    let t = ts !! fromIntegral i
    case tab of
        Val _ op  -> fmap (Ptr t) (extractValue op [i+2])
        Ptr _ loc -> do
            pp <- gep loc [int32 0, int32 $ fromIntegral i+2]
            fmap (Ptr t) (load pp 0)


valTableSetRow :: InsCmp CompileState m => Value -> Word32 -> Value -> m ()
valTableSetRow tab i row = do
    Table ts <- baseTypeOf (valType tab)
    checkTypesMatch (valType row) (ts !! fromIntegral i)
    pp <- gep (valLoc tab) [int32 0, int32 $ fromIntegral i+2]
    store pp 0 (valLoc row)


valMalloc :: InsCmp CompileState m => Type -> Value -> m Value
valMalloc typ len = do
    size <- fmap (valInt I64 . fromIntegral) (sizeOf typ)
    num  <- valsInfix S.Times len size
    pi8  <- malloc (valOp num)
    opTyp <- opTypeOf typ
    fmap (Ptr typ) $ bitcast pi8 (LL.ptr opTyp)


valTableForceAlloc :: InsCmp CompileState m => Value -> m Value
valTableForceAlloc tab@(Ptr typ _) = valTableForceAlloc' tab
valTableForceAlloc tab@(Val typ _) = do
    tab' <- valLocal typ
    valStore tab' tab
    valTableForceAlloc' tab'

valTableForceAlloc' tab@(Ptr _ _) = do
    Table ts <- baseTypeOf (valType tab)
    len <- valTableLen tab
    cap <- valTableCap tab
    
    let caseCapZero = do
        valStore cap len
        forM_ (zip ts [0..]) $ \(t, i) -> do
            mem <- valMalloc t len
            row <- valTableRow i tab
            valMemCpy mem row len
            valTableSetRow tab i mem

    z <- valsInfix S.LTEq cap (valI64 0)
    if_ (valOp z) caseCapZero (return ())
    return tab



valTableGetElem :: InsCmp CompileState m => Value -> Value -> m Value
valTableGetElem tab idx = do
    Table ts <- baseTypeOf (valType tab)

    tup <- valLocal (Tuple ts)
    forM_ (zip ts [0..]) $ \(t, i) -> do
        row <- valTableRow i tab
        ptr <- valPtrIdx row idx
        valTupleSet tup (fromIntegral i) ptr

    return tup


valTableSetElem :: InsCmp CompileState m => Value -> Value -> Value -> m ()
valTableSetElem tab idx tup = do
    Table ts  <- baseTypeOf (valType tab)
    Tuple ts' <- baseTypeOf (valType tup)
    idxType     <- baseTypeOf (valType idx)

    -- check types match
    assert (isInt idxType) "index is not an integer type"
    assert (length ts == length ts') "tuple type does not match table column"
    zipWithM_ checkTypesMatch ts ts'

    forM_ (zip ts [0..]) $ \(t, i) -> do
        row <- valTableRow i tab
        ptr <- valPtrIdx row idx
        valStore ptr =<< valTupleIdx tup (fromIntegral i)



valTableAppend :: InsCmp CompileState m => Value -> Value -> m Value
valTableAppend tab tup = do
    Table ts  <- baseTypeOf (valType tab)
    Tuple ts' <- baseTypeOf (valType tup)

    -- check types match
    assert (length ts == length ts') "tuple type does not match table column"
    zipWithM_ checkTypesMatch ts ts'

    -- create local table
    loc <- valLocal (valType tab)
    valStore loc tab

    cap <- valTableCap loc
    len <- valTableLen loc

    capZero <- valsInfix S.LTEq cap (valI64 0)
    lenZero <- valsInfix S.LTEq len (valI64 0)
    empty   <- valsInfix S.AndAnd lenZero capZero
    full    <- valsInfix S.LTEq cap len

    let emptyCase = do
        valStore cap (valI64 16)
        forM_ (zip ts [0..]) $ \(t, i) ->
            valTableSetRow loc i =<< valMalloc t cap
    
    let fullCase = do
        valStore cap =<< valsInfix S.Times len (valI64 2)
        forM_ (zip ts [0..]) $ \(t, i) -> do
            mal <- valMalloc t cap
            row <- valTableRow i loc
            valMemCpy mal row len
            valTableSetRow loc i mal

    switch_ [
        (return (valOp empty), emptyCase),
        (return (valOp full), fullCase)
        ]

    valTableSetElem loc len tup
    valStore len =<< valsInfix S.Plus len (valI64 1)
    return loc
