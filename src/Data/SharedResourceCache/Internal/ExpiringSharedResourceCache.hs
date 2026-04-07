{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
module Data.SharedResourceCache.Internal.ExpiringSharedResourceCache (CacheEntry(..), SharedResourceCache(..), CacheExpiryConfig, loadCacheableResource, handleSharerLeave, handleSharerLeaveSTM, handleSharerJoin) where
    import Data.SharedResourceCache.Internal.CacheItem (CacheItem (CacheItem), decreaseSharersByOne, increaseSharersByOne)
    import Control.Concurrent ( MVar, ThreadId, putMVar, readMVar )
    import qualified StmContainers.Map as M
    import Data.Hashable (Hashable)
    import Data.Time (UTCTime)
    import Control.Concurrent.STM (STM)
    import Control.Exception ( mask,
      uninterruptibleMask_, onException )
    import Control.Monad.STM (atomically)

    import Control.Monad (void, when)
    import Data.SharedResourceCache.Internal.Broom (scheduleCacheCleanup, removeScheduledCleanup)
    import Data.SharedResourceCache.Internal.Model (CacheExpiryConfig, CacheEntry (..))
    import Data.Time.Clock (getCurrentTime)
    import Control.Concurrent.MVar (newEmptyMVar)
    import Control.Concurrent.STM.TVar (newTVar)
    import Data.Either (isLeft)
    import Focus (Focus (Focus), Change (Leave, Remove))

    -- | A cache of resources that can be shared between multiple threads (such as a TChan broadcast channel.)
    --
    data SharedResourceCache key value err = SharedResourceCache {
        cache :: M.Map key (CacheEntry value),
        cleanUpMap :: M.Map key UTCTime,
        loadResourceOp :: key -> IO (Either err value),
        onRemoval :: Maybe (value -> IO ()),
        cacheCleanupThreadId :: ThreadId,
        cacheExpiryConfig :: CacheExpiryConfig
    }

    handleSharerJoin :: Hashable key => SharedResourceCache key value err -> CacheItem value -> key -> STM ()
    handleSharerJoin cache cacheItem resourceId = do
        void $ increaseSharersByOne cacheItem
        removeScheduledCleanup (cleanUpMap cache) resourceId

    handleSharerLeave :: Hashable key => SharedResourceCache key value err -> CacheItem value -> key -> IO ()
    handleSharerLeave cache cacheItem resourceId =
        -- We wrap this in an uninterruptibleMask_ so that we don't end up with items in the cache with phantom
        -- connections if the thread is killed during a blocking operation
        uninterruptibleMask_ $ do
            now <- getCurrentTime
            atomically (handleSharerLeaveSTM cache cacheItem resourceId now)

    handleSharerLeaveSTM :: Hashable key => SharedResourceCache key value err -> CacheItem value -> key -> UTCTime -> STM ()
    handleSharerLeaveSTM (SharedResourceCache cache cleanUpMap _ _ _ config) cacheItem resourceId now = do
        newSharerCount <- decreaseSharersByOne cacheItem
        when (newSharerCount == 0) $ void (scheduleCacheCleanup cleanUpMap config now resourceId)

    loadCacheableResource :: Hashable key => SharedResourceCache key value err -> key -> IO (Either err (CacheItem value))
    loadCacheableResource resourceCache@(SharedResourceCache cache _ loadResourceOp _ _ _) resourceId = do
        existingItem <- atomically $ do
            item <- M.lookup resourceId cache
            case item of
                Nothing -> pure Nothing
                Just result@(LoadingEntry loadingMVar) -> pure (Just result)
                Just result@(LoadedEntry resource) -> do
                    handleSharerJoin resourceCache resource resourceId
                    pure (Just result)

        case existingItem of
            Just (LoadedEntry item) -> pure $ Right item
            Just (LoadingEntry loadedSignalMVar) -> do
                -- Wait the for the other thread that is already loading the resource to signal that it has loaded the item
                -- into the cache then recursively start again
                readMVar loadedSignalMVar
                loadCacheableResource resourceCache resourceId
            Nothing -> loadFreshlyIntoCache resourceCache resourceId

    loadFreshlyIntoCache :: forall key value err. Hashable key => SharedResourceCache key value err -> key -> IO (Either err (CacheItem value))
    loadFreshlyIntoCache resourceCache@(SharedResourceCache cache _ loadResourceOp _ _ _) resourceId = do
        maybeSemaphore <- takeOwnershipOfLoad resourceCache resourceId

        case maybeSemaphore of
            -- Already loaded or loading in another thread, recursively start again
            Nothing -> loadCacheableResource resourceCache resourceId

            -- We've claimed ownership of loading the item into the cache
            Just semaphore -> do
                -- We use uninterruptibleMask so that an async exception can't stop the sempahore remaining in the cache blocking any readers of the resource
                -- from getting the resource. We're in the context of resourcet's 'allocate' so we're otherwise 'masked' apart from on blocking operations
                result <- loadIntoCache resourceCache resourceId semaphore
                    `onException` uninterruptibleMask_ (adjustCacheEntryOnLoadError resourceCache resourceId >> signalCacheLoaded semaphore)

                uninterruptibleMask_ $ do
                    when (isLeft result) (adjustCacheEntryOnLoadError resourceCache resourceId)
                    signalCacheLoaded semaphore

                pure result


        where
            signalCacheLoaded semaphore = putMVar semaphore ()

            -- Returns a Just if we took ownership and Nothing if a thread is already loading the item or it has already been fully loaded
            takeOwnershipOfLoad :: SharedResourceCache key value err -> key -> IO (Maybe (MVar ()))
            takeOwnershipOfLoad resourceCache@(SharedResourceCache cache _ loadResourceOp _ _ _) resourceId = do
                signal <- newEmptyMVar
                atomically $ do
                    cachedItem <- M.lookup resourceId cache
                    case cachedItem of
                        Nothing -> do
                            let entry = LoadingEntry signal
                            M.insert entry resourceId cache
                            pure (Just signal)
                        _ -> pure Nothing

            loadIntoCache :: SharedResourceCache key value err -> key -> MVar () -> IO (Either err (CacheItem value))
            loadIntoCache resourceCache@(SharedResourceCache cache _ loadResourceOp _ _ _) resourceId _ = do
                resourceLoadResult <- loadResourceOp resourceId
                case resourceLoadResult of
                    Right resource -> putIntoCache resourceCache resourceId resource
                    Left err -> pure (Left err)

            putIntoCache :: SharedResourceCache key value err -> key -> value -> IO (Either err (CacheItem value))
            putIntoCache resourceCache@(SharedResourceCache cache _ loadResourceOp _ _ _) resourceId resource = do
                atomically $ do
                    connections <- newTVar 0
                    let entry = CacheItem resource connections
                    handleSharerJoin resourceCache entry resourceId
                    M.insert (LoadedEntry entry) resourceId cache
                    pure (Right entry)

            adjustCacheEntryOnLoadError :: SharedResourceCache key value err -> key -> IO ()
            adjustCacheEntryOnLoadError (SharedResourceCache cache _ _ _ _ _) resourceId =
                atomically $ M.focus removeIfLoading resourceId cache

            -- | Remove the cache entry if it's still in the loading state, so that another thread can claim
            -- the semaphore to try loading it. It shouldn't be possible for a loaded entry to enter the
            -- cache and _then_ an exception to occur.
            removeIfLoading :: Focus (CacheEntry value) STM ()
            removeIfLoading = Focus
                (pure ((), Leave))
                (\case
                    LoadingEntry _ -> pure ((), Remove)
                    _              -> pure ((), Leave)
                )
