{-| Module describing an instance.

The instance data type holds very few fields, the algorithm
intelligence is in the "Node" and "Cluster" modules.

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

module Ganeti.HTools.Instance
    ( Instance(..)
    , AssocList
    , List
    , create
    , setIdx
    , setName
    , setPri
    , setSec
    , setBoth
    , setMovable
    , specOf
    , shrinkByType
    , runningStates
    ) where

import qualified Ganeti.HTools.Types as T
import qualified Ganeti.HTools.Container as Container

-- * Type declarations

-- | The instance type
data Instance = Instance { name :: String    -- ^ The instance name
                         , mem :: Int        -- ^ Memory of the instance
                         , dsk :: Int        -- ^ Disk size of instance
                         , vcpus :: Int      -- ^ Number of VCPUs
                         , running :: Bool   -- ^ Is the instance running?
                         , runSt :: String   -- ^ Original (text) run status
                         , pNode :: T.Ndx    -- ^ Original primary node
                         , sNode :: T.Ndx    -- ^ Original secondary node
                         , idx :: T.Idx      -- ^ Internal index
                         , util :: T.DynUtil -- ^ Dynamic resource usage
                         , movable :: Bool   -- ^ Can the instance be moved?
                         , tags :: [String]  -- ^ List of instance tags
                         } deriving (Show)

instance T.Element Instance where
    nameOf  = name
    idxOf   = idx
    setName = setName
    setIdx  = setIdx

-- | Running instance states.
runningStates :: [String]
runningStates = ["running", "ERROR_up"]

-- | A simple name for the int, instance association list.
type AssocList = [(T.Idx, Instance)]

-- | A simple name for an instance map.
type List = Container.Container Instance

-- * Initialization

-- | Create an instance.
--
-- Some parameters are not initialized by function, and must be set
-- later (via 'setIdx' for example).
create :: String -> Int -> Int -> Int -> String
       -> [String] -> T.Ndx -> T.Ndx -> Instance
create name_init mem_init dsk_init vcpus_init run_init tags_init pn sn =
    Instance { name = name_init
             , mem = mem_init
             , dsk = dsk_init
             , vcpus = vcpus_init
             , running = run_init `elem` runningStates
             , runSt = run_init
             , pNode = pn
             , sNode = sn
             , idx = -1
             , util = T.baseUtil
             , tags = tags_init
             , movable = True
             }

-- | Changes the index.
--
-- This is used only during the building of the data structures.
setIdx :: Instance -- ^ The original instance
       -> T.Idx    -- ^ New index
       -> Instance -- ^ The modified instance
setIdx t i = t { idx = i }

-- | Changes the name.
--
-- This is used only during the building of the data structures.
setName :: Instance -- ^ The original instance
        -> String   -- ^ New name
        -> Instance -- ^ The modified instance
setName t s = t { name = s }

-- * Update functions

-- | Changes the primary node of the instance.
setPri :: Instance  -- ^ the original instance
        -> T.Ndx    -- ^ the new primary node
        -> Instance -- ^ the modified instance
setPri t p = t { pNode = p }

-- | Changes the secondary node of the instance.
setSec :: Instance  -- ^ the original instance
        -> T.Ndx    -- ^ the new secondary node
        -> Instance -- ^ the modified instance
setSec t s = t { sNode = s }

-- | Changes both nodes of the instance.
setBoth :: Instance  -- ^ the original instance
         -> T.Ndx    -- ^ new primary node index
         -> T.Ndx    -- ^ new secondary node index
         -> Instance -- ^ the modified instance
setBoth t p s = t { pNode = p, sNode = s }

setMovable :: Instance -- ^ The original instance
           -> Bool     -- ^ New movable flag
           -> Instance -- ^ The modified instance
setMovable t m = t { movable = m }

-- | Try to shrink the instance based on the reason why we can't
-- allocate it.
shrinkByType :: Instance -> T.FailMode -> T.Result Instance
shrinkByType inst T.FailMem = let v = mem inst - T.unitMem
                              in if v < T.unitMem
                                 then T.Bad "out of memory"
                                 else T.Ok inst { mem = v }
shrinkByType inst T.FailDisk = let v = dsk inst - T.unitDsk
                               in if v < T.unitDsk
                                  then T.Bad "out of disk"
                                  else T.Ok inst { dsk = v }
shrinkByType inst T.FailCPU = let v = vcpus inst - T.unitCpu
                              in if v < T.unitCpu
                                 then T.Bad "out of vcpus"
                                 else T.Ok inst { vcpus = v }
shrinkByType _ f = T.Bad $ "Unhandled failure mode " ++ show f

-- | Return the spec of an instance.
specOf :: Instance -> T.RSpec
specOf Instance { mem = m, dsk = d, vcpus = c } =
    T.RSpec { T.rspecCpu = c, T.rspecMem = m, T.rspecDsk = d }
