import SwiftUI

struct CatalogView: View {
    let accountName: String?
    let cloudServiceSummary: String?
    let cloudServiceErrorMessage: String?
    let accountCatalogProductIDs: [String]
    let accountEntitledProductIDs: [String]
    @ObservedObject var streamController: XboxCloudStreamController
    let isAccountSignedIn: Bool
    let isCloudAccountReady: Bool
    let onStartStream: (CloudGame, ControllerInputService) -> Void
    let onSignIn: () -> Void
    let onReconnectXbox: () -> Void
    let onSignOut: () -> Void

    @StateObject private var catalog = GameCatalogStore()
    @StateObject private var controllerInput = ControllerInputService()
    @AppStorage("PixelCloudX.catalogSection") private var selectedSection: LibrarySection = .home
    @AppStorage("PixelCloudX.catalogFilter") private var selectedFilter: GameFilter = .all
    @State private var searchText = ""
    @State private var selectedGame: CloudGame?
    @State private var activeStreamGame: CloudGame?
    @State private var isShowingControllerDiagnostics = false
    @EnvironmentObject private var settings: AppSettings
    private var isSidebarVisible: Bool {
        get { settings.values.sidebarVisible }
        nonmutating set { settings.values.sidebarVisible = newValue }
    }
    private var sortAscending: Bool {
        get { settings.values.sortAscending }
        nonmutating set { settings.values.sortAscending = newValue }
    }
    @AppStorage("PixelCloudX.catalogUpdatesOnly") private var showUpdatesOnly = false
    @Environment(\.scenePhase) private var scenePhase

