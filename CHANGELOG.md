# Changelog for `shared-resource-cache`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

## 0.1.0.3 - 2026-03-23

### Fixed

- Fixed a resource leak where an async exception delivered during `handleSharerLeave`
  (between `getCurrentTime` and the `atomically` call, or during the `atomically` if it
  blocks) could leave a cache entry's sharer count permanently elevated, preventing
  eviction. `handleSharerLeave` is now wrapped in `uninterruptibleMask_`.

## 0.1.0.2 - 2026-03-23

### Fixed

- Fixed a bug where an async exception delivered after `loadIntoCache` returned
  (but before `signalCacheLoaded` executed) would leave waiting threads permanently
  blocked on the semaphore MVar. The `signalCacheLoaded` call is now inside
  `uninterruptibleMask_` alongside `adjustCacheEntryOnLoadError`, ensuring the
  semaphore is always signalled regardless of async exceptions.

## 0.1.0.1 - 2026-03-22

### Fixed

- Fixed a resource leak where an async exception delivered to the loading thread
  after a successful `putIntoCache` STM commit could leave a cache entry with its
  sharer count permanently stuck at 1, preventing eviction. The entry is now
  correctly decremented (and scheduled for eviction if no other sharers remain)
  via `adjustCacheEntryOnLoadError`.

## 0.1.0.0 - 2026-03-22

### Added

- Initial release
- `makeGlobalResourceCache` for caches that live for the lifetime of the program
- `makeResourceCache` for caches with a scoped lifetime managed via `resourcet`
- `getCacheableResource` to retrieve (and load if necessary) a cached resource
- `withCacheableResource` as a convenience wrapper around `getCacheableResource`
- `peekCacheableResource` to retrieve a cached resource without loading it if absent
- `withPeekCacheableResource` to peek at a cached resource within an STM transaction
- Background sweep thread to periodically evict expired, unused cache entries
- Reference counting via STM to track active sharers of each cached resource
