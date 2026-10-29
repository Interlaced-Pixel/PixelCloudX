import AppKit
import Foundation

private final class GravatarProtocol: URLProtocol {
    enum Mode { case found, avatarOnly, missing, rateLimited, offline }
    static var mode = Mode.found
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZdEAAAAASUVORK5CYII=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil, "Never send Xbox credentials to Gravatar")
        let isAvatar = request.url!.host == "gravatar.com"
        let status: Int
        let data: Data
        switch Self.mode {
        case .offline:
            client!.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        case .rateLimited: (status, data) = (429, Data())
        case .missing: (status, data) = (404, Data())
        case .avatarOnly where !isAvatar: (status, data) = (404, Data())
        default:
            status = 200
            data = isAvatar ? Self.png : Data(#"{"display_name":"Test player","description":"Hello","location":"Test city","profile_url":"https://gravatar.com/test","verified_accounts":[{"service_label":"Test","url":"https://example.com","is_hidden":false}]}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": isAvatar ? "image/png" : "application/json"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor
private enum GravatarTests {
    static func main() async throws {
        let expected = "973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b"
        let hash = try GravatarService.identifier(for: "  Test@Example.COM\n")
        precondition(hash == expected)
        do { _ = try GravatarService.identifier(for: "bad"); preconditionFailure() } catch {}
        do { _ = try GravatarService.avatarURL(identifier: "../bad"); preconditionFailure() } catch {}
        let url = try GravatarService.avatarURL(identifier: hash, size: 9000)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(items.contains(URLQueryItem(name: "s", value: "2048")))
        precondition(items.contains(URLQueryItem(name: "d", value: "404")))
        precondition(GravatarProfile.webURL("javascript:alert(1)") == nil)
        precondition(GravatarProfile.webURL("https://user:password@example.com") == nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GravatarProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = GravatarService(session: session)
        let suite = "com.jayian.pixelcloudx.gravatar-regression"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GravatarStore(defaults: defaults, service: service)
        try store.connect(email: "test@example.com")
        await store.refresh()
        precondition(store.image != nil && store.profile?.displayName == "Test player")
        precondition(store.profile?.verifiedAccounts?.first?.serviceLabel == "Test")
        precondition(!defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "test@example.com" })
        let restored = GravatarStore(defaults: defaults, service: service)
        precondition(restored.identifier == hash)
        GravatarProtocol.mode = .avatarOnly
        await restored.refresh()
        precondition(restored.image != nil && restored.profile == nil, "Missing profile must not discard a secondary-email avatar")
        GravatarProtocol.mode = .offline
        await store.refresh()
        precondition(store.image != nil && store.status != nil, "Transient failure must retain the last avatar")
        GravatarProtocol.mode = .rateLimited
        await store.refresh()
        precondition(store.status?.contains("too many requests") == true)
        GravatarProtocol.mode = .missing
        await store.refresh()
        precondition(store.image == nil && store.profile == nil && store.status != nil)
        store.disconnect()
        precondition(GravatarStore(defaults: defaults, service: service).identifier == nil)
        print("PASS: Gravatar SHA-256 normalization, URL bounds, safe links, native avatar/profile decoding, hash persistence, avatar-only accounts, offline/404/429 fallback, disconnect")
    }
}
