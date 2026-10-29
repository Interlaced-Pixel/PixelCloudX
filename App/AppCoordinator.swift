import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class AppCoordinator {
    enum AuthenticationState {
        case restoring
        case signedOut
        case authenticating(MicrosoftDeviceCodeChallenge)
        case signedIn
    }

    private(set) var authenticationState: AuthenticationState = .restoring
    var lastAuthError: String?
    private(set) var xboxAccount: XboxCloudAccountSession?
    private(set) var xboxServiceErrorMessage: String?
    var isQuitConfirmationPresented = false
    let streamController = XboxCloudStreamController()

    private let tokenStore: LocalAuthTokenStore
    private let authService: MicrosoftDeviceCodeAuthService
    private let xboxAccountService: XboxCloudAccountService
    private var signInTask: Task<Void, Never>?
    private var didRestore = false
    private var accountGeneration = 0

    init(tokenStore: LocalAuthTokenStore = LocalAuthTokenStore(),
         authService: MicrosoftDeviceCodeAuthService = MicrosoftDeviceCodeAuthService(),
         xboxAccountService: XboxCloudAccountService = XboxCloudAccountService()) {
        self.tokenStore = tokenStore
        self.authService = authService
        self.xboxAccountService = xboxAccountService
    }

    var isSignedIn: Bool {
        if case .signedIn = authenticationState { return true }
        return false
    }

    var isRestoringAccount: Bool {
        if case .restoring = authenticationState { return true }
        return false
    }

    var signInChallenge: MicrosoftDeviceCodeChallenge? {
        if case .authenticating(let challenge) = authenticationState { return challenge }
        return nil
    }

    var accountName: String? {
        guard isSignedIn else { return nil }
        return xboxAccount?.gamertag ?? "Microsoft account"
    }

    var accountCatalogProductIDs: [String] {
        xboxAccount?.catalogProductIDs ?? []
    }

    var accountEntitledProductIDs: [String] {
        xboxAccount?.entitledProductIDs ?? []
    }

    var cloudServiceSummary: String? {
        guard isSignedIn else { return nil }
        guard let xboxAccount else { return "Microsoft account authorized · reconnecting Xbox services" }
        return "Xbox account connected · \(xboxAccount.entitledProductIDs.count) library games"
    }

    func onAppear() async {
        guard !didRestore else { return }
        didRestore = true

        guard await tokenStore.load() != nil else {
            authenticationState = .signedOut
            return
        }

        // Keep the saved login through temporary refresh/service failures.
        // Reconnect refreshes expired credentials before rebuilding Xbox state.
        authenticationState = .signedIn
        await reconnectXboxServices()
    }

    func beginSignIn() {
        accountGeneration += 1
        let generation = accountGeneration
        signInTask?.cancel()
        lastAuthError = nil
        signInTask = Task {
            do {
                let challenge = try await authService.requestDeviceCode()
                guard !Task.isCancelled, generation == accountGeneration else { return }
                authenticationState = .authenticating(challenge)

                let tokens = try await authService.completeSignIn(challenge)
                guard !Task.isCancelled, generation == accountGeneration else { return }
                try await tokenStore.save(tokens)
                guard !Task.isCancelled, generation == accountGeneration else { return }
                authenticationState = .signedIn
                await loadXboxAccount(accessToken: tokens.accessToken)
            } catch is CancellationError {
                guard generation == accountGeneration else { return }
                authenticationState = .signedOut
            } catch {
                guard generation == accountGeneration else { return }
                authenticationState = .signedOut
                lastAuthError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        accountGeneration += 1
        signInTask?.cancel()
        signInTask = nil
        authenticationState = .signedOut
    }

    func signOut() async {
        accountGeneration += 1
        signInTask?.cancel()
        signInTask = nil
        do {
            try await tokenStore.clear()
            xboxAccount = nil
            xboxServiceErrorMessage = nil
            authenticationState = .signedOut
        } catch {
            lastAuthError = error.localizedDescription
        }
    }

    func clearAuthError() {
        lastAuthError = nil
    }

    func requestQuit() {
        guard streamController.isActive else {
            NSApplication.shared.terminate(nil)
            return
        }
        isQuitConfirmationPresented = true
    }

    func cancelQuit() {
        isQuitConfirmationPresented = false
    }

    func endStreamAndQuit() {
        isQuitConfirmationPresented = false
        Task {
            await streamController.stop()
            // AppKit may run a nested termination loop. Enter it after this
            // Swift task has released MainActor so the delegate can finish.
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func prepareForTermination() async {
        accountGeneration += 1
        signInTask?.cancel()
        await streamController.stop()
    }

    func startStream(game: CloudGame, controllerInput: ControllerInputService) {
        guard let xboxAccount else { return }
        streamController.start(game: game, account: xboxAccount, controllerInput: controllerInput) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.cloudTransferToken()
        }
    }

    private func cloudTransferToken() async throws -> String {
        let generation = accountGeneration
        let tokens = try await currentMicrosoftTokens()
        let result = try await authService.cloudTransferToken(using: tokens)
        try Task.checkCancellation()
        guard generation == accountGeneration, isSignedIn else { throw CancellationError() }
        // Persist rotated refresh credentials before sending the transfer token.
        try await tokenStore.save(result.tokens)
        return result.token
    }

    private func currentMicrosoftTokens() async throws -> StoredMicrosoftTokens {
        let generation = accountGeneration
        guard let savedTokens = await tokenStore.load() else {
            throw MicrosoftAuthError.reauthenticationRequired
        }
        if savedTokens.expiresAt > Date().addingTimeInterval(60) { return savedTokens }
        let tokens = try await authService.refresh(savedTokens)
        try Task.checkCancellation()
        guard generation == accountGeneration, isSignedIn else { throw CancellationError() }
        try await tokenStore.save(tokens)
        return tokens
    }

    func reconnectXboxServices() async {
        guard isSignedIn else {
            lastAuthError = "Sign in to Microsoft again before reconnecting Xbox services."
            return
        }
        let generation = accountGeneration
        xboxServiceErrorMessage = nil
        do {
            let tokens = try await currentMicrosoftTokens()
            guard generation == accountGeneration, isSignedIn else { return }
            await loadXboxAccount(accessToken: tokens.accessToken)
        } catch is CancellationError {
            return
        } catch MicrosoftAuthError.reauthenticationRequired {
            guard generation == accountGeneration else { return }
            xboxAccount = nil
            authenticationState = .signedOut
            lastAuthError = MicrosoftAuthError.reauthenticationRequired.localizedDescription
        } catch {
            guard generation == accountGeneration else { return }
            xboxAccount = nil
            xboxServiceErrorMessage = "Saved login retained. Could not reconnect: \(error.localizedDescription)"
        }
    }

    private func loadXboxAccount(accessToken: String) async {
        let generation = accountGeneration
        xboxServiceErrorMessage = nil
        do {
            let account = try await xboxAccountService.loadAccount(using: accessToken)
            guard generation == accountGeneration, isSignedIn else { return }
            xboxAccount = account
        } catch {
            guard generation == accountGeneration, isSignedIn else { return }
            xboxAccount = nil
            xboxServiceErrorMessage = error.localizedDescription
        }
    }
}
