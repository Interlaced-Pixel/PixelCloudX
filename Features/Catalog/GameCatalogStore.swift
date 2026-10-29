import Combine
import Foundation

@MainActor final class GameCatalogStore: ObservableObject {
    @Published private(set) var games: [CloudGame] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var changes: [String: CatalogChange] = [:]
    @Published private(set) var savedIDs: Set<String>
    @Published private(set) var recentIDs: [String]

    private let repository: CatalogRepository
    private let defaults: UserDefaults
    private var generation = 0
    private var accountIDs: [String] = []

    init(repository: CatalogRepository = .shared, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        savedIDs = Set(defaults.stringArray(forKey: "PixelCloudX.savedCloudGameProductIDs") ?? [])
        recentIDs = defaults.stringArray(forKey: "PixelCloudX.recentCloudGameProductIDs") ?? []
    }

    func load(additionalProductIDs: [String] = [], force: Bool = false, refresh: Bool = true) async {
        generation += 1
        let token = generation
        accountIDs = GameCatalogService.normalizedIDs(additionalProductIDs)
        let ids = accountIDs
        let cached = await repository.cached()
        let presentation = await repository.presentation(cached, accountIDs: ids)
        guard !Task.isCancelled, token == generation else { return }
        apply(presentation)
        isLoading = games.isEmpty && refresh
        isRefreshing = refresh
        guard refresh else { return }
        defer {
            if token == generation { isLoading = false; isRefreshing = false }
        }
        do {
            let result = try await repository.refresh(accountIDs: ids, force: force)
            let latest = await repository.presentation(result.snapshot, accountIDs: ids)
            guard !Task.isCancelled, token == generation else { return }
            apply(latest)
            errorMessage = result.warning
            if games.isEmpty && result.warning == nil { errorMessage = "No playable game details were returned. Try refreshing the catalog." }
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func markUpdatesSeen() async {
        let snapshot = await repository.acknowledgeChanges()
        changes = snapshot.changes
    }

    private func apply(_ presentation: CatalogPresentation) {
        games = presentation.games
        changes = presentation.changes
        checkedAt = presentation.checkedAt
    }

    func toggleSaved(_ game: CloudGame) {
        if savedIDs.contains(game.id) { savedIDs.remove(game.id) } else { savedIDs.insert(game.id) }
        defaults.set(savedIDs.sorted(), forKey: "PixelCloudX.savedCloudGameProductIDs")
    }

    func recordOpened(_ game: CloudGame) {
        recentIDs.removeAll { $0 == game.id }
        recentIDs.insert(game.id, at: 0)
        recentIDs = Array(recentIDs.prefix(12))
        defaults.set(recentIDs, forKey: "PixelCloudX.recentCloudGameProductIDs")
    }
}
