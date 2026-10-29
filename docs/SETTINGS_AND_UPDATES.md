# Settings and software updates

Open **PixelCloudX → Settings…** with **Command-comma**, the catalogue gear, or the stream Guide. Settings opened during a stream pause game input behind the Guide; resume explicitly afterward.

The seven sections cover startup/overlay behavior, display, audio and input, Xbox accessibility, catalogue caching, account/Gravatar, and Sparkle updates. Preferences save immediately and restore at launch. Field-level decoding preserves valid values when another field is corrupt or from a newer schema. Numeric values are bounded, and reset affects playback/catalogue preferences without removing accounts or saved games.

## Where settings take effect

| Controls | Applied by | When |
| --- | --- | --- |
| Original/16:9/16:10/4:3/21:9; fit/fill/stretch | Native Metal view geometry | Immediately |
| 720p/1080p/1440p/automatic request | Xbox control-channel resolution alias and preferred dimensions | When channels become ready, and when changed |
| Volume and game-audio mute | Native WebRTC remote audio source/track | Immediately and for newly received tracks |
| Keyboard gamepad; background controller; extra deadzone | AppKit and Game Controller sampling | Immediately |
| Echo cancellation, noise suppression, automatic gain | Native WebRTC capture constraints | Next microphone enable |
| Console language, numeric high contrast, magnifier, text-to-speech | Xbox cloud play-request settings | Next game session |
| Catalogue refresh, interval, sidebar, sort, update badges | Native catalogue UI/repository | Immediately |
| Automatic update checks/downloads | Sparkle's own persistent updater preferences | Immediately |

Xbox may limit requested resolution or accessibility behavior. These values are local preferences sent through private session contracts; PixelCloudX does not claim account-wide preference synchronization. Display ratios change local presentation, rather than generating additional game content outside the original picture.

Microphone capture intent is transient: each stream starts with the microphone off. The processing preferences persist. Command-M, the Stream menu, overlay, and Guide share one microphone controller. The View menu shares the same ratio, scaling, resolution, and statistics preferences as Settings.

## Cache management

Catalogue metadata and public artwork are separate caches. Settings shows artwork disk usage and offers an explicit confirmation before clearing downloaded covers. The operation clears only PixelCloudX's artwork files and decoded images; in-flight writes use a generation guard. It does not clear metadata, logins, saved games, or unrelated system/build caches. Automatic metadata refresh can be disabled, with a manual refresh always available while browsing.

## Signed updates

Sparkle 2.10.1 is pinned in Swift Package Manager. The app uses the standard native updater UI with HTML release notes disabled. Installer XPC support and sandbox Mach lookup exceptions follow Sparkle's sandbox documentation. Both the appcast and update archives require Ed25519 signatures, and archive verification occurs before extraction.

The signed feed is `https://github.com/Interlaced-Pixel/PixelCloudX/releases/latest/download/appcast.xml`. Both the feed and archives live in GitHub Releases; no project website is published. A source copy of the feed lives at `docs/appcast.xml`. Update checks wait during a stream. If an installation was already pending when gameplay began, its relaunch waits until the stream ends.

No credentials or update-signing keys are stored in Keychain. The release key is a permissions-restricted local file outside the repository. Signing commands require an explicit key-file argument and never use a credential-store fallback. Keep a secure offline backup: loss of this key prevents signing updates trusted by existing installations.

Run tests and create a release archive using the existing Xcode DerivedData tree:

```sh
bash Tests/run-regressions.sh
scripts/release.sh "$HOME/.config/PixelCloudX/keys/sparkle-ed25519.key"
```

The release script builds arm64, verifies the bundle signature, creates a ZIP under the existing Release products' `Distribution` directory, signs/verifies it, generates/signs/verifies the feed, and records the archive SHA-256. Publish the matching version tag and archive together with the matching signed feed. Never modify a signed feed without signing it again.

The initial distribution is ad-hoc signed and **not notarized**. macOS may block downloaded copies. Sparkle's Ed25519 signatures establish update authenticity; they do not substitute for Apple Developer ID signing or notarization.

## Verification

Regression coverage includes relaunch persistence, missing/corrupt/unknown fields, nested Xbox settings, bounds, reset isolation, display geometry, request wire types, microphone races, native peer behavior, controller packet fixtures, and catalogue recovery. Live runtime evidence is documented separately from these isolated checks in [input and microphone recovery](INPUT_AND_MIC_RECOVERY.md).
