{-# LANGUAGE ScopedTypeVariables #-}
module Data.SharedResourceCache.Internal.Broom (startBroomLoop, removeIfStale, scheduleCacheCleanup, removeScheduledCleanup) where
    import qualified StmContainers.Map as M
    import Data.Hashable (Hashable)
    import Data.Time.Clock (NominalDiffTime, UTCTime)
    import Control.Concurrent.STM (STM)
    import Control.Monad (forever, when)
    import Control.Monad.STM (atomically)
    import Data.SharedResourceCache.Internal.CacheItem (numberOfSharers, CacheItem (cacheItem))
    import Control.Exception (SomeException, catch)
    import Control.Concurrent (threadDelay)
    import ListT (traverse_)
    import Data.Time (addUTCTime, getCurrentTime)
    import Data.SharedResourceCache.Internal.Model (CacheEntry (..), CacheExpiryConfig (..))

    startBroomLoop :: Hashable key => M.Map key (CacheEntry value) -> M.Map key UTCTime -> Maybe (value -> IO ()) -> Int -> IO ()
    startBroomLoop resourceCache cleanUpMap onRemove sweepIntervalSeconds = forever $ do
        now <- getCurrentTime
        -- We use 'listTNonAtomic since we do the removal itself atomically (followed by an IO action) and
        -- if we miss an entry due to a stale view on the current iteration we can remove it in a later iteration
        traverse_ (removeIfStale  now resourceCache cleanUpMap onRemove) (M.listTNonAtomic cleanUpMap)
        threadDelay (sweepIntervalSeconds * 1000000)

    removeIfStale :: forall key err value. Hashable key => UTCTime -> M.Map key (CacheEntry value) -> M.Map key UTCTime -> Maybe (value -> IO ()) -> (key, UTCTime) -> IO ()
    removeIfStale now cache cleanUpMap onRemove (resourceId, cacheExpiryTime) =
        when (now >= cacheExpiryTime) $ do
            removed <- atomically $ removeIfNoSharers cache cleanUpMap resourceId
            case (removed, onRemove) of
                (Just removedItem, Just onRemovalFunction) -> catch (onRemovalFunction removedItem) (\(_ :: SomeException) -> return ())
                _ -> return ()
        where
            removeIfNoSharers :: M.Map key (CacheEntry value) -> M.Map key UTCTime -> key -> STM (Maybe value)
            removeIfNoSharers cache cleanupMap resourceId = do
                resource <- M.lookup resourceId cache
                case resource of
                    Just (LoadedEntry cached) -> do
                        sharers <- numberOfSharers cached

                        if sharers == 0
                            then do
                            removeFromCache cache resourceId
                            removeScheduledCleanup cleanupMap resourceId
                            return (Just (cacheItem cached))
                            else
                            return Nothing
                    _ -> pure Nothing

            removeFromCache :: M.Map key (CacheEntry value) -> key -> STM ()
            removeFromCache resourceCache resourceId = M.delete resourceId resourceCache

    scheduleCacheCleanup :: Hashable key => M.Map key UTCTime -> CacheExpiryConfig -> UTCTime -> key -> STM ()
    scheduleCacheCleanup cleanUpMap (CacheExpiryConfig _ itemEligibleForRemovalAfterUnusedSeconds) now resourceId = do
        let eligibleForRemovalSeconds = fromIntegral itemEligibleForRemovalAfterUnusedSeconds :: NominalDiffTime
        M.insert (addUTCTime eligibleForRemovalSeconds now) resourceId cleanUpMap

    removeScheduledCleanup :: Hashable key => M.Map key UTCTime -> key -> STM ()
    removeScheduledCleanup cleanUpMap resourceId = M.delete resourceId cleanUpMap
