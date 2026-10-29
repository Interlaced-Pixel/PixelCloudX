import Foundation

@main @MainActor private enum SettingsTests {
    static func main() throws {
        let suite = "PixelCloudX.SettingsRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        precondition(settings.values.displayRatio == .source && settings.values.volume == 1)
        settings.values.displayRatio = .classic
        settings.values.displayScaling = .fill
        settings.values.resolution = .quadHD
        settings.values.volume = 0.35
        settings.values.xbox.highContrast = 2
        settings.values.xbox.locale = "fr-FR"
        settings.values.keyboardEnabled = false
        settings.values.echoCancellation = false
        settings.values.catalogRefreshMinutes = 30
        let restored = AppSettings(defaults: defaults)
        precondition(restored.values == settings.values, "Every exposed preference must survive a fresh store")
        let corrupted: [String: Any] = ["volume": "bad", "resolution": "future-mode", "displayRatio": "classic",
            "deadzone": 5, "catalogRefreshMinutes": 7,
            "xbox": ["highContrast": 2, "textToSpeech": "bad", "locale": "fr-FR"]]
        defaults.set(try JSONSerialization.data(withJSONObject: corrupted), forKey: AppSettings.storageKey)
        let repaired = AppSettings(defaults: defaults)
        precondition(repaired.values.volume == 1 && repaired.values.resolution == .automatic)
        precondition(repaired.values.displayRatio == .classic && repaired.values.deadzone == 0.3)
        precondition(repaired.values.xbox.highContrast == 2 && repaired.values.xbox.locale == "fr-FR" && !repaired.values.xbox.textToSpeech)
        precondition(repaired.values.catalogRefreshMinutes == 15)
        defaults.set(Data("not-json".utf8), forKey: AppSettings.storageKey)
        precondition(AppSettings(defaults: defaults).values == AppPreferences())
        defaults.set("keep-auth", forKey: "auth-fixture")
        repaired.reset()
        precondition(defaults.string(forKey: "auth-fixture") == "keep-auth")
        precondition(AppSettings(defaults: defaults).values == AppPreferences())
        let viewport = CGSize(width: 1600, height: 1000)
        let source = CGSize(width: 1920, height: 1080)
        let fit = StreamDisplayLayout.size(in: viewport, source: source, ratio: .source, scaling: .fit)
        precondition(fit == CGSize(width: 1600, height: 900))
        let fill = StreamDisplayLayout.size(in: viewport, source: source, ratio: .source, scaling: .fill)
        precondition(abs(fill.width - 1777.777777) < 0.01 && fill.height == 1000)
        precondition(StreamDisplayLayout.size(in: viewport, source: source, ratio: .classic, scaling: .stretch) == viewport)
        let classic = StreamDisplayLayout.size(in: viewport, source: source, ratio: .classic, scaling: .fit)
        precondition(abs(classic.width / classic.height - 4.0 / 3.0) < 0.001)
        precondition(StreamDisplayLayout.size(in: .zero, source: .zero, ratio: .source, scaling: .fit) == .zero)
        print("PASS: settings relaunch persistence, partial/corrupt/future fields, nested defaults, validation, reset isolation and display fit/fill/stretch geometry")
    }
}
