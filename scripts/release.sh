#!/bin/bash
# Local release: build, sign with Developer ID, notarize, staple and publish a GitHub release,
# without ever uploading the certificate anywhere.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain (Xcode → Settings → Accounts → Manage Certificates).
#   2. Notarization credentials stored in the keychain:
#        xcrun notarytool store-credentials folio-notary --apple-id you@example.com --team-id XXXXXXXXXX
#      (asks for an app-specific password from appleid.apple.com)
#   3. gh auth login
#
# Usage: scripts/release.sh 1.0.0   (the team ID is read from the certificate; override with DEVELOPMENT_TEAM=...)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh X.Y.Z}"
PROFILE="${NOTARY_PROFILE:-folio-notary}"
cd "$(dirname "$0")/.."

# preflight: say exactly what is missing instead of failing deep inside codesign or notarytool
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [ -z "$IDENTITY" ]; then
  echo "no 'Developer ID Application' certificate in your keychain."
  echo "create one: Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application"
  exit 1
fi
# team ID is the 10 characters in parentheses of the identity name
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')}"
export DEVELOPMENT_TEAM
if ! xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1; then
  echo "no notarization credentials stored under keychain profile '$PROFILE'. Store them once:"
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id you@example.com --team-id $DEVELOPMENT_TEAM"
  echo "(it asks for an app-specific password from https://account.apple.com → Sign-In and Security → App-Specific Passwords)"
  exit 1
fi
command -v xcodegen > /dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
gh auth status > /dev/null 2>&1 || { echo "gh not logged in: gh auth login"; exit 1; }
echo "signing as: $IDENTITY"

git diff --quiet && git diff --cached --quiet || { echo "commit or stash your changes first"; exit 1; }

xcodegen generate
xcodebuild -project IBKRWidget.xcodeproj -scheme IBKRWidget -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" build | grep -E "error:|warning: .*deprecated|BUILD" || true

APP=build/Build/Products/Release/Folio.app
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type exec --verbose=2 "$APP"

ZIP="build/Folio-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
# bare file name in the checksum file, so `shasum -c Folio-X.Y.Z.zip.sha256` works next to the download
(cd build && shasum -a 256 "Folio-$VERSION.zip" > "Folio-$VERSION.zip.sha256")

git tag -a "v$VERSION" -m "Folio $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --title "Folio $VERSION" --generate-notes
echo "released v$VERSION"
