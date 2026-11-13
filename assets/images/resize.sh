#!/usr/bin/env bash
# Resize a generated image to an exact target size.
#
# Image generators (gpt-image-2.5 included) return their own fixed sizes, not the
# size the prompt asked for, so every delivered image goes through this script.
# The output always has exactly the target dimensions. How it gets there:
#
#   fill  Scale to cover the target, then centre-crop the overflow. Used when the
#         source and target aspect ratios are close (crop loses <= 20% of a side, 10% per edge),
#         which the prompts' safe margins are designed to absorb.
#   pad   Scale to fit inside the target, then letterbox with a background colour.
#         Used when the ratios differ so much that a crop would cut into the content.
#         The colour defaults to the source's top-left pixel, so the padding blends
#         with the image's own background; override with --bg.
#
# The strategy is chosen automatically unless forced with --fill or --pad.
# Transparent inputs are flattened onto the dark theme colour #0D1117 (or --bg).
#
# --compress reduces a PNG output to a 256-colour palette (no dithering), which
# usually cuts flat diagrams to a third of their size with no visible change. It
# can band smooth gradients and photos, so check the result. Without it, a PNG
# output over 1 MB prints a hint.
#
# Usage:
#   assets/images/resize.sh <preset|WxH> <input> <output> [--fill|--pad] [--bg COLOR] [--compress]
#
# Presets:
#   cover    1920x1080  LinkedIn article cover (LinkedIn crops uploads to 16:9)
#   arch     1600x1000  README architecture diagram (2x asset, displays ~830 px wide)
#   section  900x300    LinkedIn article body image
#
# Examples:
#   assets/images/resize.sh cover  ~/Downloads/generated.png assets/images/cover.png
#   assets/images/resize.sh arch   ~/Downloads/generated.png assets/images/arch.png --compress
#   assets/images/resize.sh 1200x627 in.png out.png --pad --bg '#0A0F1E'
#
# Requires ImageMagick 6 (convert, identify).

set -euo pipefail

usage() { sed -n '2,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[[ $# -ge 3 ]] || usage
TARGET="$1"; INPUT="$2"; OUTPUT="$3"; shift 3

STRATEGY=auto
BG=""
COMPRESS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fill) STRATEGY=fill ;;
    --pad)  STRATEGY=pad ;;
    --bg)   BG="${2:?--bg needs a colour}"; shift ;;
    --compress) COMPRESS=true ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
  shift
done

case "$TARGET" in
  cover)   W=1920; H=1080 ;;
  arch)    W=1600; H=1000 ;;
  section) W=900;  H=300 ;;
  *[0-9]x[0-9]*) W="${TARGET%x*}"; H="${TARGET#*x}" ;;
  *) echo "Unknown preset or size: $TARGET" >&2; usage ;;
esac

[[ -f "$INPUT" ]] || { echo "Input not found: $INPUT" >&2; exit 1; }
read -r SW SH < <(identify -format '%w %h\n' "$INPUT[0]")

MAX_CROP=0.20   # largest fraction of a side that fill may crop (10% per edge) before falling back to pad
if [[ "$STRATEGY" == auto ]]; then
  STRATEGY=$(awk -v sw="$SW" -v sh="$SH" -v w="$W" -v h="$H" -v max="$MAX_CROP" 'BEGIN {
    r = (sw / sh) / (w / h); if (r < 1) r = 1 / r;   # ratio between the two aspect ratios
    print (1 - 1 / r) <= max ? "fill" : "pad" }')
fi

# Generators sometimes deliver a transparent background. Flatten it onto the dark
# theme colour (or --bg) so the output is opaque and does not turn white on export.
HAS_ALPHA=$(identify -format '%A' "$INPUT[0]")
if [[ "$HAS_ALPHA" == True || "$HAS_ALPHA" == Blend ]]; then
  [[ -n "$BG" ]] || BG='#0D1117'
  echo "note: input has transparency; flattening onto $BG"
elif [[ "$STRATEGY" == pad && -z "$BG" ]]; then
  BG=$(convert "$INPUT[0]" -format '%[pixel:p{0,0}]' info:)
fi
FLATTEN=(-background "${BG:-black}" -alpha remove -alpha off)

SCALE=$(awk -v sw="$SW" -v sh="$SH" -v w="$W" -v h="$H" -v s="$STRATEGY" 'BEGIN {
  a = w / sw; b = h / sh; print (s == "fill") ? (a > b ? a : b) : (a < b ? a : b) }')

case "$STRATEGY" in
  fill) convert "$INPUT[0]" "${FLATTEN[@]}" -filter Lanczos -resize "${W}x${H}^" -gravity center -extent "${W}x${H}" -strip "$OUTPUT" ;;
  pad)  convert "$INPUT[0]" "${FLATTEN[@]}" -filter Lanczos -resize "${W}x${H}"  -background "$BG" -gravity center -extent "${W}x${H}" -strip "$OUTPUT" ;;
esac

IS_PNG=$([[ "$(identify -format '%m' "$OUTPUT")" == PNG ]] && echo true || echo false)
if [[ "$COMPRESS" == true ]]; then
  if [[ "$IS_PNG" == true ]]; then
    BEFORE=$(identify -format '%b' "$OUTPUT")
    convert "$OUTPUT" -dither None -colors 256 -define png:compression-level=9 -strip "PNG8:$OUTPUT"
    echo "compress: 256-colour palette, $BEFORE -> $(identify -format '%b' "$OUTPUT")"
  else
    echo "note: --compress only applies to PNG output; skipped"
  fi
fi

printf 'input:    %s  %sx%s\n' "$INPUT" "$SW" "$SH"
printf 'output:   %s  %s\n' "$OUTPUT" "$(identify -format '%wx%h %m %b' "$OUTPUT")"
printf 'strategy: %s (scale %.2fx' "$STRATEGY" "$SCALE"
[[ "$STRATEGY" == pad ]] && printf ', background %s' "$BG"
printf ')\n'
awk -v s="$SCALE" 'BEGIN { if (s > 1.5) print "warning: upscaled more than 1.5x; expect softness. Ask the generator for a larger image if it offers one." }'
if [[ "$COMPRESS" == false && "$IS_PNG" == true && $(stat -c %s "$OUTPUT") -gt 1048576 ]]; then
  echo "hint: output is over 1 MB; rerun with --compress for a smaller PNG"
fi
