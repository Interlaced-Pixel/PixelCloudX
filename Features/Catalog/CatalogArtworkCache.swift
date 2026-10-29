import CryptoKit
import Foundation
import ImageIO

final class CatalogArtwork: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor ArtworkDownloadGate {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}

/// Public artwork only. Disk and decoded-memory limits are independent; the
/// cache never reads authentication storage or attaches account credentials.
actor CatalogArtworkCache {
    static let shared = CatalogArtworkCache()
    let directory: URL
    private let session: URLSession
    private let gate = ArtworkDownloadGate()
    private let memory = NSCache<NSString, CatalogArtwork>()
    private var flights: [String: Task<Data?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private let diskLimit: Int
    private let freshness: TimeInterval
    private var diskBytes = 0
    private var validatedAt: [String: Date] = [:]
    private var variants: [String: Set<String>] = [:]
    private var inspectedDisk = false
    private var generation = 0

    func diskUsage() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "art" }.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() throws {
        generation += 1
        flights.values.forEach { $0.cancel() }
        flights.removeAll()
        memory.removeAllObjects()
        validatedAt.removeAll(); variants.removeAll(); failedAt.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "art" { try FileManager.default.removeItem(at: file) }
        diskBytes = 0
    }

    init(directory: URL? = nil, session: URLSession? = nil, memoryLimit: Int = 32 * 1_024 * 1_024,
         diskLimit: Int = 192 * 1_024 * 1_024, freshness: TimeInterval = 7 * 86_400) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PixelCloudX/Artwork-v1", isDirectory: true)
        self.diskLimit = diskLimit
        self.freshness = freshness
        memory.totalCostLimit = memoryLimit
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 25
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    func image(for url: URL, maximumPixelSize: Int) async -> CatalogArtwork? {
        guard Self.isSafe(url) else { return nil }
        if !inspectedDisk { inspectedDisk = true; prune() }
        let pixelSize = min(1600, max(64, maximumPixelSize))
        let key = Self.key(url)
        let memoryKey = "\(key)-\(pixelSize)" as NSString
        if let image = memory.object(forKey: memoryKey) {
            let age = Date().timeIntervalSince(validatedAt[key] ?? .distantPast)
            if age >= freshness || age < -300 {
                Task { _ = await self.download(url, key: key) }
            }
            return image
        }
        let file = directory.appendingPathComponent(key).appendingPathExtension("art")
        if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           (values.fileSize ?? Int.max) <= 8 * 1_024 * 1_024,
           let data = try? Data(contentsOf: file), let image = Self.decode(data, pixelSize: pixelSize) {
            memory.setObject(image, forKey: memoryKey, cost: image.image.bytesPerRow * image.image.height)
            variants[key, default: []].insert(memoryKey as String)
            validatedAt[key] = values.contentModificationDate ?? .distantPast
            let age = Date().timeIntervalSince(values.contentModificationDate ?? .distantPast)
            if age >= freshness || age < -300 { Task { _ = await self.download(url, key: key) } }
            return image
        }
        guard let data = await download(url, key: key), let image = Self.decode(data, pixelSize: pixelSize) else { return nil }
        memory.setObject(image, forKey: memoryKey, cost: image.image.bytesPerRow * image.image.height)
        variants[key, default: []].insert(memoryKey as String)
        return image
    }

    private func download(_ url: URL, key: String) async -> Data? {
        if let flight = flights[key] { return await flight.value }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 60 { return nil }
        let session = session, gate = gate
        let token = generation
        let task = Task<Data?, Never> {
            await gate.acquire()
            var result: Data?
            do {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let finalURL = http.url, Self.isSafe(finalURL), data.count <= 8 * 1_024 * 1_024,
                   Self.decode(data, pixelSize: 64) != nil { result = data }
            } catch {}
            await gate.release()
            return result
        }
        flights[key] = task
        let data = await task.value
        guard token == generation else { return nil }
        flights[key] = nil
        guard let data else { failedAt[key] = Date(); return nil }
        failedAt[key] = nil
        validatedAt[key] = Date()
        for variant in variants.removeValue(forKey: key) ?? [] { memory.removeObject(forKey: variant as NSString) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(key).appendingPathExtension("art")
            let previousSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try data.write(to: file, options: .atomic)
            diskBytes += data.count - previousSize
            if diskBytes > diskLimit { prune() }
        } catch { /* A read-only/full disk still permits this session's artwork. */ }
        return data
    }

    private static func isSafe(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func decode(_ data: Data, pixelSize: Int) -> CatalogArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return CatalogArtwork(image)
    }
    private func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension == "art" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return nil }
                return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for file in files where total > diskLimit {
            do { try FileManager.default.removeItem(at: file.0); total -= file.1 } catch {}
        }
        diskBytes = total
    }
}
