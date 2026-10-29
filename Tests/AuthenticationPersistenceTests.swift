import Foundation

// Coordinator isolation: real auth, storage, and account services with a fake
// HTTP transport; media is excluded from these authentication tests.
@MainActor final class ControllerInputService {}
@MainActor final class XboxCloudStreamController {
    var isActive = false
    var tokenTask: Task<String, Error>?
    func stop() async { tokenTask?.cancel() }
    func start(game: CloudGame, account: XboxCloudAccountSession, controllerInput: ControllerInputService,
               connectTokenProvider: @escaping @Sendable () async throws -> String) {
        tokenTask = Task { try await connectTokenProvider() }
    }
}

private final class AuthRequestProtocol: URLProtocol {
    enum Mode { case success, offline, serverError, invalidGrant, malformed }
    static var mode = Mode.success
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        let status: Int
        let payload: [String: Any]
        if host == "login.microsoftonline.com" {
            precondition(request.formFields()["refresh_token"] == "old+refresh&= %", "Form encoding must preserve refresh-token punctuation")
            switch Self.mode {
            case .offline:
                client!.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            case .serverError: (status, payload) = (503, ["error": "temporarily_unavailable"])
            case .invalidGrant: (status, payload) = (400, ["error": "invalid_grant"])
            case .malformed: (status, payload) = (200, [:])
            case .success: (status, payload) = (200, ["access_token": "new-access", "refresh_token": "rotated+refresh&=", "expires_in": 3600])
            }
        } else if host == "login.live.com" {
            // Check purpose-specific transfer exchange without exposing tokens.
            let fields = request.formFields()
            precondition(fields["scope"] == "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN")
            precondition(fields["refresh_token"] == "rotated+refresh&=")
            (status, payload) = (200, ["access_token": "console-transfer", "refresh_token": "transfer-rotated-refresh", "expires_in": 3600])
        } else if host == "user.auth.xboxlive.com" {
            (status, payload) = (200, ["Token": "user-token", "DisplayClaims": ["xui": [["uhs": "hash", "gtg": "Test player"]]]])
        } else if host == "xsts.auth.xboxlive.com" {
            (status, payload) = (200, ["Token": "xsts-token", "DisplayClaims": ["xui": [["uhs": "hash"]]]])
        } else if request.url!.path == "/v2/login/user" {
            (status, payload) = (200, ["gsToken": "service-token"])
        } else if request.url!.path == "/v2/titles" {
            (status, payload) = (200, ["titles": []])
        } else { preconditionFailure("Unexpected authentication request: \(host)") }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


private extension URLRequest {
    func formFields() -> [String: String] {
        var data = httpBody ?? Data()
        if data.isEmpty, let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "+", with: " ")
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

@main
@MainActor
private enum AuthenticationPersistenceTests {
    static func main() async throws {
        // Only synthetic credentials are written inside this generated test fixture.
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AuthenticationTestFixture")
        let file = directory.appendingPathComponent("microsoft-auth.json")
        let store = LocalAuthTokenStore(fileURL: file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let auth = MicrosoftDeviceCodeAuthService(session: session, clientID: "00000000-0000-0000-0000-000000000001")
        let account = XboxCloudAccountService(session: session)
        let expired = StoredMicrosoftTokens(accessToken: "old-access", refreshToken: "old+refresh&= %", expiresAt: .distantPast)

        for mode in [AuthRequestProtocol.Mode.offline, .serverError, .malformed] {
            try await store.save(expired)
            AuthRequestProtocol.mode = mode
            let coordinator = AppCoordinator(tokenStore: LocalAuthTokenStore(fileURL: file), authService: auth, xboxAccountService: account)
            await coordinator.onAppear()
            precondition(coordinator.isSignedIn, "Temporary refresh failure must retain the signed-in account")
            precondition(coordinator.xboxAccount == nil)
            precondition(coordinator.xboxServiceErrorMessage != nil)
            let retained = await store.load()
            precondition(retained?.refreshToken == expired.refreshToken)
            // Retry in the same app session must recover and persist rotation.
            AuthRequestProtocol.mode = .success
            await coordinator.reconnectXboxServices()
            precondition(coordinator.xboxAccount?.gamertag == "Test player")
            let renewed = await store.load()
            precondition(renewed?.accessToken == "new-access")
            precondition(renewed?.refreshToken == "rotated+refresh&=")
        }

        // A second coordinator/store instance represents a fresh app launch.
        let restored = AppCoordinator(tokenStore: LocalAuthTokenStore(fileURL: file), authService: auth, xboxAccountService: account)
        await restored.onAppear()
        precondition(restored.isSignedIn && restored.xboxAccount != nil)
        let game = CloudGame(id: "test", title: "test", description: "", publisher: nil, developer: nil,
                             releaseDate: nil, tileArtworkURL: nil, posterArtworkURL: nil, heroArtworkURL: nil,
                             supportedInputs: [], cloudOfferingIDs: [], xCloudTitleID: "test")
        restored.startStream(game: game, controllerInput: ControllerInputService())
        let transfer = try await restored.streamController.tokenTask!.value
        precondition(transfer == "console-transfer")
        let afterTransfer = await store.load()
        precondition(afterTransfer?.accessToken == "new-access", "Transfer credential must not replace the OAuth access token")
        precondition(afterTransfer?.refreshToken == "transfer-rotated-refresh")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        precondition(directoryPermissions.intValue == 0o700)

        AuthRequestProtocol.mode = .invalidGrant
        try await store.save(expired)
        let revoked = AppCoordinator(tokenStore: store, authService: auth, xboxAccountService: account)
        await revoked.onAppear()
        precondition(!revoked.isSignedIn && revoked.lastAuthError != nil, "Revoked authorization requires interactive sign-in")
        // Explicit sign-out removes the cache, unlike temporary network errors.
        await revoked.signOut()
        let cleared = await store.load()
        precondition(cleared == nil)
        print("PASS: fresh-launch restoration, offline/503/malformed refresh retention, reconnect, rotation, cloud transfer, permissions, revoked authorization, sign-out")
    }
}
