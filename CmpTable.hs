module CmpTable where

import           Control.Monad
import           Data.List

import           LLVM.AST.Type
import           LLVM.IRBuilder.Constant
import           LLVM.IRBuilder.Instruction
import           LLVM.IRBuilder.Module
import           LLVM.IRBuilder.Monad

import           CmpFuncs
import           CmpValue
import           CmpMonad


cmpTableExpr :: [[Value]] -> Instr Value
cmpTableExpr rows = do
    let numRows = length rows
    assert (numRows > 0) "cannot deduce table type"
    let numCols = length (head rows)
    assert (all (== numCols) (map length rows)) "row lengths differ" 
    assert (numCols > 0) "cannot deduce table type"

    (rowTyps, rowOpTyps, rowTypSizes) <- fmap unzip3 $ forM rows $ \row -> do
        let typ = valType (head row)
        assert (all (== typ) (map valType row)) "element types differ in row"
        opTyp <- opTypeOf typ
        size <- sizeOf opTyp
        return (typ, opTyp, size)

    typName <- freshName (mkBSS "table_t")
    let typ = Table (Just typName) rowTyps
    opTyp <- opTypeOf (Table Nothing rowTyps)
    addAction typName $ typedef typName (Just opTyp)
    ensureDef typName

    let len = numCols
    let cap = len

    val@(Ptr (Table _ _) loc) <- valLocal typ
    lenPtr <- gep loc [int32 0, int32 0]
    store lenPtr 0 (int32 $ fromIntegral len)
    capPtr <- gep loc [int32 0, int32 1]
    store capPtr 0 (int32 $ fromIntegral cap)

    forM_ (zip4 rows rowOpTyps rowTypSizes [0..]) $ \(row, rowOpTyp, size, i) -> do
        rowPtr <- gep loc [int32 0, int32 (i+2)]
        pi8 <- malloc $ int64 (fromIntegral cap * fromIntegral size)
        pMem <- bitcast pi8 (ptr rowOpTyp)
        store rowPtr 0 pMem
        forM_ (zip row [0..]) $ \(val, j) -> do
            rowPtrVal <- load rowPtr 0
            pi8 <- gep rowPtrVal [int64 j]
            opTyp <- opTypeOf (valType val)
            elemPtr <- bitcast pi8 (ptr opTyp)
            valStore (Ptr (valType val) elemPtr) val
            
    valLoad val


