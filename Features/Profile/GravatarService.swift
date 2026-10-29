import CryptoKit
import Foundation

struct GravatarProfile: Decodable, Sendable {
    let displayName: String?
    let description: String?
    let location: String?
    let pronouns: String?
    let profileURL: String?
    let verifiedAccounts: [VerifiedAccount]?

    struct VerifiedAccount: Decodable, Sendable {
        let serviceLabel: String?
        let url: String?
        let isHidden: Bool?
        enum CodingKeys: String, CodingKey {
            case serviceLabel = "service_label", url, isHidden = "is_hidden"
        }
    }
    enum CodingKeys: String, CodingKey {
        case displayName = "display_name", description, location, pronouns
        case profileURL = "profile_url", verifiedAccounts = "verified_accounts"
    }

    static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

enum GravatarError: LocalizedError {
    case invalidEmail, invalidIdentifier, rateLimited, unavailable, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidEmail: "Enter the email address associated with your Gravatar."
        case .invalidIdentifier: "Reconnect your Gravatar to update this profile."
        case .rateLimited: "Gravatar is receiving too many requests. Try refreshing later."
        case .unavailable: "Gravatar is unavailable. You can refresh it later."
        case .invalidImage: "Gravatar returned an unreadable avatar."
        }
    }
}

struct GravatarService: Sendable {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1_024 * 1_024, diskCapacity: 12 * 1_024 * 1_024)
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
    }

    static func identifier(for email: String) throws -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !normalized.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw GravatarError.invalidEmail }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func avatarURL(identifier: String, size: Int = 160) throws -> URL {
        guard isValidIdentifier(identifier) else { throw GravatarError.invalidIdentifier }
        var url = URLComponents(string: "https://gravatar.com/avatar/\(identifier)")!
        url.queryItems = [URLQueryItem(name: "s", value: String(min(2048, max(1, size)))),
                          URLQueryItem(name: "d", value: "404"), URLQueryItem(name: "r", value: "g")]
        return url.url!
    }

    func avatar(identifier: String) async throws -> Data? {
        try await get(Self.avatarURL(identifier: identifier), maximumSize: 2 * 1_024 * 1_024)
    }

    func profile(identifier: String) async throws -> GravatarProfile? {
        guard Self.isValidIdentifier(identifier) else { throw GravatarError.invalidIdentifier }
        guard let data = try await get(URL(string: "https://api.gravatar.com/v3/profiles/\(identifier)")!, maximumSize: 256 * 1_024) else { return nil }
        return try JSONDecoder().decode(GravatarProfile.self, from: data)
    }

    private func get(_ url: URL, maximumSize: Int) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("PixelCloudX/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GravatarError.unavailable }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 429 { throw GravatarError.rateLimited }
        guard (200..<300).contains(http.statusCode), data.count <= maximumSize else { throw GravatarError.unavailable }
        return data
    }
}
