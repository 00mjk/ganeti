{-| Cluster rebalancer

-}

{-

Copyright (C) 2009 Google Inc.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.

-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Data.List
import Data.Function
import Data.Maybe (isJust, fromJust)
import Monad
import System
import System.IO
import qualified System

import Text.Printf (printf, hPrintf)
import Text.JSON (showJSON)

import qualified Ganeti.HTools.Container as Container
import qualified Ganeti.HTools.Cluster as Cluster
import qualified Ganeti.HTools.Node as Node
import qualified Ganeti.HTools.Instance as Instance

import Ganeti.HTools.CLI
import Ganeti.HTools.ExtLoader
import Ganeti.HTools.Utils
import Ganeti.HTools.Types

import qualified Ganeti.Luxi as L
import qualified Ganeti.OpCodes as OpCodes
import Ganeti.Jobs

-- | Options list and functions
options :: [OptType]
options =
    [ oPrintNodes
    , oPrintInsts
    , oPrintCommands
    , oOneline
    , oDataFile
    , oRapiMaster
    , oLuxiSocket
    , oExecJobs
    , oMaxSolLength
    , oVerbose
    , oQuiet
    , oOfflineNode
    , oMinScore
    , oMaxCpu
    , oMinDisk
    , oDiskMoves
    , oDynuFile
    , oExTags
    , oShowVer
    , oShowHelp
    ]

{- | Start computing the solution at the given depth and recurse until
we find a valid solution or we exceed the maximum depth.

-}
iterateDepth :: Cluster.Table    -- ^ The starting table
             -> Int              -- ^ Remaining length
             -> Bool             -- ^ Allow disk moves
             -> Int              -- ^ Max node name len
             -> Int              -- ^ Max instance name len
             -> [MoveJob]        -- ^ Current command list
             -> Bool             -- ^ Whether to be silent
             -> Score            -- ^ Score at which to stop
             -> IO (Cluster.Table, [MoveJob]) -- ^ The resulting table
                                              -- and commands
iterateDepth ini_tbl max_rounds disk_moves nmlen imlen
             cmd_strs oneline min_score =
    let Cluster.Table ini_nl ini_il _ _ = ini_tbl
        allowed_next = Cluster.doNextBalance ini_tbl max_rounds min_score
        m_fin_tbl = if allowed_next
                    then Cluster.tryBalance ini_tbl disk_moves
                    else Nothing
    in
      case m_fin_tbl of
        Just fin_tbl ->
            do
              let
                  (Cluster.Table _ _ _ fin_plc) = fin_tbl
                  fin_plc_len = length fin_plc
                  cur_plc@(idx, _, _, move, _) = head fin_plc
                  (sol_line, cmds) = Cluster.printSolutionLine ini_nl ini_il
                                     nmlen imlen cur_plc fin_plc_len
                  afn = Cluster.involvedNodes ini_il cur_plc
                  upd_cmd_strs = (afn, idx, move, cmds):cmd_strs
              unless oneline $ do
                       putStrLn sol_line
                       hFlush stdout
              iterateDepth fin_tbl max_rounds disk_moves
                           nmlen imlen upd_cmd_strs oneline min_score
        Nothing -> return (ini_tbl, cmd_strs)

-- | Formats the solution for the oneline display
formatOneline :: Double -> Int -> Double -> String
formatOneline ini_cv plc_len fin_cv =
    printf "%.8f %d %.8f %8.3f" ini_cv plc_len fin_cv
               (if fin_cv == 0 then 1 else ini_cv / fin_cv)

-- | Submits a list of jobs and waits for all to finish execution
execJobs :: L.Client -> [[OpCodes.OpCode]] -> IO (Result [String])
execJobs client = L.submitManyJobs client . showJSON

-- | Polls a set of jobs at a fixed interval until all are finished
-- one way or another
waitForJobs :: L.Client -> [String] -> IO (Result [JobStatus])
waitForJobs client jids = do
  sts <- L.queryJobsStatus client jids
  case sts of
    Bad x -> return $ Bad x
    Ok s -> if any (<= JobRunning) s
            then do
              -- TODO: replace hardcoded value with a better thing
              threadDelay (1000000 * 15)
              waitForJobs client jids
            else return $ Ok s

-- | Check that a set of job statuses is all success
checkJobsStatus :: [JobStatus] -> Bool
checkJobsStatus = all (== JobSuccess)

-- | Execute an entire jobset
execJobSet :: String -> String -> Node.List
           -> Instance.List -> [JobSet] -> IO ()
execJobSet _      _   _  _  [] = return ()
execJobSet master csf nl il (js:jss) = do
  -- map from jobset (htools list of positions) to [[opcodes]]
  let jobs = map (\(_, idx, move, _) ->
                      Cluster.iMoveToJob csf nl il idx move) js
  let descr = map (\(_, idx, _, _) -> Container.nameOf il idx) js
  putStrLn $ "Executing jobset for instances " ++ commaJoin descr
  jrs <- bracket (L.getClient master) L.closeClient
         (\client -> do
            jids <- execJobs client jobs
            case jids of
              Bad x -> return $ Bad x
              Ok x -> do
                putStrLn $ "Got job IDs " ++ commaJoin x
                waitForJobs client x
         )
  (case jrs of
     Bad x -> do
       hPutStrLn stderr $ "Cannot compute job status, aborting: " ++ show x
       return ()
     Ok x -> if checkJobsStatus x
             then execJobSet master csf nl il jss
             else do
               hPutStrLn stderr $ "Not all jobs completed successfully: " ++
                         show x
               hPutStrLn stderr "Aborting.")

-- | Main function.
main :: IO ()
main = do
  cmd_args <- System.getArgs
  (opts, args) <- parseOpts cmd_args "hbal" options

  unless (null args) $ do
         hPutStrLn stderr "Error: this program doesn't take any arguments."
         exitWith $ ExitFailure 1

  let oneline = optOneline opts
      verbose = optVerbose opts
      shownodes = optShowNodes opts

  (fixed_nl, il, ctags, csf) <- loadExternalData opts

  let offline_names = optOffline opts
      all_nodes = Container.elems fixed_nl
      all_names = map Node.name all_nodes
      offline_wrong = filter (flip notElem all_names) offline_names
      offline_indices = map Node.idx $
                        filter (\n -> elem (Node.name n) offline_names)
                               all_nodes
      m_cpu = optMcpu opts
      m_dsk = optMdsk opts

  when (length offline_wrong > 0) $ do
         hPrintf stderr "Wrong node name(s) set as offline: %s\n"
                     (commaJoin offline_wrong)
         exitWith $ ExitFailure 1

  let nm = Container.map (\n -> if elem (Node.idx n) offline_indices
                                then Node.setOffline n True
                                else n) fixed_nl
      nl = Container.map (flip Node.setMdsk m_dsk . flip Node.setMcpu m_cpu)
           nm

  when (not oneline && verbose > 1) $
       putStrLn $ "Loaded cluster tags: " ++ intercalate "," ctags

  when (Container.size il == 0) $ do
         (if oneline then putStrLn $ formatOneline 0 0 0
          else printf "Cluster is empty, exiting.\n")
         exitWith ExitSuccess

  unless oneline $ printf "Loaded %d nodes, %d instances\n"
             (Container.size nl)
             (Container.size il)

  when (length csf > 0 && not oneline && verbose > 1) $
       printf "Note: Stripping common suffix of '%s' from names\n" csf

  let (bad_nodes, bad_instances) = Cluster.computeBadItems nl il
  unless (oneline || verbose == 0) $ printf
             "Initial check done: %d bad nodes, %d bad instances.\n"
             (length bad_nodes) (length bad_instances)

  when (length bad_nodes > 0) $
         putStrLn "Cluster is not N+1 happy, continuing but no guarantee \
                  \that the cluster will end N+1 happy."

  when (optShowInsts opts) $ do
         putStrLn ""
         putStrLn "Initial instance map:"
         putStrLn $ Cluster.printInsts nl il

  when (isJust shownodes) $
       do
         putStrLn "Initial cluster status:"
         putStrLn $ Cluster.printNodes nl (fromJust shownodes)

  let ini_cv = Cluster.compCV nl
      ini_tbl = Cluster.Table nl il ini_cv []
      min_cv = optMinScore opts

  when (ini_cv < min_cv) $ do
         (if oneline then
              putStrLn $ formatOneline ini_cv 0 ini_cv
          else printf "Cluster is already well balanced (initial score %.6g,\n\
                      \minimum score %.6g).\nNothing to do, exiting\n"
                      ini_cv min_cv)
         exitWith ExitSuccess

  unless oneline (if verbose > 2 then
                      printf "Initial coefficients: overall %.8f, %s\n"
                      ini_cv (Cluster.printStats nl)
                  else
                      printf "Initial score: %.8f\n" ini_cv)

  unless oneline $ putStrLn "Trying to minimize the CV..."
  let imlen = Container.maxNameLen il
      nmlen = Container.maxNameLen nl

  (fin_tbl, cmd_strs) <- iterateDepth ini_tbl (optMaxLength opts)
                         (optDiskMoves opts)
                         nmlen imlen [] oneline min_cv
  let (Cluster.Table fin_nl fin_il fin_cv fin_plc) = fin_tbl
      ord_plc = reverse fin_plc
      sol_msg = if null fin_plc
                then printf "No solution found\n"
                else if verbose > 2
                     then printf "Final coefficients:   overall %.8f, %s\n"
                          fin_cv (Cluster.printStats fin_nl)
                     else printf "Cluster score improved from %.8f to %.8f\n"
                          ini_cv fin_cv
                              ::String

  unless oneline $ putStr sol_msg

  unless (oneline || verbose == 0) $
         printf "Solution length=%d\n" (length ord_plc)

  let cmd_jobs = Cluster.splitJobs cmd_strs
      cmd_data = Cluster.formatCmds cmd_jobs

  when (isJust $ optShowCmds opts) $
       do
         let out_path = fromJust $ optShowCmds opts
         putStrLn ""
         (if out_path == "-" then
              printf "Commands to run to reach the above solution:\n%s"
                     (unlines . map ("  " ++) .
                      filter (/= "  check") .
                      lines $ cmd_data)
          else do
            writeFile out_path (shTemplate ++ cmd_data)
            printf "The commands have been written to file '%s'\n" out_path)

  when (optExecJobs opts && not (null ord_plc))
           (case optLuxi opts of
              Nothing -> do
                hPutStrLn stderr "Execution of commands possible only on LUXI"
                exitWith $ ExitFailure 1
              Just master -> execJobSet master csf fin_nl il cmd_jobs)

  when (optShowInsts opts) $ do
         putStrLn ""
         putStrLn "Final instance map:"
         putStr $ Cluster.printInsts fin_nl fin_il

  when (isJust shownodes) $
       do
         let ini_cs = Cluster.totalResources nl
             fin_cs = Cluster.totalResources fin_nl
         putStrLn ""
         putStrLn "Final cluster status:"
         putStrLn $ Cluster.printNodes fin_nl (fromJust shownodes)
         when (verbose > 3) $
              do
                printf "Original: mem=%d disk=%d\n"
                       (Cluster.csFmem ini_cs) (Cluster.csFdsk ini_cs)
                printf "Final:    mem=%d disk=%d\n"
                       (Cluster.csFmem fin_cs) (Cluster.csFdsk fin_cs)
  when oneline $
         putStrLn $ formatOneline ini_cv (length ord_plc) fin_cv
