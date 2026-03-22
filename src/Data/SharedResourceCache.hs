{-# LANGUAGE ScopedTypeVariables #-}

-- | A cache that holds items (resources) while there are multiple threads using the 
--   resource or until the item is eligible for removal with respect to the given cache
--   expiry configuration.
--
-- It is general purpose, but it is designed with the use case in mind where it is important that
-- different threads need to share the same resource instance (such as a TChan used for broadcasting messages
-- between threads)
module Data.SharedSharedResourceCache (
  makeSharedResourceCache,
  makeGlobalSharedResourceCache,
  withCacheableResource,
  getCacheableResource,
  SharedResourceCache,
  peekCacheableResource,
  withPeekCacheableResource,
  CacheExpiryConfig(..)) where

import Control.Concurrent ( forkIO, killThread )
import Control.Concurrent.STM.TVar ()
import Control.Monad.STM ( STM, atomically )
import Data.Text ( Text )
import Data.Time ( UTCTime )
import qualified StmContainers.Map as M
import Prelude
import Control.Monad.Trans.Resource (MonadResource, ReleaseKey, runResourceT, allocate)
import Control.Monad.IO.Class (liftIO)
import Data.SharedSharedResourceCache.Internal.CacheItem (CacheItem(..))
import Data.SharedSharedResourceCache.Internal.ExpiringSharedSharedResourceCache (CacheEntry(..), SharedResourceCache (..), CacheExpiryConfig, loadCacheableResource, handleSharerLeave, handlerSharerJoin, handleSharerLeaveSTM)
import Data.SharedSharedResourceCache.Internal.Broom (startBroomLoop)
import Data.SharedSharedResourceCache.Internal.Model (CacheExpiryConfig(..))

-- | Constructs a resource cache that is expected to be used for the lifetime of the program. Internally, it forks a thread to 
--  manage periodically removing cache entries that have expired (as per the cache expiry configuration.)
makeGlobalSharedResourceCache 
 :: (Text -> IO (Either err a)) -- The action to load the given resource by ID
 -> Maybe (a -> IO ()) -- An action to be executed when the item is removed from the cache
 -> CacheExpiryConfig -- The configuration for when the cache item should be marked as expired and be eligible for removal from the cache
 -> IO (SharedResourceCache err a)
makeGlobalSharedResourceCache loadResourceOp onRemoval cacheExpiryConfig@(CacheExpiryConfig sweepIntervalSeconds _) = do
  resourceCache <- M.newIO
  cleanUpMap <- M.newIO
  threadId <- forkIO $ startBroomLoop resourceCache cleanUpMap onRemoval sweepIntervalSeconds
  pure $ SharedResourceCache resourceCache cleanUpMap loadResourceOp onRemoval threadId cacheExpiryConfig

-- | The same as 'makeGlobalSharedResourceCache' but intended for cases where the cache doesn't live for the lifetime of the program.
--   When the resource is freed (via MonadResource) the forked thread for cleaning the resource cache is killed.
makeSharedResourceCache :: (MonadResource m) => (Text -> IO (Either err a)) -> Maybe (a -> IO ()) -> CacheExpiryConfig -> m (ReleaseKey, SharedResourceCache err a)
makeSharedResourceCache loadResourceOp onRemoval cacheExpiryConfig = do
  allocate (allocateResource loadResourceOp onRemoval) deallocateResource
  where
    allocateResource :: (Text -> IO (Either err a)) -> Maybe (a -> IO ()) -> IO (SharedResourceCache err a)
    allocateResource loadOp removal = makeGlobalSharedResourceCache loadOp removal cacheExpiryConfig

    deallocateResource :: SharedResourceCache err a -> IO ()
    deallocateResource cache = do
      let threadId = cacheCleanupThreadId cache
      killThread threadId

-- | Executes the given action using the resource with the given ID. This function is a wrapper around the 'getCacheableResource' function,
--   where the resource is freed at the end of the supplied action
withCacheableResource :: SharedResourceCache err a -> Text -> (Either err a -> IO ()) -> IO ()
withCacheableResource cache resourceId op =
  runResourceT $ do
    (_, cachedResource) <- getCacheableResource cache resourceId
    liftIO $ op cachedResource

-- | Retrieves a cacheable resource with the given resource ID using the IO action configured
--   when the cache was constructed.
--
-- If the item is already loaded into the cache, it is returned. If it is not yet loaded, the first thread requesting this resource to
-- acquire a MVar will take ownership of loading it and signal to any other threads waiting for the resource that it has been loaded.
-- 
-- This action is executed in the 'MonadResource' monad typeclass
-- context so that when the resource is freed, the cache can mark the cache item as having one less sharer.
--
-- When there are no sharers remaining, the cache item is scheduled for eviction according to the configuration that was used at cache
-- construction time
--
getCacheableResource :: (MonadResource m) => SharedResourceCache err a -> Text -> m (ReleaseKey, Either err a)
getCacheableResource resourceCache resourceId = do
  (releaseKey, cacheEntry) <- allocate (allocateResource resourceCache resourceId) (deAllocateResource resourceCache)
  return (releaseKey, cacheItem <$> cacheEntry)
  where
    allocateResource :: SharedResourceCache err a -> Text -> IO (Either err (CacheItem a))
    allocateResource = loadCacheableResource

    deAllocateResource :: SharedResourceCache err a -> Either err (CacheItem a) -> IO ()
    deAllocateResource resourceCache resource = do
      case resource of
        Left _ -> pure ()
        Right sharedResource -> handleSharerLeave resourceCache sharedResource resourceId

-- | Returns the item if it's in the cache but does not load it into the cache if it is not present.
--
--  If there are no other sharers of the resource once the resource action has been run to completion
--  or the 'release key' is used to free it early then the item is scheduled for eviction from the cache.
peekCacheableResource :: MonadResource m => SharedResourceCache err a -> Text -> m (ReleaseKey, Maybe a)
peekCacheableResource resourceCache resourceId = do
  (releaseKey, cacheEntry) <- allocate (allocateResource resourceCache resourceId) (deAllocateResource resourceCache)
  return (releaseKey, cacheItem <$> cacheEntry)
  where
    allocateResource :: SharedResourceCache err a -> Text -> IO (Maybe (CacheItem a))
    allocateResource resourceCache resourceId = atomically $ do
      item <- M.lookup resourceId (cache resourceCache)
      case item of
        Just (LoadedEntry cachedItem) -> do
          handlerSharerJoin resourceCache cachedItem resourceId
          pure (Just cachedItem)
        _ -> pure Nothing    

    deAllocateResource :: SharedResourceCache err a -> Maybe (CacheItem a) -> IO ()
    deAllocateResource resourceCache resource =
      case resource of
        Nothing -> pure ()
        Just sharedResource -> handleSharerLeave resourceCache sharedResource resourceId

-- | Executes the given action with a 'Just' if an item with the given resourceID is present in the cache,
--  otherwise executes it with Nothing
--
--  If there are no other sharers of the resource once the action is complete then the item is scheduled
--  for eviction
--
-- The 'now' parameter is used to schedule the item for eviction from the cache according to the 
-- expiry config and should be the current time. It is required to be passed in as getting the current time
-- is an IO action that cannot be performed in an STM transaction.
withPeekCacheableResource :: SharedResourceCache err a -> Text -> (Maybe a -> STM b) -> UTCTime -> STM b
withPeekCacheableResource resourceCache resourceId action now = do
  resource <- M.lookup resourceId (cache resourceCache)
  case resource of
    Just (LoadedEntry item) -> do
      handlerSharerJoin resourceCache item resourceId
      result <- action (Just (cacheItem item))
      handleSharerLeaveSTM resourceCache item resourceId now
      pure result
    _ -> action Nothing