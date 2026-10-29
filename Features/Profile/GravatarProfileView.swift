import AppKit
import SwiftUI

@MainActor
final class GravatarStore: ObservableObject {
    @Published private(set) var identifier: String?
    @Published private(set) var image: NSImage?
    @Published private(set) var profile: GravatarProfile?
    @Published private(set) var isLoading = false
    @Published private(set) var status: String?
    private let defaults: UserDefaults
    private let service: GravatarService
    private let key = "PixelCloudX.gravatarIdentifier"
    private var generation = 0

    init(defaults: UserDefaults = .standard, service: GravatarService = GravatarService()) {
        self.defaults = defaults
        self.service = service
        if let saved = defaults.string(forKey: key), GravatarService.isValidIdentifier(saved) { identifier = saved }
    }

    func connect(email: String) throws {
        let hash = try GravatarService.identifier(for: email)
        generation += 1
        identifier = hash
        defaults.set(hash, forKey: key)
        image = nil
        profile = nil
        status = nil
    }

    func disconnect() {
        generation += 1
        defaults.removeObject(forKey: key)
        identifier = nil
        image = nil
        profile = nil
        status = nil
        isLoading = false
    }

    func refresh() async {
        guard let identifier else { return }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        status = nil
        defer { if generation == requestGeneration { isLoading = false } }
        // Avatar and public profile are independent: secondary email hashes may
        // resolve an avatar while only the primary hash resolves a profile.
        async let avatarResult = loadAvatar(identifier)
        async let profileResult = loadProfile(identifier)
        let (avatar, details) = await (avatarResult, profileResult)
        guard !Task.isCancelled, generation == requestGeneration else { return }
        switch avatar {
        case .success(let data):
            if let data {
                if let decoded = NSImage(data: data) { image = decoded }
                else { status = GravatarError.invalidImage.localizedDescription }
            } else { image = nil }
        case .failure(let error): status = error.localizedDescription
        }
        switch details {
        case .success(let value): profile = value
        case .failure(let error): status = status ?? "Public profile could not be loaded: \(error.localizedDescription)"
        }
        if image == nil && profile == nil && status == nil { status = "No Gravatar found for this address. Your initials will be used." }
    }

    private func loadAvatar(_ hash: String) async -> Result<Data?, Error> {
        do { return .success(try await service.avatar(identifier: hash)) } catch { return .failure(error) }
    }
    private func loadProfile(_ hash: String) async -> Result<GravatarProfile?, Error> {
        do { return .success(try await service.profile(identifier: hash)) } catch { return .failure(error) }
    }
}

struct AccountAvatar: View {
    @EnvironmentObject private var gravatar: GravatarStore
    let accountName: String?
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.13))
            if let image = gravatar.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(accountName?.prefix(1).uppercased() ?? "G")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        .accessibilityLabel(gravatar.image == nil ? "Account avatar" : "Gravatar avatar")
    }
}

struct AccountProfileView: View {
    @EnvironmentObject private var gravatar: GravatarStore
    let accountName: String?
    let serviceSummary: String?
    let serviceError: String?
    let onReconnect: () -> Void
    let onSignOut: () -> Void
    @State private var email = ""
    @State private var inputError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    AccountAvatar(accountName: accountName, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountName ?? "Guest").font(.system(size: 18, weight: .semibold))
                        Text("PixelCloudX account").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if accountName != nil {
                    Text(serviceError ?? serviceSummary ?? "Microsoft sign-in saved")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if serviceError != nil { Button("Reconnect Xbox services", action: onReconnect) }
                }
                Divider()
                HStack {
                    Text("Gravatar").font(.headline)
                    Spacer()
                    if gravatar.isLoading { ProgressView().controlSize(.small) }
                }
                if let profile = gravatar.profile {
                    VStack(alignment: .leading, spacing: 7) {
                        if let name = profile.displayName, !name.isEmpty { Text(name).font(.headline) }
                        if let pronouns = profile.pronouns, !pronouns.isEmpty { Text(pronouns).font(.caption).foregroundStyle(.secondary) }
                        if let bio = profile.description, !bio.isEmpty { Text(bio).font(.callout).lineLimit(5) }
                        if let location = profile.location, !location.isEmpty { Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary) }
                        if let url = GravatarProfile.webURL(profile.profileURL) { Link("View Gravatar profile ↗", destination: url) }
                        ForEach(Array((profile.verifiedAccounts ?? []).filter { $0.isHidden != true }.prefix(4).enumerated()), id: \.offset) { _, account in
                            if let url = GravatarProfile.webURL(account.url) {
                                Link(destination: url) { Label(account.serviceLabel ?? "Verified account", systemImage: "checkmark.seal") }.font(.caption)
                            }
                        }
                    }
                }
                if let status = gravatar.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Text(gravatar.identifier == nil ? "Use the email associated with your Gravatar for your avatar and public profile." : "Your Gravatar is connected on this Mac. Enter another email to change it.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Gravatar email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                    .accessibilityIdentifier("gravatar-email")
                if let inputError { Text(inputError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button(gravatar.identifier == nil ? "Use Gravatar" : "Update Gravatar", action: connect)
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if gravatar.identifier != nil {
                        Button("Refresh") { Task { await gravatar.refresh() } }.disabled(gravatar.isLoading)
                        Button("Disconnect") { gravatar.disconnect(); email = ""; inputError = nil }
                    }
                }
                Text("Connecting sends a SHA-256 hash of your email to Gravatar. Only that hash is saved on this Mac. This changes your PixelCloudX profile, not your Xbox gamerpic.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Manage your Gravatar ↗", destination: URL(string: "https://gravatar.com")!).font(.caption)
                Divider()
                Button(accountName == nil ? "Back to welcome" : "Sign out", action: onSignOut)
            }
            .padding(24)
        }
        .frame(width: 390, height: 600)
    }

    private func connect() {
        do {
            try gravatar.connect(email: email)
            email = ""
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }
}

struct AccountProfileButton: View {
    let accountName: String?
    let serviceSummary: String?
    let serviceError: String?
    let onReconnect: () -> Void
    let onSignOut: () -> Void
    @State private var isPresented = false
    var body: some View {
        Button { isPresented.toggle() } label: { AccountAvatar(accountName: accountName) }
            .buttonStyle(.plain).accessibilityLabel("Account and Gravatar")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                AccountProfileView(accountName: accountName, serviceSummary: serviceSummary, serviceError: serviceError,
                                   onReconnect: onReconnect, onSignOut: { isPresented = false; onSignOut() })
            }
    }
}
