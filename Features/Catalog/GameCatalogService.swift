import Foundation
import Combine

struct CatalogContext: Codable, Equatable, Sendable {
    let market: String
    let language: String
    let feedID: String
    let hydration: String
    init(market: String = Locale.current.region?.identifier.uppercased() ?? "US",
         language: String = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")) {
        self.market = market
        self.language = language
        feedID = "29a81209-df6f-41fd-a528-2ae6b91f719c"
        hydration = "RemoteHighSapphire0"
    }
}

enum GameCatalogError: LocalizedError {
    case invalidFeed, invalidHydrationResponse, httpStatus(Int), invalidCache
    var errorDescription: String? {
        switch self {
        case .invalidFeed: "Xbox returned an unreadable cloud-game list."
        case .invalidHydrationResponse: "Xbox returned unreadable game details."
        case .httpStatus(let status): "Xbox catalog request failed (HTTP \(status))."
        case .invalidCache: "The saved catalog could not be read."
        }
    }
}

struct CatalogFeedResult: Sendable {
    let productIDs: [String]?
    let etag: String?
    let lastModified: String?
}

struct GameCatalogService: Sendable {
    let context: CatalogContext
    private let session: URLSession
    init(context: CatalogContext = CatalogContext(), session: URLSession? = nil) {
        self.context = context
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    func fetchFeed(etag: String?, lastModified: String?) async throws -> CatalogFeedResult {
        var components = URLComponents(string: "https://catalog.gamepass.com/sigls/v2")!
        components.queryItems = [URLQueryItem(name: "id", value: context.feedID),
                                URLQueryItem(name: "language", value: context.language),
                                URLQueryItem(name: "market", value: context.market)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        let (data, response) = try await send(request)
        if response.statusCode == 304 {
            return CatalogFeedResult(productIDs: nil, etag: response.value(forHTTPHeaderField: "ETag"),
                                     lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
        }
        try validate(response)
        guard data.count <= 8 * 1_024 * 1_024,
              let feed = try? JSONDecoder().decode([CatalogFeedEntry].self, from: data) else { throw GameCatalogError.invalidFeed }
        let ids = Self.normalizedIDs(feed.compactMap(\.id))
        guard !ids.isEmpty, ids.count <= 20_000 else { throw GameCatalogError.invalidFeed }
        return CatalogFeedResult(productIDs: ids, etag: response.value(forHTTPHeaderField: "ETag"),
                                 lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    func fetchProducts(_ productIDs: [String]) async throws -> [String: CatalogProduct] {
        var components = URLComponents(string: "https://catalog.gamepass.com/v3/products")!
        components.queryItems = [URLQueryItem(name: "market", value: context.market),
                                URLQueryItem(name: "language", value: context.language),
                                URLQueryItem(name: "hydration", value: context.hydration)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0.0", forHTTPHeaderField: "ms-cv")
        request.setValue("Xbox Cloud Gaming Web", forHTTPHeaderField: "calling-app-name")
        request.setValue("21.0.0", forHTTPHeaderField: "calling-app-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Products": productIDs])
        let (data, response) = try await send(request)
        try validate(response)
        guard data.count <= 16 * 1_024 * 1_024,
              let result = try? JSONDecoder().decode(CatalogHydrationResponse.self, from: data) else { throw GameCatalogError.invalidHydrationResponse }
        let requested = Set(productIDs)
        return Dictionary(result.products.compactMap { id, product in
            let normalized = id.uppercased()
            return requested.contains(normalized) ? (normalized, product) : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    static func normalizedIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0.count <= 128 && seen.insert($0).inserted }
    }
    private func validate(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw GameCatalogError.httpStatus(response.statusCode) }
    }
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var retry = 0
        while true {
            try Task.checkCancellation()
            var delay = 0.5 * Double(1 << retry)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw GameCatalogError.httpStatus(-1) }
                if ![408, 429, 500, 502, 503, 504].contains(http.statusCode) || retry >= 2 { return (data, http) }
                delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? delay
            } catch let error as URLError {
                guard [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                       .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(error.code), retry < 2 else { throw error }
            }
            retry += 1
            try await Task.sleep(for: .seconds(min(max(delay, 0.25), 15)))
        }
    }
}

