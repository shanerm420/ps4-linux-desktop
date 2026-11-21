# Package artwork

Both tiles are this project's own artwork: **512x512**, the size the XMB loads.
They are the same mark, so the pair reads as a set on the home screen.

| File | Used by | sha256 |
|---|---|---|
| `icon0.png` | `make APP=install` - PS4 XFCE Linux | `cf2055650d8cb2b1e6ba750cdbfa33c8695b7664f816f1e0b0772afe1c136033` |
| `icon0-remove.png` | `make APP=remove` - PS4 Linux: Remove ChromeOS | `8d3b9d035b785f580c7b74bb074c84bef356383698e2e97797aaca56e5ac8100` |

Drop them in this directory and the build picks the right one per app, printing:

```
  icon: artwork/icon0.png (this project's tile)
```

Without them the build falls back to the OpenOrbis sample and says so, rather
than failing. The images themselves are attached to the `v1.0.0` release.

The design: two stacked, slanted matte-black plates with a glowing amber seam
between them, on a midnight-blue field with a teal halo - the console silhouette
in flat vector form. The remover's tile is that same image dimmed and desaturated,
with a red prohibition sign (ring and diagonal bar) over it: dimmed because the
thing is being taken away, struck through because that is what the app does.
Neither uses a logo, lettering or any third-party mark, so there is nothing to
license and nothing that looks wrong on a 4K screen.
