# Status: 2026-11-21

## Built and validated

| Package | Bytes | sha256 | `pkg_validate` |
|---|---|---|---|
| `PS4-XFCE-Linux.pkg` | 294,846,464 | `495872b3afb720f6a139c25e7bde161d673f4b144a14e586d63a0e33138c4dc7` | 28/28 |
| `PS4Linux-Remove-ChromeOS.pkg` | 6,619,136 | `b518fdece3ae38760497c1944f027389790c148d9b3cdae27c860e75b8cd873b` | 28/28 |

Both now carry the screens and the three DejaVu fonts they draw with. Still
**not run on a console**.

## What changed in this build

- The app draws its own screens with SDL (software blit) and reads ScePad,
  falling back to the system dialogs when SDL, the fonts or a pad are missing.
- Graphics memory offers 1024/2048/3072/4096/**5120**/**6144** MB from one shared
  list that both the screen and the dialog path read.
- The remover asks its first question on the new screen.
- A desktop theme in the app's palette (GTK 3 + xfwm4), seeded into `/etc/skel`.

## Not in this repository yet

These exist in the build workspace but are not committed here, because they
were written after the last source push and are large:

- `pkg/installer/installer/main.c`, `remove.c` - the wiring for the screens.
- `pkg/installer/ui/` - `ui.c`, `soft.c`, `status.c`, `screen.c`, `appui.c` and
  their headers (the screens, the CPU rasteriser, the status reader, the console
  backend and the interaction loops).
- `pkg/installer/Makefile` - the UI sources, SDL/Sce libs and the font assets.
- `tools/ui-preview/` - the PNG harness that renders every screen on a PC.
- `scripts/make-pkg.sh` and `scripts/build-rootfs.sh` - the ICU invariant flag,
  the font staging call and the theme install block.

A tree with these files is at commit `8ef4e49` in the build workspace; run
`git push origin HEAD:main` from there to bring them here. Until then, a clone
builds the previous, dialog-only app.

## Regenerate, do not download

The theme's images and the stb headers are generated, not stored:

```sh
python3 theme/make-theme.py   # wallpaper + 44 xfwm4 images
scripts/get-stb.sh            # stb_truetype.h, stb_image_write.h
scripts/get-fonts.sh          # DejaVu, from fonts-dejavu-core
```
