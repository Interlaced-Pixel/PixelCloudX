import Foundation

struct XboxCloudOfferingSession: Sendable {
    let offeringID: String
    let serviceToken: String
    let serviceBaseURL: URL
}

struct XboxCloudAccountSession: Sendable {
    let gamertag: String?
    let xuid: String?
    let userHash: String
    let offerings: [XboxCloudOfferingSession]
    let catalogProductIDs: [String]
    let entitledProductIDs: [String]

    var launchOffering: XboxCloudOfferingSession? {
        offerings.first(where: { $0.offeringID == "xgpuweb" }) ?? offerings.first
    }

    func offering(for game: CloudGame) -> XboxCloudOfferingSession? {
        let gameOfferings = Set(game.cloudOfferingIDs.map { $0.uppercased() })
        guard !gameOfferings.isEmpty else { return launchOffering }
        return offerings.first(where: { gameOfferings.contains($0.offeringID.uppercased()) }) ?? launchOffering
    }
}

enum XboxCloudAccountError: LocalizedError {
    case invalidResponse(String)
    case serviceRejected(String)
    case noCloudOffering

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): message
        case .serviceRejected(let message): message
        case .noCloudOffering:
            "Microsoft authorized the account, but Xbox did not provide a Cloud Gaming offering."
        }
    }
}

/// Independently authored Xbox identity and GSSV client. It keeps Xbox service
/// tokens in memory and returns only the product IDs needed by the catalog UI.
struct XboxCloudAccountService {
    private struct XboxUserToken: Decodable {
        let token: String
        let claims: Claims

        enum CodingKeys: String, CodingKey {
            case token = "Token"
            case claims = "DisplayClaims"
        }

        struct Claims: Decodable {
            let users: [UserClaim]
            enum CodingKeys: String, CodingKey { case users = "xui" }
        }

        struct UserClaim: Decodable {
            let userHash: String
            let xuid: String?
            let gamertag: String?
            enum CodingKeys: String, CodingKey {
                case userHash = "uhs"
                case xuid
                case gamertag = "gtg"
            }
        }
    }

    private struct XboxXSTSResponse: Decodable {
        let token: String
        let claims: Claims
        enum CodingKeys: String, CodingKey {
            case token = "Token"
            case claims = "DisplayClaims"
        }
        struct Claims: Decodable {
            let users: [UserClaim]
            enum CodingKeys: String, CodingKey { case users = "xui" }
        }
        struct UserClaim: Decodable {
            let userHash: String
            enum CodingKeys: String, CodingKey { case userHash = "uhs" }
        }
    }

    private let session: URLSession
    private let jsonDecoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func loadAccount(using microsoftAccessToken: String) async throws -> XboxCloudAccountSession {
        let xboxUser = try await exchangeMicrosoftToken(microsoftAccessToken)
        guard let user = xboxUser.claims.users.first else {
            throw XboxCloudAccountError.invalidResponse("Xbox identity response had no user claim.")
        }

        let gssvXSTS = try await requestXSTS(userToken: xboxUser.token, relyingParty: "http://gssv.xboxlive.com/")
        let userHash = gssvXSTS.claims.users.first?.userHash ?? user.userHash

        var sessions: [XboxCloudOfferingSession] = []
        var products = Set<String>()
        var entitled = Set<String>()
        var offeringErrors: [String] = []

        for offeringID in ["xgpuweb", "xgpuwebf2p"] {
            do {
                let offering = try await loginToOffering(offeringID, xstsToken: gssvXSTS.token)
                sessions.append(offering)
                // The account-title list enriches catalog badges, but it is not
                // required to authenticate or start a cloud session.
                do {
                    let records = try await fetchAccountTitles(for: offering)
                    for record in records {
                        guard let productID = record.productID?.uppercased(), !productID.isEmpty else { continue }
                        products.insert(productID)
                        if record.hasEntitlement == true { entitled.insert(productID) }
                    }
                } catch {
                    NSLog("PixelCloudX could not load optional account-title details: %@", error.localizedDescription)
                }
            } catch {
                offeringErrors.append("\(offeringID): \(error.localizedDescription)")
            }
        }

        guard !sessions.isEmpty else {
            if let firstError = offeringErrors.first {
                throw XboxCloudAccountError.serviceRejected(firstError)
            }
            throw XboxCloudAccountError.noCloudOffering
        }

        return XboxCloudAccountSession(
            gamertag: user.gamertag,
            xuid: user.xuid,
            userHash: userHash,
            offerings: sessions,
            catalogProductIDs: products.sorted(),
            entitledProductIDs: entitled.sorted()
        )
    }

