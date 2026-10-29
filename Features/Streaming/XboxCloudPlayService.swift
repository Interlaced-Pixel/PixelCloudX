import Foundation

final class XboxCorrelationVector: @unchecked Sendable {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    private let lock = NSLock()
    private let base: String
    private var counter: UInt64 = 0

    init() {
        var generator = SystemRandomNumberGenerator()
        base = String((0..<22).compactMap { _ in Self.alphabet.randomElement(using: &generator) })
    }

    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "\(base).\(counter)"
    }

    func increment() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        return "\(base).\(counter)"
    }
}

struct XboxCloudServerDetails: Decodable, Sendable {
    let stunServerAddresses: [String]?
}

struct XboxCloudPlaySession: Sendable {
    let sessionPath: String
    let serviceBaseURL: URL
    let serverDetails: XboxCloudServerDetails
    let keepAliveInterval: TimeInterval
    let correlationVector: XboxCorrelationVector
}

struct XboxRemoteSDPAnswer: Decodable, Sendable {
    let messageType: String?
    let requestId: Int?
    let connectionId: String?
    let status: String
    let sdpType: String
    let sdp: String
    let control: Int?
    let input: Int?
    let message: Int?
    let chat: Int?
    let chatStream: Int?

    private enum CodingKeys: String, CodingKey {
        case messageType, requestId, connectionId, status, sdpType, sdp, control, input, message, chat, chatStream
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messageType = try values.decodeIfPresent(String.self, forKey: .messageType)
        requestId = try values.decodeIfPresent(Int.self, forKey: .requestId)
        connectionId = try values.decodeIfPresent(String.self, forKey: .connectionId)
        status = try values.decode(String.self, forKey: .status)
        sdpType = try values.decode(String.self, forKey: .sdpType)
        sdp = try values.decode(String.self, forKey: .sdp)
        func version(_ key: CodingKeys) throws -> Int? {
            if let number = try? values.decode(Int.self, forKey: key) { return number }
            if let text = try? values.decode(String.self, forKey: key),
               let number = Int(text.split(separator: ".").first.map(String.init) ?? text) { return number }
            if !values.contains(key) { return nil }
            if try values.decodeNil(forKey: key) { return nil }
            throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected a numeric channel version")
        }
        control = try version(.control)
        input = try version(.input)
        message = try version(.message)
        chat = try version(.chat)
        chatStream = try version(.chatStream)
    }
}

enum XboxCloudPlayError: LocalizedError {
    case invalidTitle
    case malformedResponse(String)
    case serviceRejected(String)
    case sessionFailed(String)
    case provisioningTimedOut
    case signalingTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "This catalog entry has no Xbox Cloud Gaming title ID."
        case .malformedResponse(let message):
            message
        case .serviceRejected(let message):
            message
        case .sessionFailed(let message):
            message
        case .provisioningTimedOut:
            "Xbox did not provision the game session before the wait expired."
        case .signalingTimedOut(let channel):
            "Xbox did not return the \(channel) signaling response in time."
        }
    }
}

/// PixelCloudX-owned client for the current Xbox web client's cloud-session
/// request and HTTP WebRTC signaling path. The service contract is private and
/// can change; responses are validated before they are used.
final class XboxCloudPlayService {
    private let session: URLSession
    private let installID: String
    private let correlationVector = XboxCorrelationVector()

    init(session: URLSession = .shared) {
        self.session = session
        let key = "PixelCloudX.sdkInstallId"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil {
            installID = existing
        } else {
            let value = UUID().uuidString
            defaults.set(value, forKey: key)
            installID = value
        }
    }

