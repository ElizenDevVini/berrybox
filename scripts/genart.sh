#!/usr/bin/env bash
# Generates card art via Higgsfield CLI into web/public/cards/.
# Chase cards use nano_banana_2_lite (1 credit), commons use z_image (0.15).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=web/public/cards
mkdir -p "$OUT"

STYLE="dynamic shonen anime trading card art, One Piece anime style, painterly cel shading, dramatic lighting, ocean adventure backdrop, portrait composition, no text, no letters, no logo, no border"

gen() { # model slug prompt
  local model="$1" slug="$2" prompt="$3"
  if [ -s "$OUT/$slug.png" ]; then echo "skip $slug"; return 0; fi
  echo "gen $slug ($model)"
  local url
  url=$(higgsfield generate create "$model" --prompt "$prompt" --aspect_ratio 3:4 --wait --wait-timeout 15m --json 2>/dev/null | jq -r '.[0].result_url // empty')
  if [ -z "$url" ]; then echo "FAIL $slug" >> "$OUT/failures.txt"; return 1; fi
  curl -sL -o "$OUT/$slug.png" "$url" && echo "done $slug"
}

# chase cards
gen nano_banana_2_lite luffy "Young pirate captain in an open white cardigan and white shorts, wild white glowing hair, huge joyful grin, rubbery exaggerated pose standing on swirling white clouds, godlike aura, sun motif behind him, $STYLE"
gen nano_banana_2_lite shanks "Red-haired pirate emperor with three claw scars over his left eye, black cloak draped over shoulders, one arm, calm commanding stare, monochrome manga ink style with only his hair in vivid red, crosshatched shading, $STYLE"
gen nano_banana_2_lite zoro "Green-haired swordsman fighting with three katanas, one held in his teeth, black bandana, green haramaki sash, whirlwind of slashes around him, fierce expression, $STYLE"

# commons
gen z_image nami "Orange-haired navigator girl with a long segmented staff summoning storm clouds and lightning, tangerine motifs, confident smirk, $STYLE"
gen z_image sanji "Blond chef in a black suit delivering a high kick with his leg wreathed in flames, curly eyebrow, cigarette smoke curling, $STYLE"
gen z_image chopper "Tiny cute reindeer creature in an oversized pink hat with a white X, blue nose, round eyes, waving happily, doctor bag beside him, $STYLE"
gen z_image usopp "Long-nosed sniper with dark curly hair under a bandana, goggles, aiming a giant green slingshot, brave scared expression, $STYLE"
gen z_image robin "Tall dark-haired archaeologist woman in purple, extra arms blooming like flower petals crossed in front of her, calm mysterious smile, $STYLE"

echo "batch complete"
ls -la "$OUT"
