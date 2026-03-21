module Data.SharedResourceCache.Internal.CacheItem (CacheItem(..), increaseSharersByOne, decreaseSharersByOne, numberOfSharers) where 
    import Control.Concurrent.STM (TVar, STM, modifyTVar')
    import Control.Concurrent.STM.TVar (readTVar)
    
    data CacheItem a = CacheItem {cacheItem :: a, connections :: TVar Int}

    increaseSharersByOne :: CacheItem a -> STM Int
    increaseSharersByOne (CacheItem item connections) = modifyTVar' connections (+ 1) >> readTVar connections

    decreaseSharersByOne :: CacheItem a -> STM Int
    decreaseSharersByOne (CacheItem item connections) = modifyTVar' connections (\item -> item - 1) >> readTVar connections

    numberOfSharers :: CacheItem a -> STM Int
    numberOfSharers (CacheItem item connections) = readTVar connections