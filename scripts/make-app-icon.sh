#!/bin/zsh
# The app icon, from design/station's artwork (full-bleed 1024px, dark and light):
#   Station/AppIcon.icon         Icon Composer icon: macOS 26 draws it natively and switches it
#                                with light/dark (a flat PNG icon gets put in a grey plate there);
#                                Xcode derives the classic .icns for macOS 14-15 from it
#   StationIcon{Light,Dark}      the icon as macOS renders each look, for Settings → App icon's
#                                Light/Dark pin (a runtime icon can't be re-rendered)
# Run: scripts/make-app-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
LIGHT=design/station/station-stripes-light-art-1024.png
DARK=design/station/station-stripes-dark-art-1024.png
ICON=Station/AppIcon.icon
ASSETS=Station/Assets.xcassets

icon_json() { # $1: extra JSON for the light (default) look, $2: for dark ("" = none)
  cat <<JSON
{
  "fill-specializations" : [ $1 ],
  "groups" : [ { "layers" : [ { "image-name-specializations" : [ $2 ], "name" : "stripes" } ] } ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON
}
WHITE='{ "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }'
BLACK='{ "solid" : "srgb:0.00000,0.00000,0.00000,1.00000" }'

rm -rf "$ICON"; mkdir -p "$ICON/Assets"
cp "$LIGHT" "$ICON/Assets/stripes-light.png"; cp "$DARK" "$ICON/Assets/stripes-dark.png"
icon_json "{ \"value\" : $WHITE }, { \"appearance\" : \"dark\", \"value\" : $BLACK }" \
          '{ "value" : "stripes-light.png" }, { "appearance" : "dark", "value" : "stripes-dark.png" }' > "$ICON/icon.json"

# Each look on its own, compiled by actool, taken from the .icns it renders.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for look in Light Dark; do
  src=$([ $look = Light ] && echo "$LIGHT" || echo "$DARK"); fill=$([ $look = Light ] && echo "$WHITE" || echo "$BLACK")
  one="$TMP/$look/AppIcon.icon"; mkdir -p "$one/Assets" "$TMP/$look/out"
  cp "$src" "$one/Assets/stripes.png"
  icon_json "{ \"value\" : $fill }" '{ "value" : "stripes.png" }' > "$one/icon.json"
  xcrun actool "$one" --compile "$TMP/$look/out" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$TMP/$look/p.plist" >/dev/null
  iconutil -c iconset "$TMP/$look/out/AppIcon.icns" -o "$TMP/$look/set.iconset"
  set="$ASSETS/StationIcon$look.imageset"; rm -rf "$set"; mkdir -p "$set"
  cp "$TMP/$look/set.iconset/icon_128x128@2x.png" "$set/StationIcon$look.png" # 256px: the largest actool renders, and what the Dock draws
  echo "{\"images\":[{\"filename\":\"StationIcon$look.png\",\"idiom\":\"mac\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$set/Contents.json"
done
echo "wrote $ICON, StationIconLight, StationIconDark"
