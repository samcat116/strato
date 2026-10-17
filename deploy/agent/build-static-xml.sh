#!/usr/bin/env bash
# FoundationXML in the Noble Swift SDK expects libxml2's v2 ABI. Ubuntu 26.04
# ships v16, so link the security-patched Noble library into the agent. Disable
# its optional ICU backend: Swift already embeds its own ICU C++ implementation.
# Source and patches come only from Ubuntu's signed Noble source indexes.
set -euo pipefail
output="${1:?usage: build-static-xml.sh <output-dir>}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
version=$(dpkg-query -W -f='${source:Version}' libxml2-dev)
cache_key="$version $(sha256sum "$0" | cut -d' ' -f1)"
if [ -f "$output/libxml2.a" ] && [ -f "$output/libxml2.so" ] && [ "$(cat "$output/cache-key" 2>/dev/null)" = "$cache_key" ]; then
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(dpkg --print-architecture)" in
  amd64) archive=https://archive.ubuntu.com/ubuntu; security=https://security.ubuntu.com/ubuntu ;;
  arm64) archive=https://ports.ubuntu.com/ubuntu-ports; security=$archive ;;
  *) echo 'unsupported build architecture' >&2; exit 1 ;;
esac
cat > "$work/sources.list" <<EOF
deb-src [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $archive noble main
deb-src [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $archive noble-updates main
deb-src [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $security noble-security main
EOF
mkdir -p "$work/lists/partial" "$work/cache/archives/partial" "$work/source"
apt_options=(-o "Dir::Etc::sourcelist=$work/sources.list" -o Dir::Etc::sourceparts=-
             -o "Dir::State::lists=$work/lists" -o "Dir::Cache=$work/cache")
apt-get "${apt_options[@]}" update
cd "$work/source"
apt-get "${apt_options[@]}" source "libxml2=$version"
mapfile -t sources < <(find "$work/source" -mindepth 1 -maxdepth 1 -type d -name 'libxml2-*')
[ "${#sources[@]}" -eq 1 ] || { echo 'ambiguous XML source directory' >&2; exit 1; }
cd "${sources[0]}"
./configure --disable-shared --enable-static --without-python --without-icu
make -j 4 libxml2.la
cp .libs/libxml2.a "$output/"
# Resolve XML's private compression dependencies after its archive is scanned,
# rather than losing them to the Swift driver's earlier --as-needed arguments.
multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
printf 'GROUP ( "%s" AS_NEEDED ( "/lib/%s/liblzma.so.5" "/lib/%s/libz.so.1" "/lib/%s/libm.so.6" ) )\n' \
  "$output/libxml2.a" "$multiarch" "$multiarch" "$multiarch" > "$output/libxml2.so"
printf '%s\n' "$version" > "$output/source-version"
printf '%s\n' "$cache_key" > "$output/cache-key"
printf 'Static XML source: Ubuntu Noble libxml2 %s, ICU disabled\n' "$version"
