# Storage layout, and the shared-path problem

## The constraint

The Linux loader's search order is fixed upstream:

```
/mnt/usb0 > /mnt/usb1 > /data/linux/boot > /user/system/boot
```

It looks for `bzImage` and `initramfs.cpio.gz` by those exact names, plus optional
`bootargs.txt` and `vram.txt`. There is no configuration file that redirects it to
another directory.

So "use namespaced paths" - the obvious way to avoid colliding with a coexisting
install - is not possible without forking the loader. Any install that boots from
the internal drive must own those four filenames in `/data/linux/boot`.

## What we do instead: explicit ownership with a backup

Before writing our own boot files, the installer:

1. scans `/data/linux/boot` for `bzImage`, `initramfs.cpio.gz`, `bootargs.txt`,
   `vram.txt`;
2. renames any it finds to `<name>.ps4linux-bak`;
3. appends a line to `/data/ps4linux/backups.txt` recording each move;
4. only then copies ours in.

Uninstall (or a "restore what was here" action in the app) renames them back and
deletes the manifest. Nothing is destroyed, and the user is told in the briefing
that an existing Linux install's boot files will be moved aside - with the reason.

This is deliberately *not* silent. If a ChromeOS or other Linux install is using
those files, its own launcher will stop working until the files are restored, and
that is stated on the confirmation screen.

**The loader also writes to those paths itself.** From v23 on, if it finds a
FAT32 external partition carrying `bzImage` and `initramfs.cpio.gz`, it copies
them into `/data/linux/boot` so no stick is needed on later boots. That means a
stick left plugged in can silently replace the boot files our installer placed,
backups notwithstanding. The recovery instructions say so, and the app warns
when a stick with those filenames is attached.

## Why not fork the loader

A patched loader that honours a `ps4linux/` subdirectory is technically easy -
`ps4-linux-loader` is open source - but it means maintaining a fork of the one
component whose firmware support (5.05-14.00) is the reason anything boots at all.
Diverging there turns a firmware-support update into a merge. Revisit only if
loader upstream accepts a configurable path.

## Image layout

Internal install: one ext4 file, `/user/app/ps4linux.img`, with no partition
table in it at all.

| Region | Contents |
|---|---|
| filesystem root | the Debian rootfs, `/home` and the Steam library inside it |

An earlier draft used GPT with separate `root`/`boot`/`home` partitions. That
does not survive contact with how the console actually boots: PS4-Multiboot opens
the image as a flat block device and hands it to the kernel through
`blockmap`/`FIBMAP`, which maps *file* blocks. A partition table inside the file
needs an offset parser with nothing to parse against, and every partition
boundary is a region the mapping cannot represent. One filesystem, fully
allocated, is the only shape that maps cleanly.

What follows from that, all of it already assumed elsewhere in this design:

- **The image must be fully allocated.** A hole has no block for `FIBMAP` to
  return, so a sparse image fails to boot or boots corrupt. Build with
  `fallocate`; copy with FTP or `dd`, never `rsync -S`, which recreates holes.
- **Kernel and initramfs are not in the image.** `bzImage`,
  `initramfs.cpio.gz`, `bootargs.txt` and `vram.txt` stay in `/data/linux/boot`,
  which the loader reads before any filesystem exists. Keeping a second copy
  inside the image would be a second thing to keep in sync, and the loader
  would still use the one in `/data/linux/boot`.
- **The label must end in `-PS4`** (`DEBIAN-PS4`, `ARCH-PS4`). That suffix is how
  Multiboot's scan recognises a Linux image. The stock `psxitarch` label is not
  used here, and an image labelled that way will not be found.
- **Size is fixed at build time**, so it must be chosen up front. Growing it
  later means copying the whole file, and the console has no tool for that.
- **`orphan_file` must be off** - see the section below.

The image is built on a host, not on the console: `mke2fs -d <tarball|tree>`
populates it in one pass, which is why the console never needs a compiler or a
debootstrap. The console only reserves space and copies bytes.

External install: the same kind of single fully-allocated ext4 image, but written
onto a dedicated USB device and labelled `USB-PS4`, rediscovered by filesystem
UUID recorded in `/data/ps4linux/ext.uuid`. Never the internal drive: the
installer refuses to write a device that holds the PS4 system.

## The ext4 features that matter

`mke2fs` 1.47 enables `orphan_file` on some distributions' default config
(Ubuntu's among them). Kernels older than 5.15 cannot mount such a filesystem,
and the PS4 5.4 kernels cannot. The ChromeOS project hit exactly this - its
state partition is formatted `-O ^orphan_file,^metadata_csum_seed` for the same
reason.

So the rule is: always pass `-O ^orphan_file` when building, and run
`scripts/check-image.sh` on the result before it goes near the console. The
validator fails such an image on the host, where the failure is a message,
rather than at boot, where it is a black screen and a bug report.

## Files we own vs files we touch

| Path | Owner | Notes |
|---|---|---|
| `/user/app/ps4linux.img` | us | the whole install |
| `/data/ps4linux/*` | us | manifest, choice, backups, external GUID |
| `/data/linux/boot/{bzImage,initramfs.cpio.gz,bootargs.txt,vram.txt}` | shared | backed up before we write |
| `/data/linux/boot/ps4linux-loader.bin` | us | ours by name |
| `/data/payloads/ps4linux-loader.bin` | us | ours by name |
| `/data/pkg`, `/user/app/CUSA*`, `/user/home` | PS4 | never touched |
| `/data/linux/boot/chromeos*` | ChromeOS | only touched by the explicit removal flow |
