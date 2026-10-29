import SwiftUI

struct AppRootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var route: AppRoute = .welcome
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gravatar: GravatarStore

    var body: some View {
        Group {
            switch route {
            case .welcome:
                WelcomeView(
                    isAuthenticating: coordinator.signInChallenge != nil,
                    isRestoringAccount: coordinator.isRestoringAccount,
                    accountName: coordinator.accountName,
                    challenge: coordinator.signInChallenge,
                    onBrowseCatalog: { route = .catalog },
                    onSignIn: coordinator.beginSignIn,
                    onCancelSignIn: coordinator.cancelSignIn
                )
            case .catalog:
                CatalogView(
                    accountName: coordinator.accountName,
                    cloudServiceSummary: coordinator.isSignedIn
                        ? coordinator.cloudServiceSummary
                        : nil,
                    cloudServiceErrorMessage: coordinator.xboxServiceErrorMessage,
                    accountCatalogProductIDs: coordinator.accountCatalogProductIDs,
                    accountEntitledProductIDs: coordinator.accountEntitledProductIDs,
                    streamController: coordinator.streamController,
                    isAccountSignedIn: coordinator.isSignedIn,
                    isCloudAccountReady: coordinator.xboxAccount?.launchOffering != nil,
                    onStartStream: coordinator.startStream,
                    onSignIn: {
                        route = .welcome
                        coordinator.beginSignIn()
                    },
                    onReconnectXbox: {
                        Task { await coordinator.reconnectXboxServices() }
                    },
                    onSignOut: {
                        Task { await coordinator.signOut() }
                    }
                )
            }
        }
        .background(CloudPalette.canvas)
        .environmentObject(gravatar)
        .task(id: gravatar.identifier) { await gravatar.refresh() }
        .onChange(of: coordinator.isSignedIn) { _, signedIn in
            route = signedIn && settings.values.startInCatalog ? .catalog : .welcome
        }
        .alert("Microsoft account", isPresented: Binding(
            get: { coordinator.lastAuthError != nil },
            set: { if !$0 { coordinator.clearAuthError() } }
        )) {
            Button("OK", role: .cancel) { coordinator.clearAuthError() }
        } message: {
            Text(coordinator.lastAuthError ?? "")
        }
        .confirmationDialog(
            "An Xbox cloud stream is still active.",
            isPresented: Binding(
                get: { coordinator.isQuitConfirmationPresented },
                set: { if !$0 { coordinator.cancelQuit() } }
            ),
            titleVisibility: .visible
        ) {
            Button("End Stream and Quit", role: .destructive) {
                coordinator.endStreamAndQuit()
            }
            Button("Keep Playing", role: .cancel) {
                coordinator.cancelQuit()
            }
        } message: {
            Text("PixelCloudX will end the Xbox session before quitting.")
        }
    }
}

private enum AppRoute {
    case welcome
    case catalog
}
