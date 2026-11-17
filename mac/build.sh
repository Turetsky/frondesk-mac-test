#!/bin/bash
# Frondesk Setup .pkg — build, sign (Developer ID), notarize, staple. Runs on the Codemagic Mac from the
# synced repo (mac/release.sh puts this dir + the engine there). Stages: keychain | app | pkg | notarize.
# Env (Codemagic app variable group mac_signing, secure): DEVID_APP_P12_B64 DEVID_INSTALLER_P12_B64
# DEVID_P12_PASS ASC_KEY_P8_B64 ASC_KEY_ID ASC_ISSUER_ID. Codemagic sets BUILD_NUMBER.
set -euo pipefail
cd "$(dirname "$0")"
TEAM=B64X7H65W6; VER=1.0.${BUILD_NUMBER:-0}
APP_SIGN="Developer ID Application: Jacob Turetsky ($TEAM)"; PKG_SIGN="Developer ID Installer: Jacob Turetsky ($TEAM)"
KC=$HOME/Library/Keychains/frondesk-signing.keychain-db
APP=build/root/Applications/Frondesk.app; PKG=out/frondesk-setup.pkg

keychain() {
  # own keychain: Codemagic's `keychain add-certificates` lets only codesign use the key (pkgbuild then fails
  # with errSecInteractionNotAllowed); the partition list apple-tool:,apple: covers codesign + pkgbuild.
  local kp; kp=$(uuidgen)
  security create-keychain -p "$kp" "$KC"; security set-keychain-settings "$KC"; security unlock-keychain -p "$kp" "$KC"
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"'); security default-keychain -d user -s "$KC"
  for t in APP INSTALLER; do v=DEVID_${t}_P12_B64
    printf '%s' "${!v}" | base64 -D > /tmp/$t.p12
    security import /tmp/$t.p12 -k "$KC" -f pkcs12 -P "$DEVID_P12_PASS" -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productbuild
    rm -f /tmp/$t.p12
  done
  security set-key-partition-list -S apple-tool:,apple: -s -k "$kp" "$KC" >/dev/null
  # the Developer ID G2 intermediate isn't on the build image; without it neither identity is valid
  curl -fsSL -o /tmp/DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
  security import /tmp/DeveloperIDG2CA.cer -k "$KC"
  security find-identity -v -p codesigning "$KC" | grep -F "$APP_SIGN"
  security find-identity -v -p basic "$KC" | grep -F "$PKG_SIGN"
}

app() {
  rm -rf build out; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/scripts out
  clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -O2 -o "$APP/Contents/MacOS/Frondesk" launcher.c
  install -m 755 open.sh "$APP/Contents/Resources/open.sh"
  install -m 755 frondesk.sh "$APP/Contents/Resources/frondesk"   # the engine, __KIT_URL__ already filled in
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ai.frondesk.desk' -c 'Add :CFBundleName string Frondesk' \
    -c 'Add :CFBundleDisplayName string Frondesk' -c 'Add :CFBundleExecutable string Frondesk' \
    -c 'Add :CFBundlePackageType string APPL' -c "Add :CFBundleShortVersionString string $VER" \
    -c "Add :CFBundleVersion string $VER" -c 'Add :LSMinimumSystemVersion string 12.0' "$APP/Contents/Info.plist"
  codesign --force --options runtime --timestamp -s "$APP_SIGN" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
}

pkg() {
  install -m 755 postinstall build/scripts/postinstall
  # not relocatable: always /Applications/Frondesk.app, even if a copy with the same bundle id exists elsewhere
  pkgbuild --analyze --root build/root build/component.plist
  plutil -replace 0.BundleIsRelocatable -bool NO build/component.plist
  pkgbuild --root build/root --component-plist build/component.plist --install-location / --scripts build/scripts \
    --identifier ai.frondesk.desk.pkg --version "$VER" --sign "$PKG_SIGN" --timestamp "$PKG"
  pkgutil --check-signature "$PKG"
}

notarize() {
  local k sid st; k=$(mktemp -d)/asc.p8; printf '%s' "$ASC_KEY_P8_B64" | base64 -D > "$k"
  local n=(--key "$k" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  xcrun notarytool submit "$PKG" "${n[@]}" --wait --timeout "${NOTARY_TIMEOUT:-20m}" --output-format json > out/notary.json || true
  cat out/notary.json; echo
  sid=$(plutil -extract id raw out/notary.json); st=$(plutil -extract status raw out/notary.json 2>/dev/null || echo timeout)
  xcrun notarytool log "$sid" "${n[@]}" out/notary-log.json >/dev/null 2>&1 && cat out/notary-log.json; echo
  rm -f "$k"; echo "NOTARY id=$sid status=$st"; [ "$st" = Accepted ]
  xcrun stapler staple "$PKG"; xcrun stapler validate "$PKG"
  spctl -a -vv -t install "$PKG"
  spctl -a -vv "$APP"
  shasum -a 256 "$PKG"
}

"$@"
