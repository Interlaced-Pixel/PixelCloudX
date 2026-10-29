import Combine
import Foundation
import CoreGraphics

protocol SettingsChoice: RawRepresentable, CaseIterable, Identifiable, Hashable where RawValue == String {
    var title: String { get }
}
extension SettingsChoice { var id: String { rawValue } }

enum DisplayRatio: String, Codable, SettingsChoice {
    case source, widescreen, mac, classic, ultrawide
    var title: String {
        switch self {
        case .source: "Original video"
        case .widescreen: "16:9"
        case .mac: "16:10"
        case .classic: "4:3"
        case .ultrawide: "21:9"
        }
    }
    var value: Double? {
        switch self {
        case .source: nil
        case .widescreen: 16.0 / 9
        case .mac: 16.0 / 10
        case .classic: 4.0 / 3
        case .ultrawide: 21.0 / 9
        }
    }
}
enum DisplayScaling: String, Codable, SettingsChoice {
    case fit, fill, stretch
    var title: String {
        switch self { case .fit: "Fit"; case .fill: "Fill and crop"; case .stretch: "Stretch to window" }
    }
}
enum StreamResolution: String, Codable, SettingsChoice {
    case automatic = "Auto", hd = "720", fullHD = "1080", quadHD = "1440"
    var title: String {
        switch self { case .automatic: "Automatic"; case .hd: "720p"; case .fullHD: "1080p"; case .quadHD: "1440p" }
    }
    var dimensions: CGSize {
        switch self {
        case .hd: CGSize(width: 1280, height: 720)
        case .automatic, .fullHD: CGSize(width: 1920, height: 1080)
        case .quadHD: CGSize(width: 2560, height: 1440)
        }
    }
}

struct XboxLaunchPreferences: Codable, Equatable, Sendable {
    var textToSpeech = false
    var magnifier = false
    var highContrast = 0
    var locale = "system"
    var resolvedLocale: String {
        locale == "system" ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : locale
    }
}

struct AppPreferences: Codable, Equatable {
    var startInCatalog = true
    var sidebarVisible = true
    var sortAscending = true
    var displayRatio = DisplayRatio.source
    var displayScaling = DisplayScaling.fit
    var resolution = StreamResolution.automatic
    var overlaySeconds = 4
    var showStatistics = false
    var volume = 1.0
    var muted = false
    var keyboardEnabled = true
    var backgroundController = true
    var deadzone = 0.0
    var echoCancellation = true
    var noiseSuppression = true
    var automaticGain = true
    var automaticCatalogRefresh = true
    var catalogRefreshMinutes = 15
    var showCatalogChanges = true
    var xbox = XboxLaunchPreferences()

    mutating func validate() {
        overlaySeconds = min(30, max(0, overlaySeconds))
        volume = volume.isFinite ? min(1, max(0, volume)) : 1
        deadzone = deadzone.isFinite ? min(0.3, max(0, deadzone)) : 0
        if ![15, 30, 60].contains(catalogRefreshMinutes) { catalogRefreshMinutes = 15 }
        if !(0...2).contains(xbox.highContrast) { xbox.highContrast = 0 }
        if !Self.locales.contains(where: { $0.0 == xbox.locale }) { xbox.locale = "system" }
    }
    static let locales = [("system", "System language"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
                          ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch"),
                          ("ja-JP", "日本語"), ("pt-BR", "Português (Brasil)")]
}

/// Versioned, atomic UserDefaults persistence. A damaged field falls back on its
/// own default; valid preferences in the same document survive schema upgrades.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let storageKey = "PixelCloudX.preferences.v1"
    @Published var values: AppPreferences {
        didSet {
            var validated = values
            validated.validate()
            if validated != values { values = validated }
            if let data = try? JSONEncoder().encode(validated) { defaults.set(data, forKey: Self.storageKey) }
        }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = AppPreferences()
        if let data = defaults.data(forKey: Self.storageKey),
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback)) as? [String: Any] {
            // Merge individually decodable fields over defaults, including nested
            // Xbox preferences. Unknown keys are retained only by newer clients.
            var merged = base
            for (key, field) in fields where base[key] != nil {
                var candidate = merged
                if let nested = field as? [String: Any], var defaultNested = base[key] as? [String: Any] {
                    for (nestedKey, nestedValue) in nested where defaultNested[nestedKey] != nil {
                        var test = defaultNested; test[nestedKey] = nestedValue
                        candidate[key] = test
                        if let encoded = try? JSONSerialization.data(withJSONObject: candidate),
                           (try? JSONDecoder().decode(AppPreferences.self, from: encoded)) != nil { defaultNested = test }
                    }
                    candidate[key] = defaultNested
                } else { candidate[key] = field }
                if let encoded = try? JSONSerialization.data(withJSONObject: candidate),
                   (try? JSONDecoder().decode(AppPreferences.self, from: encoded)) != nil { merged = candidate }
            }
            values = (try? JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: merged))) ?? fallback
        } else { values = fallback }
        var validated = values
        validated.validate()
        values = validated
    }
    func reset() {
        values = AppPreferences()
        for key in ["PixelCloudX.catalogSection", "PixelCloudX.catalogFilter", "PixelCloudX.catalogUpdatesOnly"] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Pure geometry shared by the Metal surface and regression checks.
enum StreamDisplayLayout {
    static func size(in viewport: CGSize, source: CGSize, ratio: DisplayRatio, scaling: DisplayScaling) -> CGSize {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        if scaling == .stretch { return viewport }
        let sourceAspect: Double = source.width > 0 && source.height > 0 ? Double(source.width / source.height) : 16.0 / 9.0
        let aspect: Double = ratio.value ?? sourceAspect
        let widthScale = Double(viewport.width) / aspect
        let height = scaling == .fit ? min(Double(viewport.height), widthScale) : max(Double(viewport.height), widthScale)
        return CGSize(width: height * aspect, height: height)
    }
}
