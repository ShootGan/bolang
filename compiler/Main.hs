module Main where

import System.Environment
import System.IO
import System.Console.Haskeline
import Control.Monad
import Data.List.Split
import Control.Monad.Trans
import Control.Monad.Except
import qualified Data.Map as Map
import qualified Data.Set as Set

import JIT
import Error
import Modules
import Monad
import Args
import AST
import qualified Parser as P
import qualified Lexer as L


main :: IO ()
main = do
    args <- getArgs
    let parsedArgs = parseArgs initArgs args
    if args == [] then do
        putStrLn "==== Bolang REPL ===="
        withSession True $ \session -> do
            runInputT defaultSettings (repl session)
    else if lexOnly parsedArgs then do
        withSession (optimise parsedArgs) $ \session -> do
            forM_ (modPaths parsedArgs) $ \path -> do
                res <- runBoMT (initModulesState session) (lexFile 0 path)
                case res of
                    Left err     -> printError err 
                    Right (r, _) -> mapM_ (putStrLn . show) r
    else do
        withSession (optimise parsedArgs) $ \session -> do
            forM_ (modPaths parsedArgs) $ \path -> do
                res <- runBoMT (initModulesState session) $ runMod parsedArgs Set.empty (splitOn "/" path)
                case res of
                    Left err -> printError err 
                    Right _  -> return ()


repl :: Session -> InputT IO ()
repl session = do
    minput <- handleInterrupt (return $ Just "Ctrl-C exit") $ getInputLine "8===D "
    case minput of
        Just "q"  -> return ()
        Just line -> do
            res <- runExceptT (P.parse 0 line)
            case res of
                Left e -> lift (printError e)
                Right a -> lift (prettyAST "" a)

            repl session
