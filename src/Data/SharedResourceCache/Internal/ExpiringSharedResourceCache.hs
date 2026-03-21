{-# LANGUAGE ScopedTypeVariables #-}
module Data.SharedResourceCache.Internal.ExpiringSharedResourceCache (CacheEntry(..), ResourceCache(..), CacheExpiryConfig, loadCacheableResource, handleSharerLeave, handleSharerLeaveSTM, handlerSharerJoin) where
    import Data.SharedResourceCache.Internal.CacheItem (CacheItem (CacheItem), decreaseSharersByOne, increaseSharersByOne)
    import Control.Concurrent ( MVar, ThreadId, putMVar, readMVar )
    import qualified StmContainers.Map as M
    import Data.Text (Text)
    import Data.Time (UTCTime)
    import Control.Concurrent.STM (STM)
    import Control.Exception ( mask,
      uninterruptibleMask_, finally )
    import Control.Monad.STM (atomically)
    
    import Control.Monad (void, when)
    import Data.SharedResourceCache.Internal.Broom (scheduleCacheCleanup, removeScheduledCleanup)
    import Data.SharedResourceCache.Internal.Model (CacheExpiryConfig, CacheEntry (..))
    import Data.Time.Clock (getCurrentTime)
    import Control.Concurrent.MVar (newEmptyMVar)
    import Control.Concurrent.STM.TVar (newTVar)

    -- | A cache of resources that can be shared between multiple threads (such as a TChan broadcast channel.)
    --
    data ResourceCache err a = ResourceCache {
        cache :: M.Map Text (CacheEntry err a),
        cleanUpMap :: M.Map Text UTCTime,
        loadResourceOp :: Text -> IO (Either err a),
        onRemoval :: Maybe (a -> IO ()),
        cacheCleanupThreadId :: ThreadId,
        cacheExpiryConfig :: CacheExpiryConfig
    }

    handlerSharerJoin :: ResourceCache err a -> CacheItem a -> Text -> STM ()
    handlerSharerJoin cache cacheItem resourceId = do
        void $ increaseSharersByOne cacheItem
        removeScheduledCleanup (cleanUpMap cache) resourceId

    handleSharerLeave :: ResourceCache err a -> CacheItem a -> Text -> IO ()
    handleSharerLeave cache cacheItem resourceId = do
        now <- getCurrentTime
        atomically (handleSharerLeaveSTM cache cacheItem resourceId now)

    handleSharerLeaveSTM  :: ResourceCache err a -> CacheItem a -> Text -> UTCTime -> STM ()
    handleSharerLeaveSTM (ResourceCache cache cleanUpMap _ _ _ config) cacheItem resourceId now = do
        newSharerCount <- decreaseSharersByOne cacheItem
        when (newSharerCount == 0) $ void (scheduleCacheCleanup cleanUpMap config now resourceId)

    loadCacheableResource :: ResourceCache err a -> Text -> IO (Either err (CacheItem a))
    loadCacheableResource resourceCache@(ResourceCache cache _ loadResourceOp _ _ _) resourceId = do
        existingItem <- atomically $ do
            item <- M.lookup resourceId cache
            case item of
                Nothing -> pure Nothing
                Just result@(LoadingEntry loadingMVar) -> pure (Just result)
                Just result@(LoadedEntry resource) -> do
                    handlerSharerJoin resourceCache resource resourceId
                    pure (Just result)

        case existingItem of
            Just (LoadedEntry item) -> pure $ Right item
            Just (LoadingEntry loadedSignalMVar) -> do
                -- Wait the for the other thread that is already loading the resource to signal that it has loaded the item
                -- into the cache then recursively start again
                readMVar loadedSignalMVar
                loadCacheableResource resourceCache resourceId
            Nothing -> loadFreshlyIntoCache resourceCache resourceId

    loadFreshlyIntoCache :: ResourceCache err a -> Text -> IO (Either err (CacheItem a))
    loadFreshlyIntoCache resourceCache@(ResourceCache cache _ loadResourceOp _ _ _) resourceId =
        -- We run this operation in mask so that we aren't left with a permanent loading claim in the cache if the thread is interrupted
        mask $ (\restore -> do
            maybeSemaphore <- takeOwnershipOfLoad resourceCache resourceId

            case maybeSemaphore of
                -- Already loaded or loading in another thread, recursively start again
                Nothing -> restore $ loadCacheableResource resourceCache resourceId

                -- We've claimed ownership of loading the item into the cache
                Just semaphore ->
                    restore (loadIntoCache resourceCache resourceId semaphore)
                        `finally` uninterruptibleMask_ (removeLoadingClaim resourceCache resourceId >> signalCacheLoaded semaphore)
            )

        where
            signalCacheLoaded semaphore = putMVar semaphore ()

            -- Returns a Just if we took ownership and Nothing if a thread is already loading the item or it has already been fully loaded
            takeOwnershipOfLoad :: ResourceCache err a -> Text -> IO (Maybe (MVar ()))
            takeOwnershipOfLoad resourceCache@(ResourceCache cache _ loadResourceOp _ _ _) resourceId = do
                signal <- newEmptyMVar
                atomically $ do
                    cachedItem <- M.lookup resourceId cache
                    case cachedItem of
                        Nothing -> do
                            let entry = LoadingEntry signal
                            M.insert entry resourceId cache
                            pure (Just signal)
                        _ -> pure Nothing

            loadIntoCache :: ResourceCache err a -> Text -> MVar () -> IO (Either err (CacheItem a))
            loadIntoCache resourceCache@(ResourceCache cache _ loadResourceOp _ _ _) resourceId _ = do
                resourceLoadResult <- loadResourceOp resourceId
                case resourceLoadResult of
                    Right resource -> putIntoCache resourceCache resourceId resource
                    Left err -> pure (Left err)


            putIntoCache :: ResourceCache err a -> Text -> a -> IO (Either err (CacheItem a))
            putIntoCache resourceCache@(ResourceCache cache _ loadResourceOp _ _ _) resourceId resource = do
                atomically $ do
                    connections <- newTVar 0
                    let entry = CacheItem resource connections
                    handlerSharerJoin resourceCache entry resourceId
                    M.insert (LoadedEntry entry) resourceId cache
                    pure (Right entry)

            removeLoadingClaim :: ResourceCache err a -> Text -> IO ()
            removeLoadingClaim resourceCache@(ResourceCache cache _ _ _ _ _) resourceId = atomically $ do
                result <- M.lookup resourceId cache

                case result of
                    Just (LoadingEntry _) -> void (M.delete resourceId cache)
                    _ -> pure ()