    private var recentGames: [CloudGame] {
        let lookup = Dictionary(catalog.games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return catalog.recentIDs.compactMap { lookup[$0] }
    }
    private var visibleGames: [CloudGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entitled = Set(accountEntitledProductIDs.map { $0.uppercased() })
        let games = catalog.games.filter { game in
            (!showUpdatesOnly || catalog.changes[game.id] != nil) &&
            (selectedSection != .library || catalog.savedIDs.contains(game.id)) &&
            selectedFilter.includes(game, savedIDs: catalog.savedIDs, accountEntitledProductIDs: entitled) &&
            (query.isEmpty || game.title.localizedCaseInsensitiveContains(query) ||
             game.description.localizedCaseInsensitiveContains(query) ||
             (game.publisher?.localizedCaseInsensitiveContains(query) ?? false) ||
             (game.developer?.localizedCaseInsensitiveContains(query) ?? false))
        }
        return sortAscending ? games : Array(games.reversed())
    }
    private var isHome: Bool { selectedSection == .home && searchText.isEmpty && selectedFilter == .all }

    var body: some View {
        VStack(spacing: 0) {
            CatalogToolbar(searchText: $searchText, accountName: accountName,
                           controllerInput: controllerInput,
                           onToggleSidebar: { isSidebarVisible.toggle() },
                           onControllers: { isShowingControllerDiagnostics = true },
                           serviceSummary: cloudServiceSummary, serviceError: cloudServiceErrorMessage,
                           onReconnect: onReconnectXbox, onSignOut: onSignOut)
            HStack(alignment: .top, spacing: 0) {
                if isSidebarVisible {
                    CatalogNavigation(selection: selectedSection, recentGames: recentGames,
                                      savedCount: catalog.savedIDs.count,
                                      onSelect: { selectedSection = $0; selectedFilter = .all },
                                      onGame: { selectedGame = $0 })
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            Color.clear.frame(height: 0).id("catalog-top")
                            if isHome && !recentGames.isEmpty {
                                gameRail("Recently opened", games: recentGames)
                            }
                            if isHome {
                                let added = catalog.games.filter { catalog.changes[$0.id]?.kind == .added }
                                if !added.isEmpty { gameRail("New to the catalog", games: added) }
                            }
                            if isHome && !catalog.games.isEmpty {
                                spotlight
                            }
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(headingTitle).font(.system(size: 25, weight: .bold))
                                    Text(headingSubtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { Task { await catalog.load(additionalProductIDs: accountCatalogProductIDs, force: true) } } label: {
                                    Label("Refresh catalog", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless).disabled(catalog.isRefreshing)
                                Menu {
                                    Button("Title: A to Z") { sortAscending = true }
                                    Button("Title: Z to A") { sortAscending = false }
                                } label: {
                                    Label(sortAscending ? "A–Z" : "Z–A", systemImage: "arrow.up.arrow.down")
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("Sort games")
                            }
                            filterPicker
                            HStack(spacing: 12) {
                                if catalog.isRefreshing {
                                    ProgressView().controlSize(.small)
                                    Text(catalog.games.isEmpty ? "Loading catalog…" : "Checking for catalog updates…")
                                } else if let checkedAt = catalog.checkedAt {
                                    Text("Catalog saved on this Mac · checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                                }
                                Spacer()
                                if !catalog.changes.isEmpty {
                                    Button("\(catalog.changes.count) new or updated") { showUpdatesOnly.toggle() }
                                        .foregroundStyle(CloudPalette.accent)
                                    Button("Mark seen") { Task { await catalog.markUpdatesSeen(); showUpdatesOnly = false } }
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                            if let error = catalog.errorMessage, !catalog.games.isEmpty {
                                CatalogRefreshNotice(message: error) { Task { await catalog.load(additionalProductIDs: accountCatalogProductIDs, force: true) } }
                            }
                            if catalog.games.isEmpty {
                                CatalogLoadState(isLoading: catalog.isLoading, errorMessage: catalog.errorMessage,
                                                 onRetry: { Task { await catalog.load(additionalProductIDs: accountCatalogProductIDs, force: true) } })
                            } else { gameGrid }
                            Text("Catalog listings do not confirm account entitlement.")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 15)
                        }
                        .padding(.horizontal, 30).padding(.bottom, 30)
                    }
                    .onChange(of: selectedSection) { _, _ in proxy.scrollTo("catalog-top", anchor: .top) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CloudPalette.canvas)
        .task(id: accountCatalogProductIDs.sorted().joined(separator: "|") + "|\(scenePhase)|\(activeStreamGame?.id ?? "catalog")|\(settings.values.automaticCatalogRefresh)|\(settings.values.catalogRefreshMinutes)") {
            guard activeStreamGame == nil else { return }
            await catalog.load(additionalProductIDs: accountCatalogProductIDs, refresh: scenePhase == .active && settings.values.automaticCatalogRefresh)
            guard scenePhase == .active, settings.values.automaticCatalogRefresh else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(settings.values.catalogRefreshMinutes * 60)) } catch { return }
                await catalog.load(additionalProductIDs: accountCatalogProductIDs)
            }
        }
        .sheet(item: $selectedGame) { game in
            GameDetailsSheet(game: game, isSaved: catalog.savedIDs.contains(game.id),
                             onToggleSaved: { catalog.toggleSaved(game) }, isAccountSignedIn: isAccountSignedIn,
                             isCloudAccountReady: isCloudAccountReady, hasLaunchID: game.xCloudTitleID?.isEmpty == false,
                             onSignIn: onSignIn, onReconnect: onReconnectXbox, onPlay: { startNativeStream(game) })
        }
        .sheet(isPresented: $isShowingControllerDiagnostics) { ControllerDiagnosticsView(service: controllerInput) }
        .onReceive(NotificationCenter.default.publisher(for: .catalogRefreshRequested)) { _ in
            Task { await catalog.load(additionalProductIDs: accountCatalogProductIDs, refresh: false) }
        }
        .onChange(of: streamController.phase) { _, phase in
            if phase == .idle { activeStreamGame = nil }
        }
        .allowsHitTesting(activeStreamGame == nil)
        .accessibilityHidden(activeStreamGame != nil)
        .overlay {
            if let activeStreamGame {
                NativeStreamView(game: activeStreamGame, accountName: accountName,
                                 controllerNames: controllerInput.controllers.map(\.name), streamController: streamController,
                                 onClose: {
                                     Task { await streamController.stop() }
                                     self.activeStreamGame = nil
                                 })
                    .zIndex(2)
            }
        }
    }

    private var headingTitle: String {
        if showUpdatesOnly { return "Catalog updates" }
        if !searchText.isEmpty { return "Search results" }
        if selectedFilter == .accountGames { return "My Xbox games" }
        return selectedSection == .library ? "My list" : "All games"
    }
    private var headingSubtitle: String {
        if catalog.isLoading && catalog.games.isEmpty { return "Loading the cloud catalog…" }
        if selectedSection == .library { return "\(visibleGames.count) games saved on this Mac" }
        return "\(visibleGames.count) games" + (searchText.isEmpty ? "" : " matching “\(searchText)”")
    }
    private var filterPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(GameFilter.allCases.filter { $0 != .accountGames || !accountEntitledProductIDs.isEmpty }) { filter in
                    Button { selectedFilter = filter } label: {
                        Text(filter.rawValue).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(selectedFilter == filter ? Color.white : Color.white.opacity(0.07), in: Capsule())
                            .foregroundStyle(selectedFilter == filter ? Color.black : Color.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                }
            }
        }.scrollIndicators(.hidden)
    }
    @ViewBuilder private var gameGrid: some View {
        if visibleGames.isEmpty {
            ContentUnavailableView(selectedSection == .library ? "Your list is empty" : "No games found",
                                   systemImage: selectedSection == .library ? "bookmark" : "magnifyingglass",
                                   description: Text(selectedSection == .library ? "Save games from their detail page to keep them here." : "Try another search or filter."))
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)], alignment: .leading, spacing: 25) {
                ForEach(visibleGames) { game in tile(game) }
            }
        }
    }
    private func tile(_ game: CloudGame) -> some View {
        Button { selectedGame = game } label: { GameCard(game: game, isSaved: catalog.savedIDs.contains(game.id), change: settings.values.showCatalogChanges ? catalog.changes[game.id]?.kind : nil) }
            .buttonStyle(.plain).accessibilityLabel("Show details for \(game.title)")
    }
    private func gameRail(_ title: String, games: [CloudGame]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 24, weight: .bold))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(games.prefix(12)) { game in tile(game).frame(width: 165) }
                }.padding(3)
            }.scrollIndicators(.hidden)
        }
    }
    private var spotlight: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(Array(catalog.games.prefix(6))) { game in
                    Button { selectedGame = game } label: {
                        ZStack(alignment: .bottomLeading) {
                            GameArtworkView(game: game, useHeroArt: true)
                            LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(game.title).font(.system(size: 25, weight: .bold)).lineLimit(2)
                                Text("Explore game").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                            }.padding(22)
                        }
                        .frame(width: 440, height: 245)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Explore \(game.title)")
                }
            }.padding(.vertical, 3)
        }.scrollIndicators(.hidden)
    }
    private func startNativeStream(_ game: CloudGame) {
        guard isAccountSignedIn else { onSignIn(); return }
        guard isCloudAccountReady, game.xCloudTitleID?.isEmpty == false else { return }
        selectedGame = nil
        catalog.recordOpened(game)
        activeStreamGame = game
        onStartStream(game, controllerInput)
    }
}

