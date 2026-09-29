#!/usr/bin/env bash
# Used by macOS resolution and release jobs to select the pinned compiler.
set -euo pipefail

version=6.4.0
pkg="${RUNNER_TEMP:?}/swift-$version-osx.pkg"
curl -fsSL "https://download.swift.org/swift-$version-release/xcode/swift-$version-RELEASE/swift-$version-RELEASE-osx.pkg" -o "$pkg"
sudo installer -pkg "$pkg" -target /
toolchain="/Library/Developer/Toolchains/swift-$version-RELEASE.xctoolchain"
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$toolchain/Info.plist")
echo "TOOLCHAINS=$identifier" >> "${GITHUB_ENV:?}"
