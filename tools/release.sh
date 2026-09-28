#!/usr/bin/env bash
# Archive, sign and upload TeslaNav to App Store Connect (TestFlight first, then review).
#
# Signing is automatic (-allowProvisioningUpdates): Xcode registers the App IDs, the App Group
# and the distribution profile on first run. That needs App Store Connect access, either:
#
#   a) an Apple Account for team SXEFA57E5G in Xcode → Settings → Accounts; or
#   b) an App Store Connect API key (App Manager role) at
#      ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8, plus:
#        export ASC_KEY_ID=XXXXXXXXXX
#        export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# The first signed run may stop on a "codesign wants to use a key" dialog: click Always Allow.
set -euo pipefail
cd "$(dirname "$0")/.."

AUTH=(-allowProvisioningUpdates)
if [ -n "${ASC_KEY_ID:-}" ]; then
  KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [ -f "$KEY" ] || { echo "No API key at $KEY — see the header of this script." >&2; exit 1; }
  [ -n "${ASC_ISSUER_ID:-}" ] || { echo "ASC_KEY_ID is set but ASC_ISSUER_ID is not." >&2; exit 1; }
  AUTH+=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "Using App Store Connect API key $ASC_KEY_ID."
else
  echo "No ASC_KEY_ID set — relying on the Apple Account in Xcode → Settings → Accounts."
fi

xcodegen generate
if [ "${REUSE_ARCHIVE:-0}" = "1" ] && [ -d build/TeslaNav.xcarchive ]; then
  echo "Reusing build/TeslaNav.xcarchive."
else
  xcodebuild -project TeslaNav.xcodeproj -scheme TeslaNav -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/TeslaNav.xcarchive "${AUTH[@]}" archive
fi

rm -rf build/export
xcodebuild -exportArchive -archivePath build/TeslaNav.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export "${AUTH[@]}"
echo "Uploaded. It appears in App Store Connect → TestFlight after processing (~10–30 min)."