private struct CatalogToolbar: View {
    @Binding var searchText: String
    let accountName: String?
    @ObservedObject var controllerInput: ControllerInputService
    let onToggleSidebar: () -> Void
    let onControllers: () -> Void
    let serviceSummary: String?
    let serviceError: String?
    let onReconnect: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 27, weight: .bold))
                Text("PixelCloudX").font(.system(size: 14, weight: .semibold))
                Button(action: onToggleSidebar) { Image(systemName: "sidebar.left").font(.system(size: 17)) }
                    .buttonStyle(.plain).accessibilityLabel("Toggle catalog sidebar")
            }
            Spacer(minLength: 10)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search games", text: $searchText).textFieldStyle(.plain).font(.system(size: 14))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16).frame(maxWidth: 410).frame(height: 38)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
            Spacer(minLength: 10)
            Button(action: onControllers) {
                Image(systemName: controllerInput.controllers.isEmpty ? "gamecontroller" : "gamecontroller.fill")
                    .font(.system(size: 20)).foregroundStyle(controllerInput.controllers.isEmpty ? Color.white : CloudPalette.accent)
            }
            .buttonStyle(.plain).accessibilityLabel("Controllers").help("Controller settings")
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 19)) }
                .buttonStyle(.plain).help("Settings (Command-comma)").accessibilityLabel("Settings")
            AccountProfileButton(accountName: accountName, serviceSummary: serviceSummary,
                                 serviceError: serviceError, onReconnect: onReconnect, onSignOut: onSignOut)
        }
        .foregroundStyle(.white).padding(.horizontal, 26).frame(height: 70).background(Color.black.opacity(0.8))
    }
}

