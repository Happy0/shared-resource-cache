module Data.SharedResourceCache.Internal.Broom (startBroomLoop, removeIfStale, scheduleCacheCleanup, removeScheduledCleanup) where
    import qualified StmContainers.Map as M
    import Data.Text (Text)
    import Data.Time.Clock (NominalDiffTime, UTCTime)
    import Control.Concurrent.STM (STM)
    import Control.Monad (forever, when)
    import Control.Monad.STM (atomically)
    import Data.SharedResourceCache.Internal.CacheItem (numberOfSharers, CacheItem (cacheItem))
    import Control.Concurrent (threadDelay)
    import ListT (traverse_)
    import Data.Time (addUTCTime, getCurrentTime)
    import Data.SharedResourceCache.Internal.Model (CacheEntry (..), CacheExpiryConfig (..))
    
    startBroomLoop :: M.Map Text (CacheEntry err a) -> M.Map Text UTCTime -> Maybe (a -> IO ()) -> Int -> IO ()
    startBroomLoop resourceCache cleanUpMap onRemove sweepIntervalSeconds = forever $ do
        now <- getCurrentTime
        -- We use 'listTNonAtomic since we do the removal itself atomically (followed by an IO action) and
        -- if we miss an entry due to a stale view on the current iteration we can remove it in a later iteration
        traverse_ (removeIfStale  now resourceCache cleanUpMap onRemove) (M.listTNonAtomic cleanUpMap)
        threadDelay (sweepIntervalSeconds * 1000000)

    removeIfStale :: UTCTime -> M.Map Text (CacheEntry err a) -> M.Map Text UTCTime -> Maybe (a -> IO ()) -> (Text, UTCTime) -> IO ()
    removeIfStale now cache cleanUpMap onRemove (resourceId, cacheExpiryTime) =
        when (now >= cacheExpiryTime) $ do
            removed <- atomically $ removeIfNoSharers cache cleanUpMap resourceId
            case (removed, onRemove) of
                (Just removedItem, Just onRemovalFunction) -> onRemovalFunction removedItem
                _ -> return ()
        where
            removeIfNoSharers :: M.Map Text (CacheEntry err a) -> M.Map Text UTCTime -> Text -> STM (Maybe a)
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

            removeFromCache :: M.Map Text (CacheEntry err a) -> Text -> STM ()
            removeFromCache resourceCache resourceId = M.delete resourceId resourceCache

    scheduleCacheCleanup :: M.Map Text UTCTime -> CacheExpiryConfig -> UTCTime -> Text -> STM ()
    scheduleCacheCleanup cleanUpMap (CacheExpiryConfig _ itemEligibleForRemovalAfterUnusedSeconds) now resourceId = do
        let eligibleForRemovalSeconds = fromIntegral itemEligibleForRemovalAfterUnusedSeconds :: NominalDiffTime
        M.insert (addUTCTime eligibleForRemovalSeconds now) resourceId cleanUpMap

    removeScheduledCleanup :: M.Map Text UTCTime -> Text -> STM ()
    removeScheduledCleanup cleanUpMap resourceId = M.delete resourceId cleanUpMap

