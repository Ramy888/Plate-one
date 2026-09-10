#!/usr/bin/env bash
# Renders the app icon set and the store feature graphic, then regenerates every
# Android and iOS launcher size.
#
#   ./tool/render_icon.sh
#
# The mark is the one drawn in the Claude Design project the store assets came
# from, kept here as SVG with the design system's tokens resolved to hex — so
# the app icon and the listing artwork cannot drift apart. Edit tool/icon/,
# never assets/icon/, which this script overwrites.
#
# Chrome is the renderer because it is the only one on this machine that reads
# SVG and web fonts the same way the design project does.
set -euo pipefail

cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME (override with CHROME=...)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MARK="$(cat tool/icon/_mark.svg)"

# $1 = width, $2 = height, $3 = svg-or-html body, $4 = output name
render() {
  local w=$1 h=$2 body=$3 out=$4
  cat > "$WORK/$out.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>
@font-face{font-family:Caprasimo;src:url('$PWD/assets/fonts/Caprasimo-Regular.ttf')}
@font-face{font-family:Figtree;font-weight:400;src:url('$PWD/assets/fonts/Figtree-Regular.ttf')}
html,body{margin:0;padding:0;width:${w}px;height:${h}px;background:transparent}
svg{display:block;width:${w}px;height:${h}px}
</style>
$body
HTML
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 --force-device-scale-factor=1 \
    --screenshot="assets/icon/$out.png" --window-size="$w,$h" \
    "file://$WORK/$out.html" 2>/dev/null
  echo "  assets/icon/$out.png  (${w}×${h})"
}

# The mark's bounding box is x 94..438, y 76..418 in the 512 viewBox — wider
# up-and-right than the plate alone, because of the badge. Adaptive layers are
# fitted to 62% of the canvas and centred on *that* box, so the composition
# survives a circular mask without drifting off-centre.
SAFE='translate(10.54,28.07) scale(0.9228)'

echo "Rendering icon set:"

# Play requires the 512 icon to be opaque with square corners; it applies its
# own mask. So this one keeps the flat sage ground.
render 1024 1024 "<svg viewBox=\"0 0 512 512\"><rect width=\"512\" height=\"512\" fill=\"#56633f\"/>$MARK</svg>" icon

render 1024 1024 "<svg viewBox=\"0 0 512 512\"><g transform=\"$SAFE\">$MARK</g></svg>" icon_foreground

# The themed layer is line art. A filled plate with the cutlery drawn on top of
# it would merge into one blob the moment the system tints it a single colour.
render 1024 1024 "<svg viewBox=\"0 0 512 512\"><g transform=\"$SAFE\">
  <circle cx=\"256\" cy=\"256\" r=\"162\" fill=\"none\" stroke=\"#201e1d\" stroke-width=\"20\"/>
  <g stroke=\"#201e1d\" stroke-width=\"18\" stroke-linecap=\"round\"><path d=\"M208 362V248\"/><path d=\"M303 362V248\"/></g>
  <g stroke=\"#201e1d\" stroke-width=\"11\" stroke-linecap=\"round\"><path d=\"M186 236V184\"/><path d=\"M208 236V184\"/><path d=\"M230 236V184\"/></g>
  <g stroke=\"#201e1d\" stroke-width=\"22\" stroke-linecap=\"round\"><path d=\"M189 238H227\"/></g>
  <g stroke=\"#201e1d\" stroke-width=\"34\" stroke-linecap=\"round\"><path d=\"M303 242V194\"/></g>
  <circle cx=\"368\" cy=\"146\" r=\"70\" fill=\"none\" stroke=\"#201e1d\" stroke-width=\"18\"/>
  <g stroke=\"#201e1d\" stroke-width=\"13\" stroke-linecap=\"round\"><path d=\"M343 146h50\"/><path d=\"M368 121v50\"/></g>
</g></svg>" icon_monochrome

# 1024×500 feature graphic. Play overlays its own UI across the middle on some
# surfaces, so the copy stays left and the decoration stays right.
render 1024 500 '<div style="width:1024px;height:500px;background:#f5ead8;position:relative;overflow:hidden;display:flex;align-items:center;font-family:Figtree,system-ui,sans-serif;color:#201e1d">
  <div style="position:absolute;border-radius:50%;right:-90px;top:-140px;width:420px;height:420px;background:#e1eecc"></div>
  <div style="position:absolute;border-radius:50%;right:150px;bottom:-120px;width:250px;height:250px;background:#ffe1d0"></div>
  <div style="position:absolute;right:96px;top:150px;width:200px;height:200px">
    <svg viewBox="0 0 512 512" style="width:200px;height:200px">
      <circle cx="256" cy="256" r="256" fill="#56633f"/>
      <circle cx="256" cy="256" r="150" fill="#f5ead8"/>
      <g stroke="#56633f" stroke-width="18" stroke-linecap="round"><path d="M208 362V248"/><path d="M303 362V248"/></g>
      <g stroke="#56633f" stroke-width="11" stroke-linecap="round"><path d="M186 236V184"/><path d="M208 236V184"/><path d="M230 236V184"/></g>
      <g stroke="#56633f" stroke-width="22" stroke-linecap="round"><path d="M189 238H227"/></g>
      <g stroke="#56633f" stroke-width="34" stroke-linecap="round"><path d="M303 242V194"/></g>
      <circle cx="368" cy="146" r="70" fill="#56633f"/>
      <circle cx="368" cy="146" r="54" fill="#c67139"/>
      <g stroke="#f5ead8" stroke-width="13" stroke-linecap="round"><path d="M343 146h50"/><path d="M368 121v50"/></g>
    </svg>
  </div>
  <div style="padding-left:72px;max-width:520px;position:relative">
    <h1 style="font-family:Caprasimo,serif;font-weight:400;font-size:54px;line-height:1.08;margin:0 0 18px">One small thing,<br>added to what<br>you <span style="color:#56633f">already eat</span>.</h1>
    <p style="font-size:21px;line-height:1.4;margin:0;color:#474238">Photograph your meal. Get one thing to add. No counting.</p>
  </div>
</div>' feature_graphic

echo
echo "Generating launcher sizes:"
dart run flutter_launcher_icons
