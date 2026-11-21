#!/bin/sh
# Fetches the two stb single-file libraries used by the screens and by the
# preview tool: stb_truetype.h (text rasterising) and stb_image_write.h (PNG
# output in tools/ui-preview).
#
# They are third-party code, kept out of git because they are ~290 KB of
# headers that nobody edits. Run this once after a fresh clone; the build stops
# with a clear message if they are missing.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TRUETYPE="$HERE/../pkg/installer/ui/stb_truetype.h"
WRITE="$HERE/../tools/ui-preview/stb_image_write.h"
BASE=https://raw.githubusercontent.com/nothings/stb/master

fetch() {
	[ -f "$2" ] && { echo "have $2"; return 0; }
	mkdir -p "$(dirname "$2")"
	if curl -fsSL "$1" -o "$2"; then
		echo "got $2"
	else
		rm -f "$2"
		echo "could not fetch $1" >&2
		exit 1
	fi
}

fetch "$BASE/stb_truetype.h" "$TRUETYPE"
fetch "$BASE/stb_image_write.h" "$WRITE"
