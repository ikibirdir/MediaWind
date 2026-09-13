#!/bin/bash
# Generates test media for MediaWind. Only writes inside the output folder.
#
#   scripts/make-testdata.sh [folder]          ~300 photos in several formats and sizes, an animated
#                                              GIF, EXIF-rotated photos, videos, junk files.
#                                              Default folder: ./TestMedia
#   scripts/make-testdata.sh --large [folder]  5,000 photos (APFS clones) for speed testing.
#                                              Default folder: ./TestMedia-Large
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--large" ]; then
    OUT="${2:-$ROOT/TestMedia-Large}"
    echo "==> Generating 5,000 photos in $OUT"
    swift "$ROOT/scripts/MakeTestData.swift" --large "$OUT" 5000
    exit 0
fi

OUT="${1:-$ROOT/TestMedia}"
mkdir -p "$OUT"
echo "==> Generating photos in $OUT"
swift "$ROOT/scripts/MakeTestData.swift" "$OUT" 300

if command -v ffmpeg >/dev/null; then
    echo "==> Generating videos with ffmpeg"
    ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
    SRC=(-f lavfi -i "testsrc2=size=1280x720:rate=30:duration=4" -f lavfi -i "sine=frequency=440:duration=4")
    ff "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/IMG_5_h264.mp4"
    ff "${SRC[@]}" -c:v hevc_videotoolbox -tag:v hvc1 -b:v 4M -c:a aac -shortest "$OUT/IMG_6_hevc.mov" \
        || ff "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/IMG_6_hevc.mov"
    ff "${SRC[@]}" -c:v libvpx-vp9 -b:v 1M -an "$OUT/IMG_100_vp9.webm"
    ff "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/IMG_101_h264.mkv"
    ff "${SRC[@]}" -c:v mpeg4 -q:v 5 -an "$OUT/IMG_102_mpeg4.avi"
else
    echo "==> ffmpeg not found: skipping videos (brew install ffmpeg)"
fi

echo "==> Adding junk that must be skipped"
# AppleDouble file as left behind on exFAT/FAT drives.
{ printf '\x00\x05\x16\x07\x00\x02\x00\x00'; head -c 4088 /dev/zero; } > "$OUT/._IMG_10.png"
cp "$OUT/IMG_10.png" "$OUT/.hidden.png"
echo "not an image" > "$OUT/notes.txt"
mkdir -p "$OUT/Subfolder"
cp "$OUT/IMG_12.png" "$OUT/Subfolder/IMG_999.png" 2>/dev/null || cp "$OUT/IMG_10.png" "$OUT/Subfolder/IMG_999.png"

echo "==> Done: $(ls "$OUT" | wc -l | tr -d ' ') entries in $OUT"