    func createSession(
        for game: CloudGame,
        offering: XboxCloudOfferingSession,
        preferences: XboxLaunchPreferences = XboxLaunchPreferences(),
        connectTokenProvider: @escaping @Sendable () async throws -> String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> XboxCloudPlaySession {
        guard let titleID = game.xCloudTitleID, !titleID.isEmpty else {
            throw XboxCloudPlayError.invalidTitle
        }

        let locale = preferences.resolvedLocale
        let settings: [String: Any] = [
            // Current Xbox WebRTC clients identify this transport as V3.
            "nanoVersion": "V3;WebrtcTransport.dll",
            "enableTextToSpeech": preferences.textToSpeech,
            "magnifier": preferences.magnifier,
            // Xbox's HighContrastMode is numeric: Off=0, White=1, Black=2.
            // A JSON boolean is rejected by the play request deserializer.
            "highContrast": preferences.highContrast,
            "locale": locale,
            "useIceConnection": false,
            // Xbox uses minutes east of UTC (-JavaScript getTimezoneOffset()).
            "timezoneOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            "sdkType": "web",
            "osName": "macOS",
            "enableOptionalDataCollection": false
        ]
        let body: [String: Any] = [
            "titleId": titleID,
            "systemUpdateGroup": "",
            "settings": settings,
            "serverId": "",
            "fallbackRegionNames": [],
            "clientSessionId": UUID().uuidString
        ]

        progress("Requesting an Xbox cloud session")
        let response = try await requestJSON(
            url: endpoint("v5/sessions/cloud/play", on: offering.serviceBaseURL),
            method: "POST",
            offering: offering,
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let path = response["sessionPath"] as? String, !path.isEmpty else {
            throw XboxCloudPlayError.malformedResponse("Xbox did not return a cloud session path.")
        }

        var serviceBaseURL = offering.serviceBaseURL
        let deadline = Date().addingTimeInterval(240)
        var didSendConnect = false

        do {
            while Date() < deadline {
                try Task.checkCancellation()
                let state = try await requestJSON(
                    url: endpoint("\(path)/state", on: serviceBaseURL),
                    method: "GET",
                    offering: offering
                )
                if let rawTransferURI = state["transferUri"] as? String,
                   let transferURL = Self.normalizedServiceURL(rawTransferURI),
                   Self.isXboxServiceURL(transferURL) {
                    serviceBaseURL = transferURL
                }

                let stateName = (state["state"] as? String ?? "").lowercased()
                switch stateName {
                case "waitingforresources":
                    progress("Waiting for Xbox cloud capacity")
                case "provisioning":
                    progress("Starting \(game.title)")
                case "readytoconnect":
                    if !didSendConnect {
                        progress("Joining the Xbox cloud session")
                        let transferToken = try await connectTokenProvider()
                        try Task.checkCancellation()
                        _ = try await requestJSON(
                            url: endpoint("\(path)/connect", on: serviceBaseURL),
                            method: "POST",
                            offering: offering,
                            // The bearer header remains GSSV; the body authenticates
                            // the cloud console with a Microsoft transfer token.
                            body: try JSONSerialization.data(withJSONObject: ["userToken": transferToken])
                        )
                        didSendConnect = true
                    }
                case "provisioned":
                    progress("Preparing native stream")
                    let configuration = try await requestJSON(
                        url: endpoint("\(path)/configuration", on: serviceBaseURL),
                        method: "GET",
                        offering: offering
                    )
                    guard let serverDetailsObject = configuration["serverDetails"] as? [String: Any] else {
                        throw XboxCloudPlayError.malformedResponse("Xbox did not return WebRTC server details.")
                    }
                    let serverDetailsData = try JSONSerialization.data(withJSONObject: serverDetailsObject)
                    let serverDetails = try JSONDecoder().decode(XboxCloudServerDetails.self, from: serverDetailsData)
                    let keepAlive = configuration["keepAlivePulseInSeconds"] as? Double ?? 30
                    return XboxCloudPlaySession(
                        sessionPath: path,
                        serviceBaseURL: serviceBaseURL,
                        serverDetails: serverDetails,
                        keepAliveInterval: max(10, min(keepAlive, 90)),
                        correlationVector: correlationVector
                    )
                case "failed":
                    throw XboxCloudPlayError.sessionFailed(Self.failureMessage(in: state))
                case "":
                    break
                default:
                    throw XboxCloudPlayError.sessionFailed("Xbox returned an unknown session state: \(stateName).")
                }

                try await Task.sleep(for: .seconds(stateName == "waitingforresources" ? 10 : 2))
            }

            throw XboxCloudPlayError.provisioningTimedOut
        } catch {
            // An allocated session must also be released if provisioning or
            // transfer-token acquisition fails. An unstructured task allows
            // the DELETE to finish even when the caller has been cancelled.
            let cleanupBaseURL = serviceBaseURL
            await Task {
                await end(sessionPath: path, on: cleanupBaseURL, offering: offering)
            }.value
            throw error
        }
    }

    func sendLocalSDP(
        _ offerMessage: [String: Any],
        for cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession
    ) async throws {
        try await sendSignalingMessage(
            offerMessage,
            endpoint: "sdp",
            cloudSession: cloudSession,
            offering: offering
        )
    }

    func waitForRemoteSDP(
        for cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession,
        timeout: TimeInterval = 35,
        expectedRequestID: Int? = nil,
        previousSDP: String? = nil
    ) async throws -> XboxRemoteSDPAnswer {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let response = try await pollSignaling("sdp", cloudSession: cloudSession, offering: offering),
               !response.isEmpty,
               let data = response.data(using: .utf8) {
                let answer: XboxRemoteSDPAnswer
                do {
                    answer = try JSONDecoder().decode(XboxRemoteSDPAnswer.self, from: data)
                } catch {
                    // Decoding errors describe only field paths/types. Do not
                    // log the SDP, which can contain private network addresses.
                    NSLog("PixelCloudX SDP answer decoding failed: %@", String(describing: error))
                    throw XboxCloudPlayError.malformedResponse("Xbox returned an incompatible stream answer.")
                }
                if let expectedRequestID,
                   (answer.requestId.map { $0 != expectedRequestID } ?? (previousSDP == nil || answer.sdp == previousSDP)) {
                    // HTTP polling may still expose the previous negotiation's answer.
                    try await Task.sleep(for: .milliseconds(140))
                    continue
                }
                guard answer.status.lowercased() == "success" else {
                    throw XboxCloudPlayError.serviceRejected("Xbox rejected the WebRTC offer (\(answer.status)).")
                }
                guard answer.sdpType.lowercased() == "answer", !answer.sdp.isEmpty else {
                    throw XboxCloudPlayError.malformedResponse("Xbox returned an invalid WebRTC SDP answer.")
                }
                return answer
            }
            try await Task.sleep(for: .milliseconds(140))
        }
        throw XboxCloudPlayError.signalingTimedOut("SDP")
    }

    func exchangeLocalICE(
        _ candidates: [[String: Any]],
        includesEndOfCandidates: Bool,
        for cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession
    ) async throws -> [String] {
        // The HTTP signaling endpoint expects candidate.toJSON() values to be
        // individually JSON encoded inside the candidates array. The whole
        // array is the JSON HTTP body. Data is an internal client wrapper,
        // not a property in the service's wire format.
        var candidateMessages = candidates.compactMap { candidate -> String? in
            guard JSONSerialization.isValidJSONObject(candidate),
                  let data = try? JSONSerialization.data(withJSONObject: candidate) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if includesEndOfCandidates {
            candidateMessages.append("a=end-of-candidates")
        }
        let payload = try JSONSerialization.data(withJSONObject: ["candidates": candidateMessages])
        let jsonText = String(decoding: payload, as: UTF8.self)
        try await sendSignalingText(jsonText, endpoint: "ice", cloudSession: cloudSession, offering: offering)

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try Task.checkCancellation()
            if let responseText = try await pollSignaling("ice", cloudSession: cloudSession, offering: offering),
               !responseText.isEmpty,
               let data = responseText.data(using: .utf8) {
                let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                if let candidates = decoded as? [String] { return candidates }
                if let records = decoded as? [[String: Any]] {
                    return records.compactMap { record in
                        guard let candidate = record["candidate"] as? String else { return nil }
                        return String(data: (try? JSONSerialization.data(withJSONObject: record)) ?? Data(), encoding: .utf8)
                            ?? candidate
                    }
                }
                if decoded is NSNull { return [] }
                throw XboxCloudPlayError.malformedResponse("Xbox returned an unexpected ICE response shape.")
            }
            try await Task.sleep(for: .milliseconds(140))
        }
        throw XboxCloudPlayError.signalingTimedOut("ICE")
    }

    func keepAlive(_ cloudSession: XboxCloudPlaySession, offering: XboxCloudOfferingSession) async throws {
        _ = try await requestJSON(
            url: endpoint("\(cloudSession.sessionPath)/keepalive", on: cloudSession.serviceBaseURL),
            method: "POST",
            offering: offering
        )
    }

    func end(_ cloudSession: XboxCloudPlaySession, offering: XboxCloudOfferingSession) async {
        await Task {
            await end(sessionPath: cloudSession.sessionPath, on: cloudSession.serviceBaseURL, offering: offering)
        }.value
    }

    private func end(sessionPath: String, on serviceBaseURL: URL, offering: XboxCloudOfferingSession) async {
        var request = makeRequest(
            url: endpoint(sessionPath, on: serviceBaseURL),
            method: "DELETE",
            offering: offering
        )
        request.timeoutInterval = 8
        _ = try? await session.data(for: request)
    }

    private func sendSignalingMessage(
        _ message: [String: Any],
        endpoint path: String,
        cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession
    ) async throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        let text = String(decoding: payload, as: UTF8.self)
        try await sendSignalingText(text, endpoint: path, cloudSession: cloudSession, offering: offering)
    }

