import Foundation

struct StoredMicrosoftTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

/// Stores Microsoft OAuth tokens in an app-private JSON file, without Keychain access.
/// The token values are unencrypted; the containing directory is mode 0700 and the file is mode 0600.
actor LocalAuthTokenStore {
    private struct FileContents: Codable {
        let version: Int
        let tokens: StoredMicrosoftTokens
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let supportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            self.fileURL = supportDirectory
                .appendingPathComponent("PixelCloudX", isDirectory: true)
                .appendingPathComponent("microsoft-auth.json", isDirectory: false)
        }
    }

    func load() -> StoredMicrosoftTokens? {
        do {
            try prepareDirectory()
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            try setFilePermissions()
            let contents = try JSONDecoder().decode(
                FileContents.self,
                from: Data(contentsOf: fileURL, options: .mappedIfSafe)
            )
            return contents.version == 1 ? contents.tokens : nil
        } catch {
            return nil
        }
    }

    func save(_ tokens: StoredMicrosoftTokens) throws {
        do {
            try prepareDirectory()
            let data = try JSONEncoder().encode(FileContents(version: 1, tokens: tokens))
            try data.write(to: fileURL, options: .atomic)
            try setFilePermissions()
        } catch {
            throw MicrosoftAuthError.localStorage(error.localizedDescription)
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw MicrosoftAuthError.localStorage(error.localizedDescription)
        }
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func setFilePermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
