# Package artwork

Both tiles are **512x512**, the size the XMB loads, and both are drawn for this
project.

| File | Used by | sha256 |
|---|---|---|
| `icon0.png` | `make APP=install` - PS4 XFCE Linux | `cf2055650d8cb2b1e6ba750cdbfa33c8695b7664f816f1e0b0772afe1c136033` |
| `icon0-remove.png` | `make APP=remove` - PS4 Linux: Remove ChromeOS | `41c19f6f9cca59f41f58675f9e3751613e603b983f494b9c1ac238658b407ce8` |

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

**The remover** names what it takes away. It carries the ChromeOS mark - three
120-degree sectors with a blue centre - framed by a red prohibition ring and a
diagonal bar, on the same midnight-blue field. A tile that only said "a console,
struck through" was ambiguous about which thing was going; this one is not.

The ChromeOS mark is used descriptively, to identify the software this package
removes. ChromeOS and the Chrome logo are trademarks of Google LLC; this project
is not affiliated with, endorsed by or sponsored by Google, and the mark is drawn
here rather than copied from a brand asset.