    private func exchangeMicrosoftToken(_ accessToken: String) async throws -> XboxUserToken {
        let requestBody: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": "d=\(accessToken)"
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        var request = URLRequest(url: URL(string: "https://user.auth.xboxlive.com/user/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let data = try await send(request)
        return try jsonDecoder.decode(XboxUserToken.self, from: data)
    }

    private func requestXSTS(userToken: String, relyingParty: String) async throws -> XboxXSTSResponse {
        let requestBody: [String: Any] = [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [userToken]
            ],
            "RelyingParty": relyingParty,
            "TokenType": "JWT"
        ]
        var request = URLRequest(url: URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-xbl-contract-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let data = try await send(request)
        return try jsonDecoder.decode(XboxXSTSResponse.self, from: data)
    }

    private func loginToOffering(
        _ offeringID: String,
        xstsToken: String
    ) async throws -> XboxCloudOfferingSession {
        let serviceBase = URL(string: "https://\(offeringID).gssv-play-prod.xboxlive.com")!
        var request = URLRequest(url: serviceBase.appendingPathComponent("v2/login/user"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XboxComBrowser", forHTTPHeaderField: "X-Gssv-Client")
        request.setValue("AFD", forHTTPHeaderField: "X-GSSV-Routing")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": xstsToken,
            "offeringId": offeringID
        ])

        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serviceToken = root["gsToken"] as? String,
              !serviceToken.isEmpty else {
            throw XboxCloudAccountError.invalidResponse("GSSV login did not return a service token.")
        }

        let regionURL = Self.firstRegionURL(root["offeringSettings"] as? [String: Any]) ?? serviceBase
        guard Self.isAllowedServiceURL(regionURL) else {
            throw XboxCloudAccountError.invalidResponse("GSSV returned a service URL outside its expected host.")
        }
        return XboxCloudOfferingSession(
            offeringID: offeringID,
            serviceToken: serviceToken,
            serviceBaseURL: regionURL
        )
    }

    private struct TitleRecord {
        let productID: String?
        let hasEntitlement: Bool?
    }

    private func fetchAccountTitles(for offering: XboxCloudOfferingSession) async throws -> [TitleRecord] {
        var request = URLRequest(url: offering.serviceBaseURL.appendingPathComponent("v2/titles"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(offering.serviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XboxComBrowser", forHTTPHeaderField: "X-Gssv-Client")

        let data = try await send(request)
        let root = try JSONSerialization.jsonObject(with: data)
        let records: [[String: Any]]
        if let array = root as? [[String: Any]] {
            records = array
        } else if let object = root as? [String: Any], let array = object["titles"] as? [[String: Any]] {
            records = array
        } else {
            throw XboxCloudAccountError.invalidResponse("Xbox account-title response had an unexpected shape.")
        }

        return records.map { record in
            let details = record["details"] as? [String: Any] ?? record
            return TitleRecord(
                productID: details["productId"] as? String,
                hasEntitlement: details["hasEntitlement"] as? Bool
            )
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XboxCloudAccountError.invalidResponse("Xbox returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let serviceMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["Message"] as? String ?? $0["message"] as? String }
            throw XboxCloudAccountError.serviceRejected(
                serviceMessage ?? "Xbox service request failed (HTTP \(http.statusCode))."
            )
        }
        return data
    }

    private static func firstRegionURL(_ settings: [String: Any]?) -> URL? {
        guard let regions = settings?["regions"] as? [[String: Any]] else { return nil }
        for region in regions {
            if let raw = region["baseUri"] as? String,
               let url = URL(string: raw), isAllowedServiceURL(url) {
                return url
            }
        }
        return nil
    }

    private static func isAllowedServiceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "gssv-play-prod.xboxlive.com"
            || host.hasSuffix(".gssv-play-prod.xboxlive.com")
    }
}
