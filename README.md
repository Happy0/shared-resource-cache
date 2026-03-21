# shared-resource-cache

A cache designed for guaranteeing that different threads can share the same reference to a resource. For example, it allows threads to communicate via a shared
[TChan broadcast channel](https://hackage.haskell.org/package/stm-2.5.3.1/docs/Control-Concurrent-STM-TChan.html).
Using [resourcet](https://hackage.haskell.org/package/resourcet), items are only removed from the cache after no 'sharers' are holding the
resource and the item has expired (according to the expiry configuration the cache was constructed with.)

Note: an MVar is used to coordinate between threads that only one thread does the initial load of the resource with the given IO action if multiple
threads try and retrieve a resource that is not yet cached at the same time.