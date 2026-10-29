#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
settings="$(xcodebuild -project PixelCloudX.xcodeproj -scheme PixelCloudX -configuration Debug -showBuildSettings 2>/dev/null)"
products="$(awk -F ' = ' '/ BUILT_PRODUCTS_DIR = / {print $2; exit}' <<< "$settings")"
objroot="$(awk -F ' = ' '/ OBJROOT = / {print $2; exit}' <<< "$settings")"
data_root="${objroot%/Build/Intermediates.noindex}"
[[ -n "$products" && "$data_root" != "$objroot" && -d "$products" ]]
before="$(du -sk "$data_root" | awk '{print $1}')"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Features/Catalog/CloudGame.swift App/Auth/XboxCloudAccountService.swift \
  Features/Streaming/XboxCloudPlayService.swift Tests/XboxCloudPlayServiceRequestTests.swift \
  -o "$products/PixelCloudXRequestTests"
for zone in America/Chicago Asia/Kolkata UTC; do
  TZ="$zone" "$products/PixelCloudXRequestTests"
done
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Features/Catalog/CloudGame.swift App/Auth/XboxCloudAccountService.swift \
  App/Auth/LocalAuthTokenStore.swift App/Auth/MicrosoftDeviceCodeAuthService.swift \
  App/AppCoordinator.swift Tests/AuthenticationPersistenceTests.swift \
  -o "$products/PixelCloudXAuthenticationTests"
"$products/PixelCloudXAuthenticationTests" "$products"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Features/Profile/GravatarService.swift Features/Profile/GravatarProfileView.swift Tests/GravatarTests.swift \
  -o "$products/PixelCloudXGravatarTests"
"$products/PixelCloudXGravatarTests"
rtc_framework="$data_root/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  -F "$rtc_framework" -framework WebRTC -Xlinker -rpath -Xlinker "$rtc_framework" \
  Features/Streaming/NativeRTCExecutor.swift Features/Streaming/StreamVideoView.swift \
  Features/Streaming/StreamMicrophoneController.swift Features/Streaming/NativeRTCMicrophoneTransport.swift \
  Tests/StreamVideoSurfaceTests.swift -o "$products/PixelCloudXSurfaceTests"
"$products/PixelCloudXSurfaceTests"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Features/Controller/ControllerInputService.swift Tests/KeyboardGamepadTests.swift \
  -o "$products/PixelCloudXKeyboardTests"
"$products/PixelCloudXKeyboardTests"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  -F "$rtc_framework" -framework WebRTC -Xlinker -rpath -Xlinker "$rtc_framework" \
  Features/Catalog/CloudGame.swift App/Auth/XboxCloudAccountService.swift \
  Features/Streaming/XboxCloudPlayService.swift Features/Streaming/NativeRTCExecutor.swift \
  Features/Controller/ControllerInputService.swift Features/Streaming/XboxCloudStreamController.swift \
  Features/Streaming/StreamMicrophoneController.swift Features/Streaming/NativeRTCMicrophoneTransport.swift \
  Tests/StreamProtocolTests.swift -o "$products/PixelCloudXStreamProtocolTests"
"$products/PixelCloudXStreamProtocolTests"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Features/Catalog/CloudGame.swift Features/Catalog/GameCatalogService.swift \
  Features/Catalog/CatalogCache.swift Features/Catalog/GameCatalogStore.swift \
  Features/Catalog/CatalogArtworkCache.swift Tests/CatalogCacheTests.swift \
  -o "$products/PixelCloudXCatalogTests"
"$products/PixelCloudXCatalogTests" "$products"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Shared/CloudPalette.swift Features/Profile/GravatarService.swift Features/Profile/GravatarProfileView.swift \
  Features/Streaming/StreamMicrophoneController.swift Features/Streaming/StreamMicrophoneControls.swift \
  Tests/MicrophoneTests.swift -o "$products/PixelCloudXMicrophoneTests"
"$products/PixelCloudXMicrophoneTests"
xcrun swiftc Features/Settings/AppSettings.swift -parse-as-library -module-cache-path "$data_root/ModuleCache.noindex" \
  Tests/SettingsTests.swift -o "$products/PixelCloudXSettingsTests"
"$products/PixelCloudXSettingsTests"
after="$(du -sk "$data_root" | awk '{print $1}')"
printf 'DerivedData: %s\nSize: %s -> %s KiB (%+d KiB)\n' "$data_root" "$before" "$after" "$((after-before))"
