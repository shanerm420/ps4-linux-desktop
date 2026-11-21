#!/bin/sh
# Installs the PS4 Linux desktop theme.
#
#   ./install.sh          for the current user (~/.themes, ~/.local/share)
#   sudo ./install.sh     system-wide (/usr/share/themes, /usr/share/backgrounds)
#
# Then it points XFCE at the theme with xfconf-query, if that is available.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/ps4linux"

[ -d "$SRC" ] || { echo "run make-theme.py first: $SRC is missing" >&2; exit 1; }

if [ "$(id -u)" = 0 ]; then
	THEMES=/usr/share/themes
	BG=/usr/share/backgrounds
else
	THEMES="$HOME/.themes"
	BG="$HOME/.local/share/backgrounds"
fi

mkdir -p "$THEMES" "$BG"
rm -rf "$THEMES/ps4linux"
cp -a "$SRC" "$THEMES/ps4linux"
cp -a "$SRC/wallpaper.png" "$BG/ps4linux.png"
echo "theme:     $THEMES/ps4linux"
echo "wallpaper: $BG/ps4linux.png"

if command -v xfconf-query >/dev/null 2>&1; then
	set_prop() {
		# create the property when it does not exist yet
		xfconf-query -c "$1" -p "$2" -s "$3" 2>/dev/null ||
			xfconf-query -c "$1" -p "$2" -n -t string -s "$3"
	}
	set_prop xsettings /Net/ThemeName ps4linux
	set_prop xfwm4 /general/theme ps4linux
	set_prop xfce4-desktop /backdrop/screen0/monitor0/workspace0/last-image \
		"$BG/ps4linux.png"
	echo "XFCE settings updated (log out and back in if the panel keeps the old look)."
else
	echo "xfconf-query not found: pick \"PS4 Linux\" in Settings > Appearance."
fi
