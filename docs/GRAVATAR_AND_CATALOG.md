# Native profile and catalog update

## Gravatar

Open the round account button in the catalog toolbar, enter the email registered with Gravatar, and choose **Use Gravatar**. The Microsoft token store currently has no email address, so PixelCloudX does not guess one from an Xbox gamertag or request additional Microsoft permissions.

The integration includes a native avatar, public display name, biography, location, pronouns, visible verified-account links, public-profile link, refresh, change-address, disconnect, and a link to manage the profile on Gravatar. The same avatar appears in the catalog, stream connection view, and Xbox Guide. Editing the public Gravatar account takes place on Gravatar's website; no browser engine is embedded in PixelCloudX.

The address is trimmed and lowercased, then hashed with SHA-256 according to [Gravatar's identifier specification](https://docs.gravatar.com/api/creating-identifier/). Only the hash is saved as a local profile preference. Connecting explicitly sends that hash to Gravatar for the avatar and public profile. Xbox/Microsoft tokens are never sent to Gravatar; its URLSession has no cookie or credential storage. Responses can use a bounded native HTTP cache. The email field is cleared after connecting. Disconnect clears the saved identifier and displayed profile and stops automatic lookups. This preference is local to PixelCloudX on this Mac and is independent of Xbox authentication; it does not change an Xbox gamerpic.

[Avatar requests](https://docs.gravatar.com/api/avatars/images/) use HTTPS, a size of 160 pixels, rating G, and a 404 default. The [public profile endpoint](https://docs.gravatar.com/sdk/profiles/) works without an embedded API key but exposes only public fields, with a limited set of verified accounts. Missing profiles do not prevent avatar loading: Gravatar documents that secondary email addresses can resolve an avatar while profile lookup requires the primary address. Missing images use local initials. Offline failures retain an already loaded image; rate-limit and unavailable responses offer a manual refresh instead of retrying continuously. Microsoft authentication remains independent of these lookups.

## Catalog design

The visual reference is the currently running Chrome at `play.xbox.com`, inspected on 2026-10-28. Its signed-in catalog uses a black toolbar with centered search and a profile control, grouped left navigation, portrait game covers, horizontal game rows, and landscape promotional tiles. PixelCloudX follows that hierarchy using SwiftUI and native images, while keeping its own name and account behavior.

- A full-width toolbar contains PixelCloudX identity, sidebar toggle, search/clear, controllers, and the account profile.
- The collapsible sidebar contains Home, All games, My list, and locally opened games.
- Home shows locally opened games when available, landscape discovery tiles, and the full catalog.
- All games uses a responsive portrait-cover grid, input filters, and title sorting.
- Search, saved games, controller diagnostics, account entitlements, details, reconnect, and native launch remain accessible.
- Local history is labeled **Recently opened**, since selecting a launch does not prove successful gameplay. No popularity, Game Pass entitlement, friends, or account data is invented to fill the layout.

## SDP timeout correction

The reported startup ultimately failed with “Xbox did not return the SDP signaling response in time.” The current official `PlayService-mlq8q0aq.js` sends `r.Data` directly as the POST body for both SDP and ICE. `StreamConnectionSignaler` uses `Data` internally; it is not an extra JSON property in the HTTP contract. PixelCloudX previously sent `{ "Data": "..." }`, hiding the actual offer/candidates from the endpoint.

PixelCloudX now sends the serialized SDP offer and ICE candidate object directly. It accepts both encoded-string and object `exchangeResponse` values, decodes numeric channel versions (with compatibility for string versions), and surfaces `errorDetails` immediately rather than silently polling until timeout. Startup messages identify the offer/answer/route stage, and **Cancel launch** exits startup without closing the entire app.

## Verification

`Tests/run-regressions.sh` resolves Xcode's existing default DerivedData tree. It checks the SDP and ICE wire bodies, structured answers, service errors, provisioning/cleanup, authentication persistence, and Gravatar normalization, URL bounds, decoded profiles/images, hash persistence, missing/secondary-email profiles, offline/rate-limit behavior, safe links, and disconnect. These tests use synthetic credentials and intercepted HTTP requests.

A public Gravatar example profile returned HTTP 200 without a key during implementation. A successful build or mocked signaling response does not establish that a real Xbox stream reaches playable video/audio; report live acceptance separately.

## Installed-app acceptance on 2026-10-28

The installed arm64 app loaded 565 catalog records, displayed the redesigned discovery tiles and portrait grid, exposed the native Gravatar setup panel, and filtered Madden searches to three matching records. The saved Microsoft login restored without another device-code prompt.

A first live retry passed the previous SDP timeout and exposed numeric channel versions in the answer; the answer decoder was corrected and the regression fixture now contains numeric input/control/chat versions and a compatible string message version. A subsequent Madden NFL 26 retry completed signaling and displayed native video frames inside PixelCloudX. Audio quality, controller gameplay (no controller was attached), and reconnect remain unverified. This observation does not turn Xbox's private endpoints into a supported consumer integration.

The Release build and strict signature verification passed; installed and built executable hashes matched. All three regression executables passed. Xcode's existing default DerivedData location was reused throughout.
