#!/usr/bin/env bash
#
# convert-to-vorbis.sh
# Converts .mp3, .m4a, .flac files to .ogg (Vorbis) while preserving
# metadata AND album art (even from MP3 ID3 APIC tags).
# Existing .ogg files are re-encoded to the target bitrate.
#
# Usage:  ./convert-to-vorbis.sh /path/to/music [bitrate]
#         bitrate is optional, default 192k (good quality for Vorbis)
#
# Requirements: ffmpeg (with libvorbis), python3, find, coreutils
#
# ── Why album art is tricky ──────────────────────────────────────────
#
# MP3 stores cover art as an ID3 APIC frame that ffmpeg exposes as a
# "video" stream.  M4A stores it in a 'covr' atom, also shown as a
# video stream.  FLAC uses METADATA_BLOCK_PICTURE natively.
#
# Vorbis-in-OGG does NOT support video streams — it uses a Vorbis
# comment called METADATA_BLOCK_PICTURE (inherited from the FLAC
# spec).  ffmpeg's OGG/Vorbis muxer does NOT write that comment
# automatically, so a naive conversion silently drops the art.
#
# This script fixes the problem:
#   1. Extract the embedded cover image to a temp file.
#   2. Build the METADATA_BLOCK_PICTURE binary block (picture type,
#      MIME, description, dimensions, pixel data) and base64-encode it.
#   3. Pass the result as a Vorbis metadata tag during the encode.
#
# The same pipeline handles every source format uniformly.

set -euo pipefail

# ── Colours / helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${RESET}  %s\n" "$*"; }

# ── Argument handling ────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo -e "${BOLD}Usage:${RESET}  $0 <music-folder> [bitrate]"
    echo "  music-folder  Root folder containing your music library"
    echo "  bitrate       Vorbis bitrate (default: 192k). Good values: 128k–320k"
    exit 1
fi

INPUT_DIR="$(realpath "$1")"
BITRATE="${2:-192k}"
OUTPUT_DIR="${INPUT_DIR}/OUTPUT"

if [[ ! -d "$INPUT_DIR" ]]; then
    fail "Directory does not exist: $INPUT_DIR"
    exit 1
fi

# ── Dependency checks ───────────────────────────────────────────────
missing=()
command -v ffmpeg   &>/dev/null || missing+=("ffmpeg")
command -v ffprobe  &>/dev/null || missing+=("ffprobe (part of ffmpeg)")
command -v python3  &>/dev/null || missing+=("python3")

if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required tools: ${missing[*]}"
    echo "  Ubuntu/Debian:  sudo apt install ffmpeg python3"
    echo "  macOS:          brew install ffmpeg python3"
    exit 1
fi

# ── Temp directory (cleaned up on exit) ──────────────────────────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ─────────────────────────────────────────────────────────────────────
# Python helper: build a METADATA_BLOCK_PICTURE base64 string
#
# The OGG/Vorbis container embeds cover art as a Vorbis comment whose
# value is a base64-encoded binary block defined by the FLAC spec:
#
#   [4 B]  picture type   (3 = front cover)
#   [4 B]  MIME length  →  [N B]  MIME string
#   [4 B]  desc length  →  [N B]  description
#   [4 B]  width   (0 = let the player figure it out)
#   [4 B]  height  (0 = same)
#   [4 B]  colour depth (0)
#   [4 B]  colours used (0)
#   [4 B]  data length  →  [N B]  raw image bytes
# ─────────────────────────────────────────────────────────────────────
build_picture_block() {
    local image_path="$1"
    python3 - "$image_path" <<'PYEOF'
import sys, struct, base64

path = sys.argv[1]
with open(path, "rb") as f:
    img_data = f.read()

# Detect MIME from magic bytes
if img_data[:8] == b'\x89PNG\r\n\x1a\n':
    mime = b"image/png"
elif img_data[:2] == b'\xff\xd8':
    mime = b"image/jpeg"
elif img_data[:4] == b'RIFF' and img_data[8:12] == b'WEBP':
    mime = b"image/webp"
elif img_data[:3] == b'GIF':
    mime = b"image/gif"
else:
    mime = b"image/jpeg"

desc = b""

block  = struct.pack(">I", 3)                # front cover
block += struct.pack(">I", len(mime)) + mime  # MIME
block += struct.pack(">I", len(desc)) + desc  # description
block += struct.pack(">I", 0)                 # width
block += struct.pack(">I", 0)                 # height
block += struct.pack(">I", 0)                 # colour depth
block += struct.pack(">I", 0)                 # colours used
block += struct.pack(">I", len(img_data))     # data length
block += img_data                             # pixel data

sys.stdout.write(base64.b64encode(block).decode("ascii"))
PYEOF
}

