{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
module Main (main) where

import Test.Hspec
import Data.SharedResourceCache
import Control.Monad.Trans.Resource (runResourceT, release)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.Async (async, wait)
import Control.Monad.STM (atomically)
import Data.IORef (newIORef, readIORef, modifyIORef', atomicModifyIORef')
import Data.Time.Clock (getCurrentTime)

type Cache = SharedResourceCache String String String

shortExpiry :: CacheExpiryConfig
shortExpiry = CacheExpiryConfig 1 1

longExpiry :: CacheExpiryConfig
longExpiry = CacheExpiryConfig 100 100

makeTestCache :: Maybe (String -> IO ()) -> CacheExpiryConfig -> IO Cache
makeTestCache = makeGlobalSharedResourceCache (\key -> pure (Right ("value-" ++ key)))

main :: IO ()
main = hspec $ do
    describe "SharedResourceCache" $ do

        it "loads a resource into the cache" $ do
            cache <- makeTestCache Nothing longExpiry

            result <- runResourceT $ do
                (_, val) <- getCacheableResource cache "key1"
                pure val

            result `shouldBe` Right "value-key1"

        it "returns the same resource instance for concurrent sharers" $ do
            loadCount <- newIORef (0 :: Int)
            cache :: Cache <- makeGlobalSharedResourceCache
                (\key -> do
                    modifyIORef' loadCount (+ 1)
                    pure (Right ("value-" ++ key)))
                Nothing
                longExpiry

            runResourceT $ do
                (_, val1) <- getCacheableResource cache "key1"
                liftIO $ do
                    val2 <- runResourceT $ do
                        (_, v) <- getCacheableResource cache "key1"
                        pure v
                    val1 `shouldBe` Right "value-key1"
                    val2 `shouldBe` Right "value-key1"

            count <- readIORef loadCount
            count `shouldBe` 1

        it "propagates load errors without caching them" $ do
            callCount <- newIORef (0 :: Int)
            cache :: Cache <- makeGlobalSharedResourceCache
                (\_ -> do
                    modifyIORef' callCount (+ 1)
                    pure (Left "load failed"))
                Nothing
                longExpiry

            result1 <- runResourceT $ do
                (_, val) <- getCacheableResource cache "key1"
                pure val
            result1 `shouldBe` Left "load failed"

            result2 <- runResourceT $ do
                (_, val) <- getCacheableResource cache "key1"
                pure val
            result2 `shouldBe` Left "load failed"

            count <- readIORef callCount
            count `shouldBe` 2

        it "only loads once when multiple threads request the same uncached resource" $ do
            loadCount <- newIORef (0 :: Int)
            gate <- newEmptyMVar

            cache :: Cache <- makeGlobalSharedResourceCache
                (\key -> do
                    atomicModifyIORef' loadCount (\n -> (n + 1, ()))
                    readMVar gate
                    pure (Right ("value-" ++ key)))
                Nothing
                longExpiry

            let numThreads = 5
            results <- mapM (\_ -> async $ runResourceT $ do
                    (_, val) <- getCacheableResource cache "key1"
                    pure val
                ) [1 :: Int ..numThreads]

            -- Give threads time to all reach the cache
            threadDelay 100000
            putMVar gate ()

            vals <- mapM wait results
            mapM_ (`shouldBe` Right "value-key1") vals

            count <- readIORef loadCount
            count `shouldBe` 1

        it "calls onRemoval when an item is evicted" $ do
            removedItems <- newIORef ([] :: [String])
            cache <- makeTestCache
                (Just (\val -> modifyIORef' removedItems (val :)))
                shortExpiry

            runResourceT $ do
                (_, _) <- getCacheableResource cache "key1"
                pure ()

            -- Wait for the sweep to evict it
            threadDelay 2500000

            removed <- readIORef removedItems
            removed `shouldBe` ["value-key1"]

        it "does not evict items that still have sharers" $ do
            removedItems <- newIORef ([] :: [String])
            cache <- makeTestCache
                (Just (\val -> modifyIORef' removedItems (val :)))
                shortExpiry

            runResourceT $ do
                (_, _) <- getCacheableResource cache "key1"
                -- Wait for a sweep cycle while still holding the resource
                liftIO $ threadDelay 2500000
                removed <- liftIO $ readIORef removedItems
                liftIO $ removed `shouldBe` []

        it "does not evict a resurrected item after its sharer count returned to zero" $ do
            loadCount <- newIORef (0 :: Int)
            removedItems <- newIORef ([] :: [String])
            cache :: Cache <- makeGlobalSharedResourceCache
                (\key -> do
                    modifyIORef' loadCount (+ 1)
                    pure (Right ("value-" ++ key)))
                (Just (\val -> modifyIORef' removedItems (val :)))
                shortExpiry

            -- First acquire/release cycle: count goes 0 -> 1 -> 0, scheduling a cleanup
            runResourceT $ do
                (_, val) <- getCacheableResource cache "key1"
                liftIO $ val `shouldBe` Right "value-key1"

            -- Re-acquire before the scheduled cleanup fires: count goes 0 -> 1
            runResourceT $ do
                (_, val) <- getCacheableResource cache "key1"
                liftIO $ val `shouldBe` Right "value-key1"

                -- Hold the resource well past the originally scheduled eviction time
                liftIO $ threadDelay 2500000

                removed <- liftIO $ readIORef removedItems
                liftIO $ removed `shouldBe` []

            -- Only one actual load occurred, confirming it's the same cached item
            count <- readIORef loadCount
            count `shouldBe` 1

        it "peek returns Nothing for uncached items" $ do
            cache <- makeTestCache Nothing longExpiry

            result <- runResourceT $ do
                (_, val) <- peekCacheableResource cache "key1"
                pure val

            result `shouldBe` Nothing

        it "peek returns the item if it is cached" $ do
            cache <- makeTestCache Nothing longExpiry

            runResourceT $ do
                (_, _) <- getCacheableResource cache "key1"
                (_, peeked) <- peekCacheableResource cache "key1"
                liftIO $ peeked `shouldBe` Just "value-key1"

        it "withCacheableResource provides the resource to the action" $ do
            cache <- makeTestCache Nothing longExpiry

            ref <- newIORef ("" :: String)
            withCacheableResource cache "key1" $ \case
                Right val -> modifyIORef' ref (const val)
                Left _ -> pure ()

            result <- readIORef ref
            result `shouldBe` "value-key1"

        it "withPeekCacheableResource returns Nothing for uncached items" $ do
            cache <- makeTestCache Nothing longExpiry

            now <- getCurrentTime
            result <- atomically $ withPeekCacheableResource cache "key1" pure now
            result `shouldBe` (Nothing :: Maybe String)

        it "releasing a resource early allows re-loading" $ do
            cache <- makeTestCache Nothing longExpiry

            runResourceT $ do
                (releaseKey, _) <- getCacheableResource cache "key1"
                release releaseKey
                (_, val2) <- getCacheableResource cache "key1"
                liftIO $ val2 `shouldBe` Right "value-key1"
