#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 || ! -f "$1" ]]; then
  echo 'Usage: scripts/release.sh /absolute/path/to/sparkle-ed25519.key' >&2
  echo 'A restricted local signing key file is required. No credential-store fallback is permitted.' >&2
  exit 2
fi
key_file="$1"
python3 - "$key_file" <<'PY'
import pathlib,stat,sys
key=pathlib.Path(sys.argv[1])
if not key.is_absolute() or stat.S_IMODE(key.stat().st_mode) & 0o077:
    raise SystemExit('Signing key must use an absolute path and have no group/other permissions.')
PY
settings="$(xcodebuild -project PixelCloudX.xcodeproj -scheme PixelCloudX -configuration Release -showBuildSettings 2>/dev/null)"
products="$(awk -F ' = ' '/ BUILT_PRODUCTS_DIR = / {print $2; exit}' <<< "$settings")"
objroot="$(awk -F ' = ' '/ OBJROOT = / {print $2; exit}' <<< "$settings")"
data_root="${objroot%/Build/Intermediates.noindex}"
[[ -n "$products" && "$data_root" != "$objroot" && -d "$data_root" ]]
before="$(du -sk "$data_root" | awk '{print $1}')"
xcodebuild -project PixelCloudX.xcodeproj -scheme PixelCloudX -configuration Release \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- build
app="$products/PixelCloudX.app"
codesign --verify --deep --strict "$app"
xcrun swift -module-cache-path "$data_root/ModuleCache.noindex" scripts/validate-release-key.swift "$key_file" "$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
archive="$products/Distribution/PixelCloudX-$version-arm64.zip"
mkdir -p "$products/Distribution"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
signer="$data_root/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$signer" ]]
signature="$("$signer" --ed-key-file "$key_file" -p "$archive")"
"$signer" --ed-key-file "$key_file" --verify "$archive" "$signature"
python3 - "$archive" "$version" "$build" "$signature" <<'PY'
import datetime,email.utils,pathlib,sys,xml.etree.ElementTree as E
archive,version,build,signature=sys.argv[1:]
S='http://www.andymatuschak.org/xml-namespaces/sparkle'
E.register_namespace('sparkle',S)
root=E.Element('rss',version='2.0');channel=E.SubElement(root,'channel')
E.SubElement(channel,'title').text='PixelCloudX Updates'
E.SubElement(channel,'link').text='https://github.com/Interlaced-Pixel/PixelCloudX'
E.SubElement(channel,'description').text='Signed PixelCloudX releases from Interlaced Pixel.'
item=E.SubElement(channel,'item')
E.SubElement(item,'title').text=f'PixelCloudX {version}'
E.SubElement(item,'pubDate').text=email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
E.SubElement(item,f'{{{S}}}version').text=build
E.SubElement(item,f'{{{S}}}shortVersionString').text=version
E.SubElement(item,f'{{{S}}}minimumSystemVersion').text='14.0'
E.SubElement(item,'link').text=f'https://github.com/Interlaced-Pixel/PixelCloudX/releases/tag/v{version}'
E.SubElement(item,'description').text='See the release page for changes and known limitations.'
E.SubElement(item,'enclosure',{'url':f'https://github.com/Interlaced-Pixel/PixelCloudX/releases/download/v{version}/{pathlib.Path(archive).name}',
    'length':str(pathlib.Path(archive).stat().st_size),'type':'application/octet-stream',f'{{{S}}}edSignature':signature})
E.indent(root)
E.ElementTree(root).write('docs/appcast.xml',encoding='utf-8',xml_declaration=True)
PY
"$signer" --ed-key-file "$key_file" docs/appcast.xml
"$signer" --ed-key-file "$key_file" --verify docs/appcast.xml
(
  cd "$(dirname "$archive")"
  shasum -a 256 "$(basename "$archive")"
) > "$archive.sha256"
after="$(du -sk "$data_root" | awk '{print $1}')"
printf 'Archive: %s\nDerivedData: %s\nSize: %s -> %s KiB (%+d KiB)\n' "$archive" "$data_root" "$before" "$after" "$((after-before))"
