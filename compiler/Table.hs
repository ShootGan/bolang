{-# LANGUAGE FlexibleContexts #-}
module Table where

import Control.Monad

import qualified LLVM.AST.Type as LL
import LLVM.IRBuilder.Constant
import LLVM.IRBuilder.Instruction

import qualified AST as S
import Monad
import Value
import State
import Funcs
import Type 
import Tuple
import Typeof
import Trace



tableLen :: InsCmp CompileState m => Value -> m Value
tableLen tab = trace "tableLen" $ do
    Table _ <- assertBaseType isTable (valType tab)
    op <- valOp <$> valLoad tab
    Val I64 <$> extractValue op [0]


tableCap :: InsCmp CompileState m => Value -> m Value
tableCap tab = trace "tableCap" $ do
    Table _ <- assertBaseType isTable (valType tab)
    op <- valOp <$> valLoad tab
    Val I64 <$> extractValue op [1]


tableSetLen :: InsCmp CompileState m => Value -> Value -> m ()
tableSetLen tab@(Ptr _ loc) len = trace "tableSetLen" $ do
    Table _ <- assertBaseType isTable (valType tab)
    assertBaseType isInt (valType len)
    l <- gep loc [int32 0, int32 0]
    store l 0 =<< (valOp <$> valLoad len)


tableSetCap :: InsCmp CompileState m => Value -> Value -> m ()
tableSetCap tab@(Ptr _ loc) cap = trace "tableSetCap" $ do
    Table _ <- assertBaseType isTable (valType tab)
    assertBaseType isInt (valType cap)
    c <- gep loc [int32 0, int32 1]
    store c 0 =<< (valOp <$> valLoad cap)


tableRow :: InsCmp CompileState m => Int -> Value -> m Value
tableRow i tab = do
    Table ts <- assertBaseType isTable (valType tab)
    assert (i >= 0 && i < length ts) "Invalid table row index"
    case tab of
        Val _ op  -> Ptr (ts !! i) <$> extractValue op [fromIntegral i + 2]
        Ptr _ loc -> do
            r <- gep loc [int32 0, int32 (fromIntegral i + 2)]
            Ptr (ts !! i) <$> load r 0
    

tableSetRow :: InsCmp CompileState m => Value -> Int -> Value -> m ()
tableSetRow tab i row = trace "tableSetRow" $ do
    Table ts <- assertBaseType isTable (valType tab)
    assert (valType row == ts !! i) "Types do not match"
    pp <- gep (valLoc tab) [int32 0, int32 (fromIntegral i+2)]
    store pp 0 (valLoc row)


tableGetElem :: InsCmp CompileState m => Value -> Value -> m Value
tableGetElem tab idx = trace "tableGetElem" $ do
    Table ts <- assertBaseType isTable (valType tab)

    tup <- valLocal $ Tuple [ ("", t) | t <- ts ]
    forM_ (zip ts [0..]) $ \(t, i) -> do
        row <- tableRow i tab
        tupleSet tup i =<< valPtrIdx row idx

    return tup


tableSetElem :: InsCmp CompileState m => Value -> Value -> Value -> m ()
tableSetElem tab idx tup = trace "tableSetElem" $ do
    Table ts <- assertBaseType isTable (valType tab)
    Tuple xs <- assertBaseType isTuple (valType tup)
    idxType  <- assertBaseType isInt (valType idx)

    -- check types match
    assert (length ts == length xs) "tuple type does not match table column"
    assert (ts == map snd xs) "Types do not match"

    forM_ (zip ts [0..]) $ \(t, i) -> do
        row <- tableRow i tab
        ptr <- valPtrIdx row idx
        valStore ptr =<< tupleIdx i tup


tableRange :: InsCmp CompileState m => Value -> Value -> Value -> m Value
tableRange tab start end = trace "tableRange" $ do
    Table ts <- baseTypeOf (valType tab)

    assertBaseType isInt (valType start)
    assertBaseType isInt (valType end)

    len <- tableLen tab
    cap <- tableCap tab

    startLoc <- valLocal (valType start)
    endLoc   <- valLocal (valType end)

    startLT0 <- valsInfix S.LT start (valI64 0)
    if_ (valOp startLT0)
        (valStore startLoc (valI64 0))
        (valStore startLoc start)

    endGT <- valsInfix S.GT end len
    if_ (valOp endGT)
        (valStore endLoc len)
        (valStore endLoc end)

    startGT <- valsInfix S.GT startLoc len
    if_ (valOp startGT)
        (valStore startLoc len)
        (return ())

    crossed <- valsInfix S.GT startLoc endLoc
    if_ (valOp crossed)
        (valStore endLoc startLoc)
        (return ())
    
    loc <- valLocal (valType tab)
    tableSetLen loc =<< valsInfix S.Minus endLoc startLoc
    tableSetCap loc =<< valsInfix S.Minus cap startLoc

    forM_ (zip ts [0..]) $ \(t, i) -> do
        row <- tableRow i tab 
        tableSetRow loc i =<< valPtrIdx row startLoc

    return loc


tableAppendElem :: InsCmp CompileState m => Value -> Value -> m Value
tableAppendElem tab val = trace "tableAppendElem" $ do
    err "TODO"
--    
--    Table ts <- assertBaseType isTable (valType tab)
--    assert (length ts == 1) "Can only append to tables with one row"
--    let [t] = ts
--    
--    baseT <- baseTypeOf t
--    baseV <- baseTypeOf (valType val)
--    assert (baseT == baseV) "Types do not match."
--
--    loc <- valLocal (valType tab)
--    valStore loc tab
--
--    len <- tableLen loc
--    cap <- tableCap loc
--    newLen <- valsInfix S.Plus len (valI64 1) 
--
--
--    bFull <- valsInfix S.GT newLen cap
--    if_ (valOp bFull) (fullCase loc newLen t) (return ())
--
--    tup <- valLocal (Tuple [("", t)])
--    tupleSet tup 0 val
--    tableSetElem loc len tup
--    valLoad loc
--    where
--        fullCase loc newLen t = do
--            tableSetCap loc =<< valsInfix S.Times newLen (valI64 2)
--            mal <- valMalloc t =<< tableCap loc
--            row <- tableRow 0 loc
--            valMemCpy mal row =<< tableLen loc
--            tableSetRow loc 0 mal



tableAppend :: InsCmp CompileState m => Value -> Value -> m Value
tableAppend a b = trace "tableAppend" $ do
    Table ts <- assertBaseType isTable (valType a)
    assertBaseType isTable (valType b)

    assert (valType a == valType b) "Types do not match."

    loc <- valLocal (valType a)
    valStore loc a

    aLen <- tableLen a
    bLen <- tableLen b
    newLen <- valsInfix S.Plus aLen bLen
    tableSetLen loc newLen

    bFull <- valsInfix S.GT newLen =<< tableCap loc
    if_ (valOp bFull) (fullCase loc newLen ts aLen) (return ())

    -- copy b into loc
    forM_ (zip ts [0..]) $ \(t, i) -> do
        row <- tableRow i loc
        dst <- valPtrIdx row aLen 
        src <- tableRow i b
        valMemCpy dst src bLen

    return loc
    where
        fullCase loc newLen ts aLen = do
            tableSetCap loc =<< valsInfix S.Times newLen (valI64 2)
            forM_ (zip ts [0..]) $ \(t, i) -> do
                tableSetRow loc i =<< valMalloc t =<< tableCap loc
                dst <- tableRow i loc
                src <- tableRow i a
                valMemCpy dst src aLen