# ─────────────────────────────────────────────────────────────────────
# Extract the first image/video stream (= cover art) from a file.
# Prints the path to the extracted image on success, returns 1 if
# the source has no embedded art.
# ─────────────────────────────────────────────────────────────────────
extract_cover() {
    local src="$1"
    local tag="cover_${RANDOM}_${RANDOM}"
    local out_img="${TMPDIR}/${tag}"

    # Ask ffprobe whether there is a video/image stream at all
    local codec
    codec=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name \
            -of csv=p=0 "$src" 2>/dev/null | head -1)

    [[ -z "$codec" ]] && return 1

    # Pick an output extension that matches the embedded codec so
    # ffmpeg can do a simple stream-copy (fast, lossless).
    local ext="jpg"
    case "$codec" in
        png)  ext="png"  ;;
        bmp)  ext="bmp"  ;;
        webp) ext="webp" ;;
        gif)  ext="gif"  ;;
        # mjpeg / jpeg → jpg (default)
    esac

    # Try codec-copy first (fastest, preserves quality perfectly)
    if ffmpeg -nostdin -hide_banner -loglevel error \
        -i "$src" -an -vcodec copy -frames:v 1 \
        "${out_img}.${ext}" 2>/dev/null && [[ -s "${out_img}.${ext}" ]]; then
        echo "${out_img}.${ext}"
        return 0
    fi

    # Fallback: re-encode to JPEG (handles exotic embedded codecs)
    rm -f "${out_img}.${ext}"
    if ffmpeg -nostdin -hide_banner -loglevel error \
        -i "$src" -an -vframes 1 -q:v 2 \
        "${out_img}.jpg" 2>/dev/null && [[ -s "${out_img}.jpg" ]]; then
        echo "${out_img}.jpg"
        return 0
    fi

    rm -f "${out_img}.jpg"
    return 1
}

# ─────────────────────────────────────────────────────────────────────
# Convert a single file to Vorbis with metadata + album art
# ─────────────────────────────────────────────────────────────────────
convert_file() {
    local src="$1"
    local dst="$2"
    local had_art="no"

    # ── Step 1: Try to extract cover art ─────────────────────────────
    local cover_path=""
    local b64=""

    if cover_path="$(extract_cover "$src")"; then
        # ── Step 2: Build the METADATA_BLOCK_PICTURE blob ────────────
        b64="$(build_picture_block "$cover_path")"
        rm -f "$cover_path"
    fi

    # ── Step 3: Encode audio ─────────────────────────────────────────
    # We write metadata via an ffmetadata file so we don't hit
    # argument-length limits with huge base64 cover-art blobs.

    local metafile="${TMPDIR}/meta_${RANDOM}.ini"

    # Start with a header then dump all existing tags
    echo ";FFMETADATA1" > "$metafile"

    # Grab existing tags from the source and write them out.
    # ffprobe prints TAG:key=value lines; we convert to ffmetadata format.
    ffprobe -v error -show_entries format_tags \
        -of default=nw=1 "$src" 2>/dev/null \
        | sed -n 's/^TAG:\(.*\)/\1/p' \
        | grep -vi "^METADATA_BLOCK_PICTURE" \
        >> "$metafile" || true

    # Append cover art tag if we have one
    if [[ -n "$b64" ]]; then
        echo "METADATA_BLOCK_PICTURE=${b64}" >> "$metafile"
        had_art="yes"
    fi

    ffmpeg -nostdin -hide_banner -loglevel warning \
        -i "$src" \
        -i "$metafile" \
        -map 0:a -map_metadata 1 \
        -c:a libvorbis -b:a "$BITRATE" \
        "$dst"

    rm -f "$metafile"

    # Return art status via stdout
    echo "$had_art"
}

# ── Collect files ────────────────────────────────────────────────────
EXTENSIONS=( "mp3" "ogg" "m4a" "flac" )