    private func sendSignalingText(
        _ value: String,
        endpoint path: String,
        cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession
    ) async throws {
        // Xbox PlayService sends r.Data itself as the HTTP body. Wrapping it
        // again in {Data: ...} hides messageType/sdp/candidates from the server.
        let body = Data(value.utf8)
        _ = try await requestJSON(
            url: endpoint("\(cloudSession.sessionPath)/\(path)", on: cloudSession.serviceBaseURL),
            method: "POST",
            offering: offering,
            body: body
        )
    }

    private func pollSignaling(
        _ path: String,
        cloudSession: XboxCloudPlaySession,
        offering: XboxCloudOfferingSession
    ) async throws -> String? {
        let url = endpoint("\(cloudSession.sessionPath)/\(path)", on: cloudSession.serviceBaseURL)
        var request = makeRequest(url: url, method: "GET", offering: offering)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XboxCloudPlayError.malformedResponse("Xbox signaling returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.rejected(data: data, status: http.statusCode)
        }
        guard !data.isEmpty else { return nil }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let object = decoded as? [String: Any] {
            if let details = object["errorDetails"] as? [String: Any], !details.isEmpty {
                throw XboxCloudPlayError.serviceRejected(Self.failureMessage(in: object))
            }
            if let text = object["exchangeResponse"] as? String { return text }
            if let value = object["exchangeResponse"], JSONSerialization.isValidJSONObject(value) {
                return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            }
            throw XboxCloudPlayError.malformedResponse("Xbox returned no \(path.uppercased()) signaling answer.")
        }
        return decoded as? String
    }

