import CoreFoundation
import Foundation

private final class PlayScenario: @unchecked Sendable {
    enum Mode { case success, failedState, rejectedConnect, cancelledTransfer, signalingError }
    let mode: Mode
    private let lock = NSLock()
    private var polls = 0
    private var sdpRequest = 1
    private var sdpPolls = 0
    var staleMicrophoneAnswer = false
    var omitMicrophoneRequestID = false
    private(set) var connects = 0
    private(set) var deletes = 0

    init(_ mode: Mode) { self.mode = mode }

    func response(to request: URLRequest) throws -> (Int, [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-gssv-token")
        switch (request.httpMethod!, request.url!.path) {
        case ("POST", "/v5/sessions/cloud/play"):
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            let settings = body["settings"] as! [String: Any]
            let highContrast = settings["highContrast"] as! NSNumber
            precondition(CFGetTypeID(highContrast) != CFBooleanGetTypeID(), "highContrast must be a JSON number")
            precondition(highContrast.intValue == 0)
            precondition(settings["timezoneOffsetMinutes"] as? Int == TimeZone.current.secondsFromGMT() / 60)
            precondition(settings["nanoVersion"] as? String == "V3;WebrtcTransport.dll")
            precondition(body["titleId"] as? String == "TEST-TITLE")
            return (200, ["sessionPath": "v5/sessions/cloud/test-session"])
        case ("GET", "/v5/sessions/cloud/test-session/state"):
            polls += 1
            if mode == .failedState {
                return (200, ["state": "Failed", "errorDetails": ["code": "NoEntitlement", "message": "This account cannot play this title."]])
            }
            return (200, ["state": polls < 3 ? "ReadyToConnect" : "Provisioned"])
        case ("POST", "/v5/sessions/cloud/test-session/connect"):
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            precondition(body["userToken"] as? String == "test-transfer-token", "GSSV is not the console transfer token")
            connects += 1
            if mode == .rejectedConnect {
                return (403, ["errorDetails": ["code": "TransferRejected", "message": "Transfer token rejected."]])
            }
            return (200, [:])
        case ("GET", "/v5/sessions/cloud/test-session/configuration"):
            return (200, ["serverDetails": ["stunServerAddresses": ["stun:test.invalid:3478"]], "keepAlivePulseInSeconds": 30])
        case ("POST", "/v5/sessions/cloud/test-session/sdp"):
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            precondition(body["Data"] == nil, "Internal Data wrapper must not reach the wire")
            precondition(body["messageType"] as? String == "offer")
            precondition(body["sdp"] as? String == "v=0\r\n")
            if body["requestId"] as? Int == 2 {
                precondition((body["configuration"] as? [String: Bool])?["isMediaStreamsChatRenegotiation"] == true)
                sdpRequest = 2; sdpPolls = 0
            }
            return (200, [:])
        case ("GET", "/v5/sessions/cloud/test-session/sdp"):
            if mode == .signalingError { return (200, ["errorDetails": ["code": "InvalidOffer", "message": "Invalid SDP offer."]]) }
            sdpPolls += 1
            let requestID = sdpRequest == 2 && (sdpPolls == 1 || staleMicrophoneAnswer) ? 1 : sdpRequest
            var answer: [String: Any] = ["status": "success", "requestId": requestID, "sdpType": "answer",
                "sdp": "v=0\r\no=- 1 \(requestID) IN IP4 0.0.0.0\r\n", "input": 10, "control": 3, "message": "1", "chat": 1, "chatStream": 1]
            if sdpRequest == 2 && omitMicrophoneRequestID { answer.removeValue(forKey: "requestId") }
            return (200, ["exchangeResponse": answer])
        case ("POST", "/v5/sessions/cloud/test-session/ice"):
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            precondition(body["Data"] == nil)
            let candidates = body["candidates"] as! [String]
            precondition(candidates.last == "a=end-of-candidates")
            let first = try JSONSerialization.jsonObject(with: Data(candidates[0].utf8)) as! [String: Any]
            precondition(first["candidate"] as? String == "candidate:test")
            return (200, [:])
        case ("GET", "/v5/sessions/cloud/test-session/ice"):
            return (200, ["exchangeResponse": "[]"])
        case ("DELETE", "/v5/sessions/cloud/test-session"):
            deletes += 1
            return (200, [:])
        default:
            preconditionFailure("Unexpected request: \(request.httpMethod!) \(request.url!.path)")
        }
    }
}

private extension URLRequest {
    func bodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            precondition(count >= 0)
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class PlayRequestProtocol: URLProtocol {
    static var scenario = PlayScenario(.success)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, payload) = try Self.scenario.response(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client!.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload))
            client!.urlProtocolDidFinishLoading(self)
        } catch { client!.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
private enum PlayRequestTests {
    static func main() async throws {
        for mode in [PlayScenario.Mode.success, .failedState, .rejectedConnect, .cancelledTransfer] {
            let scenario = PlayScenario(mode)
            PlayRequestProtocol.scenario = scenario
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlayRequestProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let game = CloudGame(id: "TEST-PRODUCT", title: "Test game", description: "", publisher: nil,
                                 developer: nil, releaseDate: nil, tileArtworkURL: nil, posterArtworkURL: nil,
                                 heroArtworkURL: nil, supportedInputs: [.controller], cloudOfferingIDs: ["xgpuweb"],
                                 xCloudTitleID: "TEST-TITLE")
            let offering = XboxCloudOfferingSession(offeringID: "xgpuweb", serviceToken: "test-gssv-token",
                                                    serviceBaseURL: URL(string: "https://test.invalid")!)
            let task = Task {
                try await XboxCloudPlayService(session: session).createSession(
                    for: game, offering: offering, connectTokenProvider: {
                        if mode == .cancelledTransfer {
                            withUnsafeCurrentTask { $0?.cancel() }
                            try Task.checkCancellation()
                        }
                        return "test-transfer-token"
                    }, progress: { _ in }
                )
            }
            do {
                let result = try await task.value
                precondition(mode == .success)
                precondition(result.serverDetails.stunServerAddresses == ["stun:test.invalid:3478"])
                precondition(scenario.connects == 1, "Repeated ReadyToConnect must not repeat the handshake")
                precondition(scenario.deletes == 0)
                let service = XboxCloudPlayService(session: session)
                try await service.sendLocalSDP(["messageType": "offer", "sdp": "v=0\r\n"], for: result, offering: offering)
                let answer = try await service.waitForRemoteSDP(for: result, offering: offering, timeout: 1)
                precondition(answer.input == 10 && answer.control == 3 && answer.message == 1)
                precondition(answer.sdpType == "answer", "Structured exchangeResponse must be decoded")
                try await service.sendLocalSDP(["messageType": "offer", "requestId": 2, "sdp": "v=0\r\n",
                                               "configuration": ["isMediaStreamsChatRenegotiation": true]], for: result, offering: offering)
                let microphoneAnswer = try await service.waitForRemoteSDP(for: result, offering: offering, timeout: 1, expectedRequestID: 2)
                precondition(microphoneAnswer.requestId == 2, "A previous video answer must not satisfy microphone negotiation")
                precondition(microphoneAnswer.chatStream == 1)
                scenario.omitMicrophoneRequestID = true
                let unnumbered = try await service.waitForRemoteSDP(for: result, offering: offering, timeout: 1,
                                                                   expectedRequestID: 2, previousSDP: answer.sdp)
                precondition(unnumbered.requestId == nil && unnumbered.sdp != answer.sdp)
                scenario.staleMicrophoneAnswer = true
                do {
                    _ = try await service.waitForRemoteSDP(for: result, offering: offering, timeout: 0.05, expectedRequestID: 2, previousSDP: answer.sdp)
                    preconditionFailure("Only stale SDP answers must time out")
                } catch { precondition(error is XboxCloudPlayError) }
                scenario.staleMicrophoneAnswer = false
                scenario.omitMicrophoneRequestID = false
                let candidates = try await service.exchangeLocalICE([["candidate": "candidate:test"]], includesEndOfCandidates: true, for: result, offering: offering)
                precondition(candidates.isEmpty)
                PlayRequestProtocol.scenario = PlayScenario(.signalingError)
                do {
                    _ = try await service.waitForRemoteSDP(for: result, offering: offering, timeout: 1)
                    preconditionFailure("Xbox signaling errors must not be hidden until timeout")
                } catch {
                    precondition(error.localizedDescription.contains("InvalidOffer"))
                }
                PlayRequestProtocol.scenario = scenario
            } catch {
                precondition(mode != .success)
                precondition(scenario.deletes == 1, "Allocated session must be released on failure or cancellation")
                switch mode {
                case .failedState:
                    precondition(error.localizedDescription.contains("NoEntitlement"))
                    precondition(error.localizedDescription.contains("This account cannot play this title."))
                case .rejectedConnect:
                    precondition(error.localizedDescription.contains("TransferRejected"))
                case .cancelledTransfer:
                    precondition(error is CancellationError)
                    precondition(scenario.connects == 0)
                case .signalingError: preconditionFailure("Unexpected mode")
                case .success: preconditionFailure("Unexpected success-path error")
                }
            }
        }
        print("PASS: raw SDP/ICE wire bodies, structured SDP answers, immediate signaling errors, launch wire types, transfer handshake, repeated ready state, nested errors, failure/cancellation cleanup (\(TimeZone.current.identifier))")
    }
}