FIND_ARGS=( -not -path "${OUTPUT_DIR}/*" \( )
for i in "${!EXTENSIONS[@]}"; do
    [[ $i -gt 0 ]] && FIND_ARGS+=( -o )
    FIND_ARGS+=( -iname "*.${EXTENSIONS[$i]}" )
done
FIND_ARGS+=( \) )

mapfile -t FILES < <(find "$INPUT_DIR" "${FIND_ARGS[@]}" -type f | sort)

TOTAL=${#FILES[@]}
if [[ $TOTAL -eq 0 ]]; then
    warn "No music files (.mp3, .ogg, .m4a, .flac) found in: $INPUT_DIR"
    exit 0
fi

info "Found ${BOLD}${TOTAL}${RESET} music file(s) in: $INPUT_DIR"
info "Output directory: $OUTPUT_DIR"
info "Vorbis bitrate: $BITRATE"
echo ""

# ── Counters ─────────────────────────────────────────────────────────
converted=0
skipped=0
failed=0
art_kept=0
art_none=0

# ── Main loop ────────────────────────────────────────────────────────
for filepath in "${FILES[@]}"; do
    relative="${filepath#"$INPUT_DIR"/}"
    out_path="${OUTPUT_DIR}/${relative%.*}.ogg"
    out_dir="$(dirname "$out_path")"

    current=$(( converted + skipped + failed + 1 ))
    printf "${BOLD}[%d/%d]${RESET} %s " "$current" "$TOTAL" "$relative"

    # Skip if already converted
    if [[ -f "$out_path" ]]; then
        printf "→ ${YELLOW}skipped (exists)${RESET}\n"
        (( skipped++ )) || true
        continue
    fi

    mkdir -p "$out_dir"

    art_status=""
    if art_status="$(convert_file "$filepath" "$out_path" 2>&1 | tail -1)" \
       && [[ -f "$out_path" && -s "$out_path" ]]; then

        if [[ "$art_status" == "yes" ]]; then
            printf "→ ${GREEN}done (with cover art)${RESET}\n"
            (( art_kept++ )) || true
        else
            printf "→ ${GREEN}done${RESET}\n"
            (( art_none++ )) || true
        fi
        (( converted++ )) || true
    else
        rm -f "$out_path"
        printf "→ ${RED}FAILED${RESET}\n"
        (( failed++ )) || true
    fi
done

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
echo -e "${BOLD} Conversion complete${RESET}"
echo -e "${BOLD}═══════════════════════════════════════${RESET}"
echo -e "  ${GREEN}Converted:${RESET}    $converted"
echo -e "    with art:   $art_kept"
echo -e "    without:    $art_none"
echo -e "  ${YELLOW}Skipped:${RESET}      $skipped"
echo -e "  ${RED}Failed:${RESET}       $failed"
echo -e "  ${CYAN}Total:${RESET}        $TOTAL"
echo ""
echo -e "  Output:  ${BOLD}${OUTPUT_DIR}${RESET}"

# ── Size comparison ──────────────────────────────────────────────────
if [[ $converted -gt 0 ]] && command -v du &>/dev/null; then
    orig_size=$(find "$INPUT_DIR" -not -path "${OUTPUT_DIR}/*" \
        \( -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.m4a' -o -iname '*.flac' \) \
        -type f -exec du -cb {} + | tail -1 | cut -f1)
    vorbis_size=$(find "$OUTPUT_DIR" -iname '*.ogg' -type f \
        -exec du -cb {} + 2>/dev/null | tail -1 | cut -f1)
    if [[ -n "${vorbis_size:-}" && "${orig_size:-0}" -gt 0 ]]; then
        ratio=$(awk "BEGIN { printf \"%.1f\", ($vorbis_size / $orig_size) * 100 }")
        orig_h=$(numfmt --to=iec-i --suffix=B "$orig_size" 2>/dev/null || echo "${orig_size} bytes")
        vorb_h=$(numfmt --to=iec-i --suffix=B "$vorbis_size" 2>/dev/null || echo "${vorbis_size} bytes")
        echo ""
        echo -e "  ${BOLD}Size comparison:${RESET}"
        echo -e "    Originals:    $orig_h"
        echo -e "    Vorbis files: $vorb_h  (${ratio}% of original)"
    fi
fi
