# Changelog for `shared-resource-cache`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

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
