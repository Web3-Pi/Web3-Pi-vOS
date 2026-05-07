#!/usr/bin/env bash
#
# compress.sh — pack the built Web3 Pi vOS .img into a release-named
# .img.xz with maximum compression and a sidecar SHA-256 checksum file.
#
# Output (in output/images/):
#   Web3Pi-SoloStakingOS.img.xz
#   Web3Pi-SoloStakingOS.img.xz.sha256
#
# Usage:
#   ./compress.sh                       # auto-pick newest .img in output/images/
#   ./compress.sh path/to/file.img      # compress a specific image

set -euo pipefail

IMAGES_DIR="output/images"
RELEASE_NAME="Web3Pi-SoloStakingOS"

if [[ $# -ge 1 ]]; then
    IMG="$1"
else
    IMG=$(ls -1t "$IMAGES_DIR"/Armbian-unofficial_*_Rpi4b-w3p_*.img 2>/dev/null | head -n1 || true)
fi

if [[ -z "${IMG:-}" || ! -f "$IMG" ]]; then
    echo "error: no .img found (looked in $IMAGES_DIR/Armbian-unofficial_*_Rpi4b-w3p_*.img)" >&2
    echo "usage: $0 [path/to/file.img]" >&2
    exit 1
fi

OUT_DIR=$(dirname "$IMG")
OUT_XZ="${OUT_DIR}/${RELEASE_NAME}.img.xz"
OUT_SHA="${OUT_XZ}.sha256"

echo "Source:  $IMG"
echo "Output:  $OUT_XZ"
echo "Flags:   -9 -e -T 0 (max preset, extreme, all cores)"
echo

# -9    highest standard compression preset
# -e    extreme mode (~1-3 % smaller output, more CPU)
# -T 0  use all available CPU cores
# -v    verbose progress
# -c    write to stdout (so we can redirect to a renamed file
#       without touching the original .img)
xz -9 -e -T 0 -v -c "$IMG" > "$OUT_XZ"

echo
echo "Generating SHA-256 ..."
( cd "$OUT_DIR" && shasum -a 256 "${RELEASE_NAME}.img.xz" > "${RELEASE_NAME}.img.xz.sha256" )

echo
echo "Done."
ls -lh "$OUT_XZ" "$OUT_SHA"
echo
cat "$OUT_SHA"
