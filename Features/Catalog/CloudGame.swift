import Foundation

enum GameFilter: String, CaseIterable, Identifiable {
    case all = "All games"
    case accountGames = "My Xbox games"
    case controller = "Controller"
    case touch = "Touch"
    case keyboardMouse = "Keyboard & mouse"
    case saved = "Saved"

    var id: String { rawValue }

    func includes(_ game: CloudGame, savedIDs: Set<String>, accountEntitledProductIDs: Set<String> = []) -> Bool {
        switch self {
        case .all:
            true
        case .accountGames:
            accountEntitledProductIDs.contains(game.id.uppercased())
        case .controller:
            game.supportedInputs.contains(.controller)
        case .touch:
            game.supportedInputs.contains(.touch)
        case .keyboardMouse:
            game.supportedInputs.contains(.keyboard) || game.supportedInputs.contains(.mouse)
        case .saved:
            savedIDs.contains(game.id)
        }
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case home = "Home"
    case browse = "All games"
    case library = "My list"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .browse: "square.grid.2x2.fill"
        case .library: "bookmark.fill"
        }
    }
}

enum GameInput: String, Hashable, Codable, Sendable {
    case controller
    case touch
    case keyboard
    case mouse

    init?(catalogValue: String) {
        switch catalogValue.lowercased() {
        case "controller", "gamepad": self = .controller
        case "touch": self = .touch
        case "keyboard", "keyboardmouse", "keyboard/mouse": self = .keyboard
        case "mouse": self = .mouse
        default: return nil
        }
    }
}

struct CloudGame: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let publisher: String?
    let developer: String?
    let releaseDate: Date?
    let tileArtworkURL: URL?
    let posterArtworkURL: URL?
    let heroArtworkURL: URL?
    let supportedInputs: Set<GameInput>
    let cloudOfferingIDs: Set<String>
    let xCloudTitleID: String?

    var releaseYear: String {
        guard let releaseDate else { return "" }
        return String(Calendar(identifier: .gregorian).component(.year, from: releaseDate))
    }

    var tagline: String {
        guard let firstSentence = description
            .split(whereSeparator: { $0 == "." || $0 == "\n" })
            .first else {
            return "Available to play with Xbox Cloud Gaming"
        }
        let sentence = String(firstSentence).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty { return sentence }
        return "Available to play with Xbox Cloud Gaming"
    }

    var inputSummary: String {
        let labels: [(GameInput, String)] = [
            (.controller, "Controller"),
            (.touch, "Touch"),
            (.keyboard, "Keyboard"),
            (.mouse, "Mouse")
        ]
        let available = labels.compactMap { input, label in
            supportedInputs.contains(input) ? label : nil
        }
        return available.isEmpty ? "Input details unavailable" : available.joined(separator: " · ")
    }
}

struct CatalogFeedEntry: Decodable {
    let id: String?
}

struct CatalogHydrationResponse: Decodable {
    let products: [String: CatalogProduct]

    enum CodingKeys: String, CodingKey {
        case products = "Products"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let dictionary = try? container.nestedContainer(keyedBy: ProductKey.self, forKey: .products) {
            products = Dictionary(dictionary.allKeys.compactMap { key in
                guard let product = try? dictionary.decode(CatalogProduct.self, forKey: key) else { return nil }
                return (key.stringValue, product)
            }, uniquingKeysWith: { first, _ in first })
            return
        }

        let entries = try container.decode([CatalogProduct].self, forKey: .products)
        products = Dictionary(entries.compactMap { product in
            guard let productID = product.productID ?? product.storeID,
                  !productID.isEmpty else { return nil }
            return (productID, product)
        }, uniquingKeysWith: { first, _ in first })
    }

    private struct ProductKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

struct CatalogProduct: Codable, Sendable {
    let productID: String?
    let storeID: String?
    let productTitle: String?
    let productDescription: String?
    let productDescriptionShort: String?
    let publisherName: String?
    let developerName: String?
    let xCloudTitleID: String?
    let imageTile: CatalogImage?
    let imagePoster: CatalogImage?
    let imageHero: CatalogImage?
    let originalReleaseDate: String?
    let availablePlatforms: [String]?
    let xCloudOfferings: [String: CloudOffering]?

    enum CodingKeys: String, CodingKey {
        case productID = "ProductId"
        case storeID = "StoreId"
        case productTitle = "ProductTitle"
        case productDescription = "ProductDescription"
        case productDescriptionShort = "ProductDescriptionShort"
        case publisherName = "PublisherName"
        case developerName = "DeveloperName"
        case xCloudTitleID = "XCloudTitleId"
        case imageTile = "Image_Tile"
        case imagePoster = "Image_Poster"
        case imageHero = "Image_Hero"
        case originalReleaseDate = "OriginalReleaseDate"
        case availablePlatforms = "AvailablePlatforms"
        case xCloudOfferings = "XCloudOfferings"
    }

    var isCloudPlayable: Bool {
        if availablePlatforms?.contains(where: { $0.caseInsensitiveCompare("XCloud") == .orderedSame }) == true {
            return true
        }
        return xCloudOfferings?.isEmpty == false
    }

    var supportedInputs: Set<GameInput> {
        Set((xCloudOfferings?.values.flatMap { $0.supportedInputTypes ?? [] } ?? []).compactMap(GameInput.init(catalogValue:)))
    }

    func game(productID: String, isAccountCloudTitle: Bool = false) -> CloudGame? {
        guard isCloudPlayable || isAccountCloudTitle,
              let title = productTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        return CloudGame(
            id: productID,
            title: title,
            description: productDescriptionShort ?? productDescription ?? "Available to play with Xbox Cloud Gaming.",
            publisher: publisherName,
            developer: developerName,
            releaseDate: originalReleaseDate.flatMap { ISO8601DateFormatter().date(from: $0) },
            tileArtworkURL: imageTile?.resolvedURL,
            posterArtworkURL: imagePoster?.resolvedURL,
            heroArtworkURL: imageHero?.resolvedURL,
            supportedInputs: supportedInputs,
            cloudOfferingIDs: Set((xCloudOfferings ?? [:]).keys.map { $0.uppercased() }),
            xCloudTitleID: xCloudTitleID
        )
    }
}

struct CatalogImage: Codable, Sendable {
    let url: String?

    enum CodingKeys: String, CodingKey {
        case url = "URL"
    }

    var resolvedURL: URL? {
        guard let url else { return nil }
        return URL(string: url.hasPrefix("//") ? "https:\(url)" : url)
    }
}

struct CloudOffering: Codable, Sendable {
    let supportedInputTypes: [String]?

    enum CodingKeys: String, CodingKey {
        case supportedInputTypes = "SupportedInputTypes"
    }
}
