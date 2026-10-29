import CryptoKit
import Foundation

struct CatalogChange: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case added, updated }
    let kind: Kind
    let date: Date
}
struct CachedCatalogProduct: Codable, Sendable {
    var product: CatalogProduct?
    var checkedAt: Date
    var attemptedAt: Date
}
struct CatalogSnapshot: Codable, Sendable {
    var version = 1
    let context: CatalogContext
    var feedIDs: [String] = []
    var products: [String: CachedCatalogProduct] = [:]
    var feedCheckedAt: Date?
    var etag: String?
    var lastModified: String?
    var changes: [String: CatalogChange] = [:]
    var acknowledgedAt: Date = .distantPast

    func games(accountIDs: [String]) -> [CloudGame] {
        let account = Set(GameCatalogService.normalizedIDs(accountIDs))
        return GameCatalogService.normalizedIDs(feedIDs + Array(account)).compactMap { id in
            products[id]?.product?.game(productID: id, isAccountCloudTitle: account.contains(id))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

actor CatalogDiskCache {
    let context: CatalogContext
    let fileURL: URL
    private let maximumBytes = 32 * 1_024 * 1_024
    init(context: CatalogContext, directory: URL? = nil) {
        self.context = context
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PixelCloudX/Catalog-v1", isDirectory: true)
        let identity = [context.market, context.language, context.feedID, context.hydration].joined(separator: "|")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        fileURL = root.appendingPathComponent("\(key).json")
    }
    func load() -> CatalogSnapshot? {
        read(fileURL) ?? read(fileURL.appendingPathExtension("previous"))
    }
    private func read(_ url: URL) -> CatalogSnapshot? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data),
              snapshot.version == 1, snapshot.context == context,
              snapshot.products.count <= 20_000, snapshot.feedIDs.count <= 20_000,
              snapshot.feedIDs == GameCatalogService.normalizedIDs(snapshot.feedIDs),
              snapshot.products.keys.allSatisfy({ !$0.isEmpty && $0 == $0.uppercased() }) else { return nil }
        return snapshot
    }
    func save(_ snapshot: CatalogSnapshot) throws {
        guard snapshot.context == context, snapshot.version == 1 else { throw GameCatalogError.invalidCache }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumBytes else { throw GameCatalogError.invalidCache }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Keep one validated previous generation. A damaged or future-version
        // primary file never overwrites the last usable backup.
        if read(fileURL) != nil {
            try Data(contentsOf: fileURL).write(to: fileURL.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

struct CatalogRefreshResult: Sendable {
    let snapshot: CatalogSnapshot
    let warning: String?
}

actor CatalogRepository {
    static let shared = CatalogRepository()
    let context: CatalogContext
    private let service: GameCatalogService
    private let disk: CatalogDiskCache
    private let now: @Sendable () -> Date
    private let feedLifetime: TimeInterval
    private let productLifetime: TimeInterval
    private var snapshot: CatalogSnapshot?
    private var flight: (id: UUID, task: Task<CatalogRefreshResult, Error>)?

    init(service: GameCatalogService = GameCatalogService(), disk: CatalogDiskCache? = nil,
         feedLifetime: TimeInterval = 15 * 60, productLifetime: TimeInterval = 6 * 60 * 60,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        context = service.context
        self.disk = disk ?? CatalogDiskCache(context: service.context)
        self.now = now
        self.feedLifetime = feedLifetime
        self.productLifetime = productLifetime
    }
    func cached() async -> CatalogSnapshot {
        if let snapshot { return snapshot }
        let loaded = await disk.load()
        // Another caller may have finished a refresh while disk IO was pending.
        if snapshot == nil { snapshot = loaded ?? CatalogSnapshot(context: context) }
        return snapshot!
    }
    func acknowledgeChanges() async -> CatalogSnapshot {
        var current = await cached()
        current.acknowledgedAt = now()
        current.changes = [:]
        snapshot = current
        try? await disk.save(current)
        return current
    }
    func refresh(accountIDs: [String], force: Bool = false) async throws -> CatalogRefreshResult {
        let base = await cached()
        let operation: (id: UUID, task: Task<CatalogRefreshResult, Error>)
        let joined: Bool
        if let existing = flight { operation = existing; joined = true }
        else {
            let service = service, date = now(), feedTTL = feedLifetime, productTTL = productLifetime
            operation = (UUID(), Task {
                try await Self.update(base, service: service, accountIDs: accountIDs, force: force,
                                      now: date, feedLifetime: feedTTL, productLifetime: productTTL)
            })
            flight = operation
            joined = false
        }
        do {
            var result = try await operation.task.value
            if flight?.id == operation.id {
                var updated = result.snapshot
                updated.acknowledgedAt = max(updated.acknowledgedAt, snapshot?.acknowledgedAt ?? .distantPast)
                updated.changes = updated.changes.filter { $0.value.date > updated.acknowledgedAt }
                snapshot = updated
                flight = nil
                do { try await disk.save(updated) }
                catch { result = CatalogRefreshResult(snapshot: updated, warning: "Catalog updated, but could not save it for the next launch.") }
            }
            let current = snapshot ?? result.snapshot
            // Account enrichment can arrive during the public refresh. It must
            // join that refresh, then hydrate only any additional missing IDs.
            if joined && GameCatalogService.normalizedIDs(accountIDs).contains(where: { current.products[$0] == nil }) {
                return try await refresh(accountIDs: accountIDs)
            }
            return CatalogRefreshResult(snapshot: current, warning: result.warning)
        } catch {
            if flight?.id == operation.id { flight = nil }
            throw error
        }
    }

    func presentation(_ snapshot: CatalogSnapshot, accountIDs: [String]) -> CatalogPresentation {
        CatalogPresentation(games: snapshot.games(accountIDs: accountIDs), changes: snapshot.changes,
                            checkedAt: snapshot.feedCheckedAt)
    }

    private static func update(_ base: CatalogSnapshot, service: GameCatalogService, accountIDs: [String],
                               force: Bool, now: Date, feedLifetime: TimeInterval,
                               productLifetime: TimeInterval) async throws -> CatalogRefreshResult {
        var updated = base
        var warnings: [String] = []
        func stale(_ date: Date?, lifetime: TimeInterval) -> Bool {
            guard let date else { return true }
            return now.timeIntervalSince(date) >= lifetime || date > now.addingTimeInterval(300)
        }
        if force || stale(base.feedCheckedAt, lifetime: feedLifetime) {
            do {
                let feed = try await service.fetchFeed(etag: base.feedIDs.isEmpty ? nil : base.etag,
                                                       lastModified: base.feedIDs.isEmpty ? nil : base.lastModified)
                if let ids = feed.productIDs { updated.feedIDs = ids }
                guard !updated.feedIDs.isEmpty else { throw GameCatalogError.invalidFeed }
                updated.feedCheckedAt = now
                updated.etag = feed.productIDs == nil ? (feed.etag ?? base.etag) : feed.etag
                updated.lastModified = feed.productIDs == nil ? (feed.lastModified ?? base.lastModified) : feed.lastModified
            } catch {
                try Task.checkCancellation()
                guard !base.feedIDs.isEmpty else { throw error }
                warnings.append(error.localizedDescription)
            }
        }
        let ids = GameCatalogService.normalizedIDs(updated.feedIDs + accountIDs)
        let required = ids.filter { id in
            guard let record = base.products[id] else { return true }
            let lifetime = record.product == nil ? feedLifetime : productLifetime
            return force || (stale(record.checkedAt, lifetime: lifetime) && stale(record.attemptedAt, lifetime: 60))
        }
        let batches = stride(from: 0, to: required.count, by: 100).map { Array(required[$0..<min($0 + 100, required.count)]) }
        struct Batch: Sendable { let ids: [String]; let products: [String: CatalogProduct]?; let error: String? }
        await withTaskGroup(of: Batch.self) { group in
            var next = 0
            func enqueue(_ batch: [String]) {
                group.addTask {
                    do { return Batch(ids: batch, products: try await service.fetchProducts(batch), error: nil) }
                    catch { return Batch(ids: batch, products: nil, error: error.localizedDescription) }
                }
            }
            while next < min(4, batches.count) { enqueue(batches[next]); next += 1 }
            while let batch = await group.next() {
                if let products = batch.products {
                    for id in batch.ids {
                        if let product = products[id], product.productTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            updated.products[id] = CachedCatalogProduct(product: product, checkedAt: now, attemptedAt: now)
                        } else {
                            var record = updated.products[id] ?? CachedCatalogProduct(product: nil, checkedAt: now, attemptedAt: now)
                            record.attemptedAt = now
                            updated.products[id] = record
                        }
                    }
                } else {
                    warnings.append(batch.error ?? "Some game details could not be refreshed.")
                    for id in batch.ids {
                        var record = updated.products[id] ?? CachedCatalogProduct(product: nil, checkedAt: .distantPast, attemptedAt: now)
                        record.attemptedAt = now
                        updated.products[id] = record
                    }
                }
                if next < batches.count { enqueue(batches[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        let publicIDs = Set(updated.feedIDs)
        if !base.games(accountIDs: []).isEmpty {
            let oldGames = Dictionary(base.games(accountIDs: []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for game in updated.games(accountIDs: []) {
                if let previous = oldGames[game.id] {
                    if previous != game, updated.changes[game.id]?.kind != .added {
                        updated.changes[game.id] = CatalogChange(kind: .updated, date: now)
                    }
                } else { updated.changes[game.id] = CatalogChange(kind: .added, date: now) }
            }
        }
        updated.changes = updated.changes.filter { publicIDs.contains($0.key) && now.timeIntervalSince($0.value.date) < 30 * 86_400 }
        let retained = Set(ids)
        updated.products = updated.products.filter { retained.contains($0.key) }
        return CatalogRefreshResult(snapshot: updated, warning: warnings.isEmpty ? nil : warnings[0])
    }
}

struct CatalogPresentation: Sendable {
    let games: [CloudGame]
    let changes: [String: CatalogChange]
    let checkedAt: Date?
}
