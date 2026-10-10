#!/usr/bin/env bash
#
# publish_to_github.sh — sync binary release whitelist to a public GitHub checkout.
#
# Env (optional — defaults below):
#   GITHUB_REPO       default: INMO-X/BluetoothKit
#   PUBLIC_CHECKOUT   local clone of https://github.com/INMO-X/BluetoothKit.git
#                     default: first existing among:
#                       ../BluetoothKit
#
# Customer Podfile fail-safe (document in README; CocoaPods cannot enforce):
#   Binary customers must use Full OR exactly one Devices/<X> (e.g. Devices/C100).
#   Never `pod '…/Devices'` alone (pulls all nested XCFrameworks) and never two
#   Devices/* lines — same Swift module BluetoothKit → duplicate symbols.
#
# Public repo is binary-only for BluetoothKit; Example demo sources live under Example/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo $ROOT
GITHUB_REPO="${GITHUB_REPO:-INMO-X/BluetoothKit}"

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
: "${PUBLIC_CHECKOUT:?Set PUBLIC_CHECKOUT=/path/to/clone of https://github.com/INMO-X/BluetoothKit.git}"
echo "GITHUB_REPO=$GITHUB_REPO"
echo "PUBLIC_CHECKOUT=$PUBLIC_CHECKOUT"

VERSION="$(ruby -e "require 'cocoapods'; puts Pod::Specification.from_file('$ROOT/BluetoothKit.podspec').version")"

rsync -a --delete "$ROOT/XCFrameworks/" "$PUBLIC_CHECKOUT/XCFrameworks/"

# Refuse library .swift sources (binary-only); Example demo Swift is allowed.
leaked="$(find "$PUBLIC_CHECKOUT" -name '*.swift' ! -path '*/Example/*' 2>/dev/null || true)"
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
git tag -a "$VERSION" -m "BluetoothKit $VERSION"
echo "Review, then: git push origin HEAD && git push origin $VERSION  # $GITHUB_REPO"
