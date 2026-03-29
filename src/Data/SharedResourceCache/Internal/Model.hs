module Data.SharedResourceCache.Internal.Model(CacheExpiryConfig(..), CacheEntry(..)) where

    import Control.Concurrent (MVar)
    import Data.SharedResourceCache.Internal.CacheItem (CacheItem)

    -- | Configuration for managing when items can be removed from the cache when there are no more sharers
    data CacheExpiryConfig = CacheExpiryConfig {
        sweepIntervalSeconds :: Int,
        -- ^ How often the cache's sweeper background thread should sweep the cache for expired entries with no sharers that are eligible for removal, in seconds
        itemEligibleForRemovalAfterUnusedSeconds :: Int 
        -- ^ How long after a cache entry has had no sharers that it is eligible for removal from the cache by the sweeper background thread
    }
    
    data CacheEntry a = LoadedEntry (CacheItem a) | LoadingEntry (MVar ())