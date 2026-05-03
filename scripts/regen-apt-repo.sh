#!/bin/bash
# WatchPair11 — Regenerate APT repo metadata in docs/ for GitHub Pages
# Usage: bash scripts/regen-apt-repo.sh
# Run from repo root. Requires: dpkg-scanpackages, gzip, bzip2, sha256sum.

set -e
cd "$(dirname "$0")/.."

DOCS=docs
DEBS=$DOCS/debs

[ -d "$DEBS" ] || { echo "ERR: $DEBS not found"; exit 1; }
ls "$DEBS"/*.deb >/dev/null 2>&1 || { echo "ERR: no .deb in $DEBS"; exit 1; }

echo "==> Generating Packages from $DEBS/*.deb"
( cd "$DOCS" && dpkg-scanpackages -m debs > Packages )

echo "==> Compressing"
( cd "$DOCS" && gzip -k -9 -f Packages && bzip2 -k -9 -f Packages )

echo "==> Generating Release with Date + hashes"
{
  cat <<EOF
Origin: WatchPair11
Label: WatchPair11
Suite: stable
Version: 1.0
Codename: WatchPair11
Architectures: iphoneos-arm64
Components: main
Description: Tweak iOS 16.6 + watchOS 11.5 pairing with native Apple Pay support
Date: $(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S UTC")
EOF
  for algo in MD5Sum:md5sum SHA1:sha1sum SHA256:sha256sum; do
    label=${algo%:*}
    cmd=${algo#*:}
    echo "$label:"
    for f in Packages Packages.gz Packages.bz2; do
      [ -f "$DOCS/$f" ] && printf " %s %16d %s\n" "$($cmd "$DOCS/$f" | awk '{print $1}')" "$(stat -c%s "$DOCS/$f")" "$f"
    done
  done
} > "$DOCS/Release"

# GPG sign if a key matches the repo identity
GPG_KEY=${GPG_KEY:-A1F177E549CE2DD1}
if gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1; then
  echo "==> Signing Release with GPG key $GPG_KEY"
  gpg --default-key "$GPG_KEY" --clearsign --yes --output "$DOCS/InRelease" "$DOCS/Release"
  gpg --default-key "$GPG_KEY" -abs --yes --output "$DOCS/Release.gpg" "$DOCS/Release"
  gpg --armor --export "$GPG_KEY" > "$DOCS/wp11-archive-keyring.asc"
  gpg --export "$GPG_KEY" > "$DOCS/wp11-archive-keyring.gpg"
else
  echo "==> WARNING: GPG key $GPG_KEY not found, skipping signing"
  echo "    Users will need 'Trusted: yes' in their .sources file"
fi

echo "==> Done. Files in $DOCS/:"
ls -la "$DOCS"/Packages* "$DOCS"/Release* "$DOCS"/InRelease "$DOCS"/wp11-archive-keyring.* 2>/dev/null
echo ""
echo "Next: git add $DOCS && git commit && git push"
