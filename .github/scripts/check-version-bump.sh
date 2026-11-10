#!/bin/bash
# Usage: check-version-bump.sh <base-sha> <head-sha>
# Fails when the diff changes shipped files but Info.plist's version is not raised above base.
# Set SKIP=true to pass anyway (the PR workflow sets it from the `no-version-bump` label).
set -euo pipefail

BASE="$1"
HEAD="$2"

# Files that end up in the app, the CLI, the release zip, or what install.sh installs.
SHIPPED='^(Sources/|Package\.swift$|Package\.resolved$|Info\.plist$|scripts/|skills/|build-app\.sh$|package-release\.sh$)'

plist_value() { # <rev> <key>
    git show "$1:Info.plist" | awk -v key="$2" '
        $0 ~ "<key>" key "</key>" { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }'
}

changed=$(git diff --name-only "$BASE" "$HEAD" | grep -E "$SHIPPED" || true)
if [ -z "$changed" ]; then
    echo "No shipped files changed; no version bump needed."
    exit 0
fi

echo "Shipped files changed:"
echo "$changed" | sed 's/^/  /'

if [ "${SKIP:-false}" = "true" ]; then
    echo "Label no-version-bump is set; skipping the version check."
    exit 0
fi

old=$(plist_value "$BASE" CFBundleShortVersionString)
new=$(plist_value "$HEAD" CFBundleShortVersionString)
build=$(plist_value "$HEAD" CFBundleVersion)
echo "Version on main: ${old}   Version in this PR: ${new} (build ${build})"

if [ "$new" = "$old" ] || [ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -1)" != "$new" ]; then
    echo "::error file=Info.plist::This PR changes what ships but CFBundleShortVersionString is ${new}, not above main's ${old}. Raise it (and CFBundleVersion) in Info.plist, or add the no-version-bump label if users get nothing new."
    exit 1
fi

if [ "$build" != "$new" ]; then
    echo "::error file=Info.plist::CFBundleVersion is ${build} but CFBundleShortVersionString is ${new}. Keep them the same."
    exit 1
fi

echo "Version raised from ${old} to ${new}."
