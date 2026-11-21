# PS4 Linux - desktop theme

The app's look, on the desktop: navy surfaces, one blue for focus and selection,
the same ink text, and a wallpaper made from the same two lights as the app's
background. GTK 3 + xfwm4, which is what XFCE on the image uses.

## Install on a running system

```sh
python3 theme/make-theme.py     # writes the images (once)
theme/install.sh                # ~/.themes + ~/.local/share
sudo theme/install.sh           # or system-wide
```

Then pick **PS4 Linux** in Settings > Appearance, or let the script set it with
`xfconf-query`. The window decorations, the panel, menus, entries, lists and
scrollbars are all in the stylesheet.

## In the image

`scripts/build-rootfs.sh` copies this directory to `/usr/share/themes/ps4linux`,
the wallpaper to `/usr/share/backgrounds/ps4linux.png`, and seeds
`/etc/skel/.config/xfce4` so a new user starts with the theme already on. Run
`theme/make-theme.py` before the rootfs build: the generated images are not in
git.

## What is in here

- `ps4linux/gtk-3.0/gtk.css` - the palette and every widget rule that matters.
- `ps4linux/xfwm4/` - `themerc` plus the titlebar and button images, generated
  by `make-theme.py`. Buttons are circles with the app's glyph language.
- `ps4linux/wallpaper.png` - 1920x1080, the app's background (generated).
- `make-theme.py` - regenerates the images from the palette.
- `make-preview.py` - draws `preview.png`, a picture of the intended result.
- `install.sh` - copies it into place and points XFCE at it.

## Not verified

Nothing here has been seen on a real XFCE session yet: the preview is a drawing
of it, not a capture. GTK themes are easy to get subtly wrong (a widget you
never opened), so expect to adjust a rule or two after the first look. The icon
theme is left at whatever the image ships (`Papirus` is seeded, but the
stylesheet does not depend on it).
