import Foundation

struct MicrosoftDeviceCodeChallenge: Identifiable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int

    var id: String { deviceCode }
}

enum MicrosoftAuthError: LocalizedError, Sendable {
    case missingClientID
    case invalidResponse(String)
    case authorizationDeclined
    case authorizationExpired
    case localStorage(String)
    case reauthenticationRequired
    case serviceRejected(code: String, message: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Microsoft sign-in is not configured for this build."
        case .invalidResponse(let message):
            message
        case .authorizationDeclined:
            "Microsoft account authorization was declined."
        case .authorizationExpired:
            "The Microsoft sign-in code expired. Start sign-in again."
        case .localStorage(let message):
            "Could not save the local sign-in file: \(message)"
        case .reauthenticationRequired:
            "Microsoft needs you to sign in again to renew this account's authorization."
        case .serviceRejected(let code, let message, _):
            "\(code): \(message)"
        }
    }
}

struct MicrosoftDeviceCodeAuthService {
    static let clientIDInfoPlistKey = "PixelCloudXMicrosoftClientID"
    private static let scope = "xboxlive.signin openid profile offline_access"

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let verificationURIComplete: String?
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private let session: URLSession
    private let clientID: String?

    init(session: URLSession = .shared, clientID: String? = Self.configuredClientID()) {
        self.session = session
        self.clientID = clientID
    }

    static var isConfigured: Bool {
        configuredClientID() != nil
    }

    func requestDeviceCode() async throws -> MicrosoftDeviceCodeChallenge {
        guard let clientID else {
            throw MicrosoftAuthError.missingClientID
        }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": clientID,
            "scope": Self.scope
        ])

        let response = try await send(request)
        let decoded = try JSONDecoder().decode(DeviceCodeResponse.self, from: response)
        return MicrosoftDeviceCodeChallenge(
            deviceCode: decoded.deviceCode,
            userCode: decoded.userCode,
            verificationURI: decoded.verificationURI,
            verificationURIComplete: decoded.verificationURIComplete,
            expiresIn: decoded.expiresIn,
            interval: max(1, decoded.interval)
        )
    }

    func completeSignIn(_ challenge: MicrosoftDeviceCodeChallenge) async throws -> StoredMicrosoftTokens {
        let deadline = Date().addingTimeInterval(TimeInterval(challenge.expiresIn))
        var pollInterval = max(1, challenge.interval)

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let token = try await pollToken(deviceCode: challenge.deviceCode)
                guard let accessToken = token.accessToken else {
                    throw MicrosoftAuthError.invalidResponse("Microsoft returned no access token.")
                }
                return StoredMicrosoftTokens(
                    accessToken: accessToken,
                    refreshToken: token.refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3_600))
                )
            } catch DeviceCodePollError.pending {
                try await Task.sleep(for: .seconds(pollInterval))
            } catch DeviceCodePollError.slowDown {
                pollInterval += 5
                try await Task.sleep(for: .seconds(pollInterval))
            }
        }

        throw MicrosoftAuthError.authorizationExpired
    }

    func refresh(_ tokens: StoredMicrosoftTokens) async throws -> StoredMicrosoftTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw MicrosoftAuthError.reauthenticationRequired
        }
        guard let clientID else { throw MicrosoftAuthError.missingClientID }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.scope
        ])

        do {
            let response = try await send(request)
            let token = try JSONDecoder().decode(TokenResponse.self, from: response)
            guard let accessToken = token.accessToken, !accessToken.isEmpty else {
                throw MicrosoftAuthError.invalidResponse("Microsoft returned no access token while renewing sign-in.")
            }
            return StoredMicrosoftTokens(
                accessToken: accessToken,
                refreshToken: token.refreshToken ?? refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3_600))
            )
        } catch let MicrosoftAuthError.serviceRejected(code, _, _) where
            ["invalid_grant", "interaction_required", "login_required"].contains(code) {
            throw MicrosoftAuthError.reauthenticationRequired
        }
    }

    /// GSSV bearer tokens authorize the service API; the console /connect
    /// exchange instead requires Microsoft's purpose-scoped transfer token.
    func cloudTransferToken(using tokens: StoredMicrosoftTokens) async throws -> (token: String, tokens: StoredMicrosoftTokens) {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw MicrosoftAuthError.reauthenticationRequired
        }
        guard let clientID else { throw MicrosoftAuthError.missingClientID }
        var request = URLRequest(url: URL(string: "https://login.live.com/oauth20_token.srf")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"
        ])
        let response = try await send(request)
        let result = try JSONDecoder().decode(TokenResponse.self, from: response)
        guard let transferToken = result.accessToken, !transferToken.isEmpty else {
            throw MicrosoftAuthError.invalidResponse("Microsoft returned no Xbox cloud-transfer token.")
        }
        return (transferToken, StoredMicrosoftTokens(
            accessToken: tokens.accessToken,
            refreshToken: result.refreshToken ?? refreshToken,
            expiresAt: tokens.expiresAt
        ))
    }

    private enum DeviceCodePollError: Error {
        case pending
        case slowDown
    }

    private func pollToken(deviceCode: String) async throws -> TokenResponse {
        guard let clientID else {
            throw MicrosoftAuthError.missingClientID
        }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "client_id": clientID,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode
        ])

        do {
            let response = try await send(request)
            let token = try JSONDecoder().decode(TokenResponse.self, from: response)
            guard token.accessToken != nil else {
                throw MicrosoftAuthError.invalidResponse("Microsoft returned no access token.")
            }
            return token
        } catch let error as DeviceCodePollError {
            throw error
        } catch let error as MicrosoftAuthError {
            if case .serviceRejected(let code, _, _) = error {
                if code == "authorization_pending" { throw DeviceCodePollError.pending }
                if code == "slow_down" { throw DeviceCodePollError.slowDown }
                if code == "authorization_declined" { throw MicrosoftAuthError.authorizationDeclined }
                if code == "expired_token" { throw MicrosoftAuthError.authorizationExpired }
            }
            throw error
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.invalidResponse("Microsoft returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw MicrosoftAuthError.serviceRejected(code: error.error, message: error.errorDescription ?? "",
                                                         status: http.statusCode)
            }
            throw MicrosoftAuthError.invalidResponse("Microsoft request failed (HTTP \(http.statusCode)).")
        }
        return data
    }

    static func configuredClientID() -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: clientIDInfoPlistKey) as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        // URLComponents leaves '+' literal; form decoders interpret it as a
        // space, which corrupts refresh tokens containing plus signs.
        return components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
    }
}
