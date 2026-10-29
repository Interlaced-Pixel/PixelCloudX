# PixelCloudX project guidance

- Keep the app a native macOS application built with SwiftUI and system frameworks. Do not add WKWebView, WebKit, Chromium, CEF, or another browser wrapper.
- Keep all user-facing design and architecture documents under docs/.
- Treat the current sign-in and game catalog as a UI preview. Do not claim account authentication, catalog availability, or cloud playback works until a supported service integration exists.
- Keep Apple silicon as the target architecture (arm64) and prefer native system rendering and input APIs.
- Use Xcode's default DerivedData location unless this project later adopts one stable project-specific path. Reuse it across configurations; do not create timestamped or task-specific build directories.
- Before building, check the current build instructions and DerivedData location. After a build, report the path used and its size change. Do not clean shared caches or delete build data unless requested.

- Never use Keychain for credentials, tokens, or update signing keys. Use permission-restricted local files. Release commands must always specify the signing key file explicitly and must never fall back to Keychain.
