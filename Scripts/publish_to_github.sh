#!/usr/bin/env bash
#
# publish_to_github.sh — sync binary release whitelist to a public GitHub checkout.
#
# Env (optional — defaults below):
#   GITHUB_REPO       default: INMO-X/IMBluetoothKit
#   PUBLIC_CHECKOUT   local clone of https://github.com/INMO-X/IMBluetoothKit.git
#                     default: first existing among:
#                       ../IMBluetoothKit-public
#                       ../../../PrivateLibrary/IMBluetoothKit-public
#                       ../../../../PrivateLibrary/IMBluetoothKit-public
#   SKIP_BUILD=1      skip ./Scripts/build_xcframeworks.sh when XCFrameworks/ already exist
#                     (must be the exact string "1"; any other value still builds)
#
# Customer Podfile fail-safe (document in README; CocoaPods cannot enforce):
#   Binary customers must use Full OR exactly one Devices/<X> (e.g. Devices/C100).
#   Never `pod '…/Devices'` alone (pulls all nested XCFrameworks) and never two
#   Devices/* lines — same Swift module IMBluetoothKit → duplicate symbols.
#
# Public repo is binary-only for IMBluetoothKit; ExampleApp demo sources live under ExampleApp/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo $ROOT
GITHUB_REPO="${GITHUB_REPO:-INMO-X/IMBluetoothKit}"

if [[ -z "${PUBLIC_CHECKOUT:-}" ]]; then
  for candidate in \
    "$ROOT"
  do
    if [[ -d "$candidate/.git" ]]; then
      PUBLIC_CHECKOUT="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi
: "${PUBLIC_CHECKOUT:?Set PUBLIC_CHECKOUT=/path/to/clone of https://github.com/INMO-X/IMBluetoothKit.git}"
echo "GITHUB_REPO=$GITHUB_REPO"
echo "PUBLIC_CHECKOUT=$PUBLIC_CHECKOUT"

if [[ "${SKIP_BUILD:-}" == "1" ]]; then
  if [[ ! -d "$ROOT/XCFrameworks" ]] || [[ -z "$(find "$ROOT/XCFrameworks" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]]; then
    echo "SKIP_BUILD=1 but XCFrameworks/ is missing or empty; run ./Scripts/build_xcframeworks.sh first" >&2
    exit 1
  fi
#else
#  "$ROOT/Scripts/build_xcframeworks.sh"
fi

VERSION="$(ruby -e "require 'cocoapods'; puts Pod::Specification.from_file('$ROOT/IMBluetoothKit.podspec').version")"

rsync -a --delete "$ROOT/XCFrameworks/" "$PUBLIC_CHECKOUT/XCFrameworks/"
#cp "$ROOT/IMBluetoothKit.podspec" "$PUBLIC_CHECKOUT/IMBluetoothKit.podspec"
#cp "$ROOT/LICENSE" "$PUBLIC_CHECKOUT/"
#cp "$ROOT/README.md" "$PUBLIC_CHECKOUT/"
#cp "$ROOT/IMBluetoothKit/PrivacyInfo.xcprivacy" "$PUBLIC_CHECKOUT/PrivacyInfo.xcprivacy"
#mkdir -p "$PUBLIC_CHECKOUT/docs"
#cp "$ROOT/docs/USAGE.md" "$ROOT/docs/PRIVACY.md" "$PUBLIC_CHECKOUT/docs/"
#cp "$ROOT/Scripts/public-repo.gitignore" "$PUBLIC_CHECKOUT/.gitignore"

## Remove any leftover Framework-era podspec from prior publishes.
#rm -f "$PUBLIC_CHECKOUT/IMBluetoothFramework.podspec"

# Refuse library .swift sources (binary-only); ExampleApp demo Swift is allowed.
leaked="$(find "$PUBLIC_CHECKOUT" -name '*.swift' ! -path '*/ExampleApp/*' 2>/dev/null || true)"
if [[ -n "$leaked" ]]; then
  echo "Refusing to publish: .swift sources detected in public checkout:" >&2
  echo "$leaked" >&2
  exit 1
fi

if ! git -C "$PUBLIC_CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "PUBLIC_CHECKOUT is not a git repository: $PUBLIC_CHECKOUT" >&2
  exit 1
fi

cd "$PUBLIC_CHECKOUT"
git add -A
git commit -m "Release $VERSION"
# Move/replace tag for this version if republishing the same semver.
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  git tag -d "$VERSION" >/dev/null 2>&1 || true
fi
git tag -a "$VERSION" -m "IMBluetoothKit $VERSION"
echo "Review, then: git push origin HEAD && git push origin $VERSION  # $GITHUB_REPO"