private struct CatalogNavigation: View {
    let selection: LibrarySection
    let recentGames: [CloudGame]
    let savedCount: Int
    let onSelect: (LibrarySection) -> Void
    let onGame: (CloudGame) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 5) {
                    ForEach(LibrarySection.allCases) { section in
                        Button { onSelect(section) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.symbol).frame(width: 22)
                                Text(section.rawValue).font(.system(size: 14, weight: selection == section ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(14).background(selection == section ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(7).background(CloudPalette.panel, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 15) {
                    Label("Recently opened", systemImage: "clock.arrow.circlepath").font(.system(size: 13, weight: .semibold))
                    if recentGames.isEmpty {
                        Text("Games you open will appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(recentGames.prefix(6)) { game in
                        Button { onGame(game) } label: {
                            HStack(spacing: 10) {
                                GameArtworkView(game: game).frame(width: 35, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(game.title).font(.system(size: 12)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(CloudPalette.panel, in: RoundedRectangle(cornerRadius: 14))
                Button { onSelect(.library) } label: {
                    HStack { Label("My list", systemImage: "bookmark"); Spacer(); Text("\(savedCount)").foregroundStyle(.secondary) }
                        .font(.system(size: 12)).padding(16)
                }.buttonStyle(.plain)
            }.padding(14)
        }
        .frame(width: 235).frame(maxHeight: .infinity).background(Color.black.opacity(0.4))
    }
}

private struct GameCard: View {
    let game: CloudGame
    let isSaved: Bool
    var change: CatalogChange.Kind?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GameArtworkView(game: game)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if let change {
                        Text(change == .added ? "NEW" : "UPDATED")
                            .font(.system(size: 9, weight: .heavy)).tracking(0.7)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .foregroundStyle(.black).background(CloudPalette.accent, in: Capsule()).padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSaved {
                        Image(systemName: "bookmark.fill").font(.system(size: 11)).padding(9)
                            .background(.black.opacity(0.7), in: Circle()).padding(7)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 7) {
                        if game.supportedInputs.contains(.controller) { Image(systemName: "gamecontroller") }
                        if game.supportedInputs.contains(.keyboard) { Image(systemName: "keyboard") }
                        if game.supportedInputs.contains(.touch) { Image(systemName: "hand.tap") }
                    }
                    .font(.system(size: 11)).padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1))
            Text(game.title).font(.system(size: 12, weight: .medium)).lineLimit(2).frame(height: 31, alignment: .topLeading)
        }
        .foregroundStyle(.white).contentShape(Rectangle())
    }
}

private struct GameArtworkView: View {
    let game: CloudGame
    var useHeroArt = false

    private var artworkURL: URL? {
        if useHeroArt { return game.heroArtworkURL ?? game.posterArtworkURL ?? game.tileArtworkURL }
        return game.posterArtworkURL ?? game.tileArtworkURL
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.18, blue: 0.21), Color(red: 0.22, green: 0.24, blue: 0.37)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let artworkURL {
                    CachedCatalogArtwork(url: artworkURL, pixelSize: useHeroArt ? 1200 : 600)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                }

                LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

private struct CachedCatalogArtwork: View {
    let url: URL
    let pixelSize: Int
    @State private var artwork: CatalogArtwork?
    @State private var finished = false

    var body: some View {
        Group {
            if let artwork { Image(decorative: artwork.image, scale: 1).resizable().scaledToFill() }
            else if !finished { ProgressView().tint(CloudPalette.accent) }
            else { Image(systemName: "gamecontroller.fill").font(.system(size: 36)).foregroundStyle(.white.opacity(0.6)) }
        }
        .task(id: url) {
            artwork = nil
            finished = false
            let loaded = await CatalogArtworkCache.shared.image(for: url, maximumPixelSize: pixelSize)
            guard !Task.isCancelled else { return }
            artwork = loaded
            finished = true
        }
        .onDisappear { artwork = nil }
    }
}

private struct GameDetailsSheet: View {
    let game: CloudGame
    let isSaved: Bool
    let onToggleSaved: () -> Void
    let isAccountSignedIn: Bool
    let isCloudAccountReady: Bool
    let hasLaunchID: Bool
    let onSignIn: () -> Void
    let onReconnect: () -> Void
    let onPlay: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                GameArtworkView(game: game, useHeroArt: true)
                    .frame(height: 245)
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, CloudPalette.panel.opacity(0.95)], startPoint: .center, endPoint: .bottom)
                    }

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(CloudPalette.primaryText)
                        .padding(10)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(14)
                .accessibilityLabel("Close game details")
            }
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 13) {
                Text([game.publisher, game.releaseYear.isEmpty ? nil : game.releaseYear].compactMap { $0 }.joined(separator: "  ·  ").uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(CloudPalette.accent)

                Text(game.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(CloudPalette.primaryText)

                Text(game.inputSummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CloudPalette.accent)

                ScrollView {
                    Text(game.description)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(CloudPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button(action: playAction) {
                        Label(playButtonTitle, systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(isAccountSignedIn && isCloudAccountReady && !hasLaunchID)

                    Button(action: onToggleSaved) {
                        Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(QuietButtonStyle())

                    Spacer()

                    Text(statusMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CloudPalette.secondaryText)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .padding(18)
        .frame(width: 700, height: 650)
        .background(CloudPalette.panel)
    }

    private var playButtonTitle: String {
        if !isAccountSignedIn { return "Sign in to play" }
        if !isCloudAccountReady { return "Reconnect Xbox account" }
        return "Play now"
    }

    private var playAction: () -> Void {
        if !isAccountSignedIn { return onSignIn }
        if !isCloudAccountReady { return onReconnect }
        return onPlay
    }

    private var statusMessage: String {
        if !isAccountSignedIn { return "Xbox sign-in required" }
        if !isCloudAccountReady { return "Xbox service session unavailable" }
        return hasLaunchID ? "Ready to launch" : "Xbox launch ID unavailable"
    }
}

private struct CatalogLoadState: View {
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView().controlSize(.large).tint(CloudPalette.accent)
                Text("Loading Xbox cloud-game catalog…")
                    .font(.system(size: 13))
                    .foregroundStyle(CloudPalette.secondaryText)
            } else {
                Image(systemName: errorMessage == nil ? "gamecontroller" : "wifi.exclamationmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(CloudPalette.accent)
                Text(errorMessage ?? "No cloud games were returned for this region.")
                    .font(.system(size: 13))
                    .foregroundStyle(CloudPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Retry", action: onRetry).buttonStyle(QuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

private struct CatalogRefreshNotice: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(CloudPalette.accent)
            Text("Showing the previously loaded catalog. Refresh failed: \(message)")
                .font(.system(size: 11))
                .foregroundStyle(CloudPalette.secondaryText)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: onRetry).buttonStyle(.plain).foregroundStyle(CloudPalette.accent)
        }
        .padding(12)
        .background(CloudPalette.raised, in: RoundedRectangle(cornerRadius: 10))
    }
}
