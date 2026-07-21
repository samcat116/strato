#!/bin/bash
# Installs the cvc5 SMT solver the control plane's write-time guardrail check
# drives (IAM phase 7, issue #484).
#
# Only that check needs it: nothing links against cvc5, it is spawned as a
# subprocess, and it is never on the request path. It is a hard dependency of
# *binding writes* though — with no solver those return 503 rather than being
# accepted unchecked (docs/architecture/iam.md).
#
# Pinned to 1.3.1, the version cedar-policy-symcc is developed against, and to
# the permissively licensed `-static` builds rather than the `-static-gpl`
# ones. Checksums are verified: this binary decides whether policy writes are
# accepted, so an unverified download would be a poor thing to trust.
#
# Usage: scripts/install-cvc5.sh [install-dir]   (default /usr/local/bin)
set -euo pipefail

VERSION=1.3.1
INSTALL_DIR="${1:-/usr/local/bin}"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)   ASSET=cvc5-macOS-arm64-static  SHA=a0e7f5b03b1bc4284fbfff7cdfb08c704801701cf7ece83a13f8a505e7581215 ;;
  Darwin-x86_64)  ASSET=cvc5-macOS-x86_64-static SHA=e7fe4af9491bd7c0db7591c0a483775735bd1a98b23933fd337a73ae39c10ff9 ;;
  Linux-aarch64|Linux-arm64)
                  ASSET=cvc5-Linux-arm64-static  SHA=fe2b661834a82fd8830f7a757c340f0e20041fa41e19b038fa02ace0eaf1c6f2 ;;
  Linux-x86_64)   ASSET=cvc5-Linux-x86_64-static SHA=1a1cda20d2df4938fa4944a69f33ddc9172e319ece0eed0aa09c4d7abede3ed1 ;;
  *) echo "error: no cvc5 $VERSION build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

URL="https://github.com/cvc5/cvc5/releases/download/cvc5-$VERSION/$ASSET.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> downloading $ASSET"
curl -fsSL "$URL" -o "$WORK/cvc5.zip"

echo "$SHA  $WORK/cvc5.zip" | (sha256sum -c - 2>/dev/null || shasum -a 256 -c -)

unzip -q "$WORK/cvc5.zip" -d "$WORK"
install -m 0755 "$WORK/$ASSET/bin/cvc5" "$INSTALL_DIR/cvc5"

echo "==> installed $("$INSTALL_DIR/cvc5" --version | head -1) to $INSTALL_DIR/cvc5"
