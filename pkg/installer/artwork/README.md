# Package artwork

`icon0.png` is the tile the PS4 home screen shows for PS4 XFCE Linux: **512x512**,
the size the XMB loads, drawn for this project instead of borrowed from the
OpenOrbis samples.

```
sha256 cf2055650d8cb2b1e6ba750cdbfa33c8695b7664f816f1e0b0772afe1c136033
```

Drop the file in this directory as `icon0.png` and `make APP=install` picks it up,
printing:

```
  icon: artwork/icon0.png (this project's tile)
```

Without it the build falls back to the OpenOrbis sample and says so, rather than
failing. The image itself is attached to the `v1.0.0` release.

The design: two stacked, slanted matte-black plates with a glowing amber seam
between them, on a midnight-blue field with a teal halo behind - the console
silhouette in flat vector form. No logos, lettering or third-party marks, so
there is nothing to license and nothing that looks wrong on a 4K screen.
