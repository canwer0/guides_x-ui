#!/usr/bin/env bash
set -Eeuo pipefail

# Fetch the installer and its artwork from a public GitHub folder, then run it.
# Usage: bootstrap-stream-one-v12.sh [owner/repo] [branch] [folder]
OWNER_REPO="${1:-canwer0/guides_x-ui}"
REF="${2:-main}"
FOLDER="${3:-xhttp/stream-one-tls-reality}"

[[ "$OWNER_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid owner/repo" >&2; exit 2; }
[[ "$REF" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Use a simple branch or tag name" >&2; exit 2; }
[[ "$FOLDER" =~ ^[A-Za-z0-9_./-]+$ && "$FOLDER" != *..* ]] || { echo "Invalid repository folder" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run via sudo bash" >&2; exit 1; }

WORK="$(mktemp -d -t stream-one-v12.XXXXXX)"
cleanup(){ rm -rf -- "$WORK"; }
trap cleanup EXIT
BASE="https://raw.githubusercontent.com/$OWNER_REPO/$REF/$FOLDER"
mkdir -m 700 "$WORK/assets"
INSTALLER="install-xhttp-stream-one-vlessenc-nginx-v12.sh"
if ! curl -fsSL --retry 3 --connect-timeout 20 "$BASE/$INSTALLER" -o "$WORK/$INSTALLER"; then
  # Accept the short filename currently used in the GitHub folder screenshot.
  # The downloaded bytes are still checked against SHA256SUMS before execution.
  for candidate in install-xhttp-stream-one-vlesenc-nginx.sh install-xhttp-stream-one-vlessenc-nginx.sh; do
    if curl -fsSL --retry 3 --connect-timeout 20 "$BASE/$candidate" -o "$WORK/$INSTALLER"; then break; fi
  done
  [[ -s "$WORK/$INSTALLER" ]] || { echo "Installer file was not found in $OWNER_REPO/$FOLDER" >&2; exit 1; }
fi
for image in poster-orbit.webp poster-noir.webp poster-summit.webp poster-afterglow.webp; do
  curl -fsSL --retry 3 --connect-timeout 20 "$BASE/assets/$image" -o "$WORK/assets/$image"
done
curl -fsSL --retry 3 --connect-timeout 20 "$BASE/SHA256SUMS" -o "$WORK/SHA256SUMS"
(cd "$WORK" && sha256sum --check --status SHA256SUMS) || { echo "Downloaded files failed SHA-256 verification" >&2; exit 1; }
bash -n "$WORK/$INSTALLER"
bash "$WORK/$INSTALLER"
