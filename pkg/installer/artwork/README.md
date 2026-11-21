# Package artwork

Both tiles are **512x512**, the size the XMB loads, and both are drawn for this
project.

| File | Used by | sha256 |
|---|---|---|
| `icon0.png` | `make APP=install` - PS4 XFCE Linux | `cf2055650d8cb2b1e6ba750cdbfa33c8695b7664f816f1e0b0772afe1c136033` |
| `icon0-remove.png` | `make APP=remove` - PS4 Linux: Remove ChromeOS | `ab747efd155f73306e04221613113616fdf25641c0b4189fd991cb7249d6e026` |

Drop them in this directory and the build picks the right one per app, printing:

```
  icon: artwork/icon0.png (this project's tile)
```

Without them the build falls back to the OpenOrbis sample and says so, rather
than failing. The images themselves are attached to the `v1.0.0` release.

## What the two tiles say

**The installer** is the console: two stacked, slanted matte-black plates with a
glowing amber seam, on a midnight-blue field with a teal halo. It is the system
being put on the machine.

**The remover** names what it takes away. It carries the ChromeOS mark framed by
a red prohibition ring and a diagonal bar, on the same midnight-blue field. A tile
that only said "a console, struck through" was ambiguous about which thing was
going; this one is not.

**It is the Flex mark, so it is monochrome.** ChromeOS Flex is the greyscale
brand: the same ring-and-core form as ChromeOS, drawn in a single silver tone with
a darker grey core, not the four-colour Chrome mark. The only colour on the tile is
the prohibition sign, which is the point of the tile.

ChromeOS and ChromeOS Flex are trademarks of Google LLC. The mark is drawn here to
identify the software this package removes; this project is not affiliated with,
endorsed by or sponsored by Google.
