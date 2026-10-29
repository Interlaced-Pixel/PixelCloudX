import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private final class CatalogFixture: @unchecked Sendable {
    private let lock = NSLock()
    var ids = ["A", "B"]
    var titles: [String: String] = [:]
    var status = 200
    var conditional = false
    var failContaining: String?
    var malformed: String?
    var omitted: String?
    var imageData = Data()
    var delay: UInt64 = 10_000_000
    private(set) var feeds = 0
    private(set) var batches: [[String]] = []
    private(set) var images = 0
    private var active = 0
    private(set) var peak = 0

    func response(_ request: URLRequest) -> (Int, Data, [String: String]) {
        lock.lock(); defer { lock.unlock() }
        active += 1; peak = max(peak, active)
        if request.url!.host == "artwork.invalid" {
            images += 1
            return (status, imageData, ["Content-Type": "image/png"])
        }
        if request.url!.path == "/sigls/v2" {
            feeds += 1
            if status != 200 { return (status, Data(), [:]) }
            if conditional {
                check(request.value(forHTTPHeaderField: "If-None-Match") == "catalog-tag")
                return (304, Data(), ["ETag": "catalog-tag"])
            }
            return (200, json(ids.map { ["id": $0] }), ["ETag": "catalog-tag"])
        }
        let body = try! JSONSerialization.jsonObject(with: request.body()) as! [String: Any]
        let requested = body["Products"] as! [String]
        batches.append(requested)
        if status != 200 || (failContaining.map { requested.contains($0) } ?? false) { return (400, Data(), [:]) }
        var products: [String: Any] = [:]
        for id in requested where id != omitted {
            products[id] = id == malformed ? ["ProductTitle": 123] : [
                "ProductTitle": titles[id] ?? "Title \(id)", "ProductDescriptionShort": "Description \(id)",
                "OriginalReleaseDate": "2025-01-01T00:00:00Z", "XCloudTitleId": "CLOUD-\(id)",
                "AvailablePlatforms": (id == "X" || id == "Y") ? [] : ["XCloud"]
            ]
        }
        return (200, json(["Products": products]), [:])
    }
    func finish() { lock.lock(); active -= 1; lock.unlock() }
}
private func check(_ value: Bool, _ message: String = "Catalog cache assertion failed") { precondition(value, message) }
private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private extension URLRequest {
    func body() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    static var fixture = CatalogFixture()
    private var completionTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.fixture
        let result = fixture.response(request)
        completionTask = Task {
            do { try await Task.sleep(nanoseconds: fixture.delay) } catch { fixture.finish(); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.2)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            fixture.finish()
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { completionTask?.cancel() }
}

@main @MainActor private enum CatalogCacheTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("CatalogCacheFixtures", isDirectory: true)
        // This directory contains only fixtures created by this test executable.
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = CatalogFixture(); CatalogProtocol.fixture = fixture
        let context = CatalogContext(market: "US", language: "en-US")
        let service = GameCatalogService(context: context, session: session)
        let clock = TestClock()
        let disk = CatalogDiskCache(context: context, directory: root.appendingPathComponent("metadata"))
        let repository = CatalogRepository(service: service, disk: disk, now: { clock.now() })
        check(GameCatalogService.normalizedIDs([" a ", "A", "", "b"]) == ["A", "B"])

        var result = try await repository.refresh(accountIDs: [])
        check(result.snapshot.games(accountIDs: []).count == 2 && result.snapshot.changes.isEmpty)
        check(fixture.feeds == 1 && fixture.batches.count == 1)
        _ = try await repository.refresh(accountIDs: [])
        check(fixture.feeds == 1 && fixture.batches.count == 1, "Fresh metadata must avoid all requests")

        let warm = CatalogRepository(service: service, disk: disk, now: { clock.now() })
        let before = Date()
        let warmSnapshot = await warm.cached()
        check(warmSnapshot.games(accountIDs: []).count == 2)
        check(fixture.feeds == 1 && fixture.batches.count == 1, "Warm catalog must use disk before network")
        print("Warm catalog read: \(Int(Date().timeIntervalSince(before) * 1000)) ms")

        fixture.conditional = true; clock.advance(16 * 60)
        result = try await repository.refresh(accountIDs: [])
        check(fixture.feeds == 2 && fixture.batches.count == 1, "304 must reuse fresh hydration")

        fixture.conditional = false; fixture.ids = ["A", "C"]; fixture.titles["A"] = "Alpha updated"
        clock.advance(7 * 3600)
        result = try await repository.refresh(accountIDs: [])
        check(result.snapshot.games(accountIDs: []).map(\.id).sorted() == ["A", "C"])
        check(result.snapshot.changes["A"]?.kind == .updated && result.snapshot.changes["C"]?.kind == .added)
        check(result.snapshot.products["B"] == nil, "Authoritative feed removal must remove the title")
        _ = await repository.acknowledgeChanges()
        check(await disk.load()?.changes.isEmpty == true)

        fixture.status = 403
        result = try await repository.refresh(accountIDs: [], force: true)
        check(result.warning != nil && result.snapshot.games(accountIDs: []).count == 2, "Offline/failed refresh preserves usable games")
        fixture.status = 200; fixture.malformed = "A"; fixture.titles["C"] = "Charlie updated"
        clock.advance(7 * 3600)
        result = try await repository.refresh(accountIDs: [])
        check(result.snapshot.games(accountIDs: []).first(where: { $0.id == "A" })?.title == "Alpha updated")
        check(result.snapshot.games(accountIDs: []).first(where: { $0.id == "C" })?.title == "Charlie updated", "One malformed product must not discard the batch")

        let other = CatalogDiskCache(context: CatalogContext(market: "GB", language: "en-GB"), directory: root.appendingPathComponent("metadata"))
        check(await other.load() == nil, "Market/language contexts must be isolated")
        let path = disk.fileURL
        try Data("corrupt".utf8).write(to: path)
        check(await disk.load() != nil, "A corrupt primary must fall back to the validated previous generation")
        var future = result.snapshot; future.version = 99
        try JSONEncoder().encode(future).write(to: path)
        check(await disk.load()?.version == 1, "Future versions must not be interpreted as current data")

        let partialFixture = CatalogFixture(); partialFixture.ids = (0..<601).map { "P\($0)" }
        partialFixture.failContaining = "P100"; partialFixture.delay = 30_000_000
        CatalogProtocol.fixture = partialFixture
        let partialDisk = CatalogDiskCache(context: context, directory: root.appendingPathComponent("partial"))
        let partial = CatalogRepository(service: service, disk: partialDisk, now: { clock.now() })
        let partialResult = try await partial.refresh(accountIDs: [])
        check(partialResult.warning != nil && partialResult.snapshot.games(accountIDs: []).count == 501)
        check(partialFixture.peak <= 4 && partialFixture.peak > 1, "Hydration concurrency must remain bounded")
        let partialWarm = CatalogRepository(service: service, disk: partialDisk)
        let warmStart = Date()
        let cachedPartial = await partialWarm.cached()
        let presentation = await partialWarm.presentation(cachedPartial, accountIDs: [])
        check(presentation.games.count == 501)
        print("Warm 501-title disk decode and projection: \(Int(Date().timeIntervalSince(warmStart) * 1000)) ms")
        partialFixture.failContaining = nil
        let batchesBefore = partialFixture.batches.count
        _ = try await partial.refresh(accountIDs: [])
        check(partialFixture.batches.count == batchesBefore, "Failed batches need retry backoff")
        clock.advance(61)
        let retried = try await partial.refresh(accountIDs: [])
        check(retried.snapshot.games(accountIDs: []).count == 601)
        check(partialFixture.batches.count == batchesBefore + 1, "Retry only missing/stale products")

        let joinedFixture = CatalogFixture(); joinedFixture.ids = ["A"]; joinedFixture.delay = 50_000_000
        CatalogProtocol.fixture = joinedFixture
        let joined = CatalogRepository(service: service, disk: CatalogDiskCache(context: context, directory: root.appendingPathComponent("joined")))
        async let first = joined.refresh(accountIDs: ["X"])
        try await Task.sleep(for: .milliseconds(15))
        async let second = joined.refresh(accountIDs: ["Y"])
        let (_, secondResult) = try await (first, second)
        check(joinedFixture.feeds == 1 && joinedFixture.batches.count == 2)
        check(secondResult.snapshot.games(accountIDs: []).map(\.id) == ["A"], "Shared cache must not retain account-only membership")
        check(secondResult.snapshot.games(accountIDs: ["Y"]).count == 2)

        let ackDisk = CatalogDiskCache(context: context, directory: root.appendingPathComponent("ack"))
        let base = secondResult.snapshot; check(base.context == context)
        try await ackDisk.save(base)
        let ackRepo = CatalogRepository(service: service, disk: ackDisk, now: { clock.now() })
        joinedFixture.ids = ["A", "NEW"]
        let refreshing = Task { try await ackRepo.refresh(accountIDs: [], force: true) }
        try await Task.sleep(for: .milliseconds(15)); clock.advance(1)
        _ = await ackRepo.acknowledgeChanges()
        let ackResult = try await refreshing.value
        check(ackResult.snapshot.changes.isEmpty, "In-flight refresh must respect Mark seen")

        let suite = "PixelCloudX.CatalogCacheTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = GameCatalogStore(repository: warm, defaults: defaults)
        let feedCount = joinedFixture.feeds
        await store.load(refresh: false)
        check(store.games.count == 2 && joinedFixture.feeds == feedCount, "Store must publish the warm catalog without requesting the service")
        joinedFixture.status = 403
        await store.load(force: true)
        check(store.games.count == 2)
        check(store.errorMessage != nil)
        check(!store.isLoading)
        let savedGame = warmSnapshot.games(accountIDs: [])[0]
        store.toggleSaved(savedGame)
        store.recordOpened(savedGame)
        let restoredStore = GameCatalogStore(repository: warm, defaults: defaults)
        check(restoredStore.savedIDs.contains(savedGame.id))
        check(restoredStore.recentIDs.first == savedGame.id)
        defaults.removePersistentDomain(forName: suite)

        let artFixture = CatalogFixture(); artFixture.imageData = makePNG(); CatalogProtocol.fixture = artFixture
        let artRoot = root.appendingPathComponent("artwork")
        let artwork = CatalogArtworkCache(directory: artRoot, session: session)
        let url = URL(string: "https://artwork.invalid/cover.png")!
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 { group.addTask { await artwork.image(for: url, maximumPixelSize: 64) != nil } }
            for await success in group { check(success) }
        }
        check(artFixture.images == 1, "Identical artwork requests must coalesce")
        artFixture.status = 403
        let offlineArtwork = CatalogArtworkCache(directory: artRoot, session: session)
        let offlineImage = await offlineArtwork.image(for: url, maximumPixelSize: 64)
        check(offlineImage?.image.width == 64 && artFixture.images == 1, "Restart must display disk artwork offline")
        let coverFile = try FileManager.default.contentsOfDirectory(at: artRoot, includingPropertiesForKeys: nil)[0]
        try Data("not an image".utf8).write(to: coverFile)
        artFixture.status = 200
        let repairingArtwork = CatalogArtworkCache(directory: artRoot, session: session)
        check(await repairingArtwork.image(for: url, maximumPixelSize: 64) != nil, "Corrupt artwork must be fetched again")
        check(artFixture.images == 2)
        artFixture.status = 403
        check(await artwork.image(for: URL(string: "http://artwork.invalid/a")!, maximumPixelSize: 64) == nil)
        let badURL = URL(string: "https://artwork.invalid/missing.png")!
        check(await artwork.image(for: badURL, maximumPixelSize: 64) == nil)
        let failedCount = artFixture.images
        _ = await artwork.image(for: badURL, maximumPixelSize: 64)
        check(artFixture.images == failedCount, "Artwork failures need retry backoff")
        let stale = CatalogArtworkCache(directory: artRoot, session: session, freshness: -1)
        let staleStart = Date()
        check(await stale.image(for: url, maximumPixelSize: 64) != nil, "Stale artwork must remain available during revalidation")
        check(Date().timeIntervalSince(staleStart) < 0.2)
        try await Task.sleep(for: .milliseconds(40))
        artFixture.status = 200
        let limitedRoot = root.appendingPathComponent("limited-artwork")
        let limited = CatalogArtworkCache(directory: limitedRoot, session: session, diskLimit: artFixture.imageData.count + 1)
        _ = await limited.image(for: url, maximumPixelSize: 64)
        _ = await limited.image(for: URL(string: "https://artwork.invalid/second.png")!, maximumPixelSize: 64)
        let files = try FileManager.default.contentsOfDirectory(at: limitedRoot, includingPropertiesForKeys: [.fileSizeKey])
        let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        check(size <= artFixture.imageData.count + 1 && files.count == 1, "Artwork disk eviction must enforce its budget")
        print("PASS: warm/offline catalog, freshness/304, incremental changes/removals, malformed products, partial batches, bounded concurrency, retry backoff, account isolation, corruption/version fallback, refresh coalescing, Mark seen race, artwork persistence/coalescing/downsampling/eviction")
    }

    private static func makePNG() -> Data {
        let context = CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 512,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); check(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
