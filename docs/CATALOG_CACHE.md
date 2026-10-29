# Catalogue cache

The catalogue uses stale-while-revalidate metadata and persistent native artwork caching. Cached games are projected off the main actor and shown before a service request completes.

## Metadata lifecycle

`CatalogRepository` owns one shared refresh per region/language/feed/hydration context. The disk key is a SHA-256 digest of that context. Public feed membership is stored separately from account-provided title IDs; private account membership and authentication tokens are never written to the catalogue cache.

The feed is checked every 15 minutes using `ETag` and `Last-Modified` when supplied. Fresh product details are reused for six hours. Newly discovered or stale products hydrate in batches of 100, with at most four requests in flight. Transient HTTP failures have bounded retries, and failed product batches become eligible for another attempt after 60 seconds. Missing products have a short negative-cache lifetime. Manual Refresh forces a fresh metadata check.

Cached games remain available during network failures. Partial responses preserve good prior metadata, and one malformed product does not invalidate the rest of its batch. Successful authoritative feed updates remove departed titles. A failed or malformed feed cannot erase the saved list.

Metadata uses versioned atomic JSON writes, a validated previous generation, a 32 MiB per-file limit, and collection bounds. A corrupt or incompatible primary falls back to the previous valid file. Future-dated freshness timestamps are rechecked. Cache storage failure leaves the in-memory result usable and reports that it could not be saved.

## Visible updates

The first cache bootstrap creates no artificial “new” badges. Later discoveries receive persistent NEW badges and a “New to the catalog” rail. Changed metadata receives UPDATED badges. The update counter filters the catalogue to changed titles; Mark seen dismisses those markers persistently and respects a refresh already in flight. Markers expire after 30 days or when the title leaves the public feed.

The catalogue shows its last successful check time, background refresh state, and a non-modal retry notice when a refresh fails. Automatic checks run while the catalogue is active and pause while streaming or while the scene is inactive. Returning to the catalogue rechecks freshness.

## Artwork

`CatalogArtworkCache` accepts HTTPS URLs without embedded credentials, coalesces identical requests, and limits concurrent downloads to four. It bounds encoded images at 8 MiB, decoded-memory cache cost at 32 MiB, and disk artwork at 192 MiB. ImageIO creates thumbnails off the main actor; visible views release their image references on disappearance.

Artwork survives process restarts. Stale images remain immediately usable while refreshing after seven days. Invalid images are never cached. Failed downloads have a 60-second retry backoff. Eviction removes only this cache's own `.art` files, oldest first. It never cleans Xcode data, authentication storage, or another application's cache.

The default sandbox paths are:

- `~/Library/Containers/com.jayian.pixelcloudx/Data/Library/Caches/PixelCloudX/Catalog-v1/`
- `~/Library/Containers/com.jayian.pixelcloudx/Data/Library/Caches/PixelCloudX/Artwork-v1/`

macOS can purge cache storage. A missing cache triggers normal hydration and retains the user's separate saved and recently opened lists.

## Checks

`Tests/run-regressions.sh` uses the existing Xcode DerivedData products directory. Cache fixtures and mocked URLSession requests cover warm/offline loads, freshness, HTTP 304, incremental changes, removals, malformed products, partial failure, bounded concurrency, retry backoff, account isolation, version/corruption fallback, coalesced refreshes, Mark seen races, saved/recent preferences, and artwork decoding/persistence/eviction.

A 501-title warm-cache disk read and projection took 92–117 ms in isolated local checks. That is a fixture benchmark; final catalogue UI appearance and real-service update timing were not checked while the user requested uninterrupted screen/audio use.