    private func requestJSON(
        url: URL,
        method: String,
        offering: XboxCloudOfferingSession,
        body: Data? = nil
    ) async throws -> [String: Any] {
        var request = makeRequest(url: url, method: method, offering: offering)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XboxCloudPlayError.malformedResponse("Xbox returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.rejected(data: data, status: http.statusCode)
        }
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XboxCloudPlayError.malformedResponse("Xbox returned an unexpected response shape.")
        }
        return object
    }

    private func makeRequest(url: URL, method: String, offering: XboxCloudOfferingSession) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(offering.serviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("XboxComBrowser", forHTTPHeaderField: "X-Gssv-Client")
        request.setValue("AFD", forHTTPHeaderField: "X-GSSV-Routing")
        request.setValue(correlationVector.increment(), forHTTPHeaderField: "ms-cv")
        request.setValue(Self.deviceInfo(installID: installID), forHTTPHeaderField: "X-MS-Device-Info")
        request.timeoutInterval = 18
        return request
    }

    private func endpoint(_ path: String, on baseURL: URL) -> URL {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: normalized, relativeTo: baseURL.appendingPathComponent(""))?.absoluteURL
            ?? baseURL.appendingPathComponent(normalized)
    }

    private static func normalizedServiceURL(_ value: String) -> URL? {
        if let parsed = URL(string: value), parsed.scheme != nil { return parsed }
        return URL(string: "https://\(value)")
    }

    private static func isXboxServiceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "xboxlive.com" || host.hasSuffix(".xboxlive.com")
    }

    private static func deviceInfo(installID: String) -> String {
        let value: [String: Any] = [
            "appInfo": [
                "env": [
                    "clientAppId": "com.jayian.pixelcloudx",
                    "clientAppType": "native",
                    "clientAppVersion": "1.0",
                    "clientSdkVersion": "PixelCloudX/1",
                    "httpEnvironment": "prod",
                    "sdkInstallId": installID
                ]
            ],
            "dev": [
                "displayInfo": ["dimensions": ["heightInPixels": 0, "widthInPixels": 0],
                                "pixelDensity": ["dpiX": 1, "dpiY": 1]],
                "browser": ["browserName": "", "browserVersion": ""],
                "hw": ["make": "Apple", "model": "Mac", "platformType": "macOS", "sdkType": "native"],
                "os": ["name": "macOS", "ver": ProcessInfo.processInfo.operatingSystemVersionString, "platform": "macOS"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func rejected(data: Data, status: Int) -> XboxCloudPlayError {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return .serviceRejected(failureMessage(in: root ?? [:],
            fallback: "Xbox Cloud Gaming request failed (HTTP \(status))."))
    }

    private static func failureMessage(in response: [String: Any],
                                       fallback: String = "Xbox reported that the game session failed.") -> String {
        let details = response["errorDetails"] as? [String: Any] ?? [:]
        let message = [details["message"], details["Message"], response["errorMessage"],
                       response["message"], response["Message"]]
            .compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let code = details["code"] ?? response["code"]
        let codeText = (code as? String) ?? (code as? NSNumber)?.stringValue
        if let codeText, !codeText.isEmpty { return "\(message ?? fallback) (Xbox: \(codeText))" }
        return message ?? fallback
    }
}
