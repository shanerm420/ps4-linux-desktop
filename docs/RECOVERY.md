# Recovery

Nothing in this project modifies the PS4 system, its partitions, games or saves.
Every failure mode below is recoverable, but read the boot-loop section carefully
- that one is caused by a setting *outside* this project.

## Removing an install: a file, not a partition

A PS4 Linux install - the ChromeOS project's included - is **not a partition on
the PS4 drive**. The drive holds Sony's own encrypted UFS filesystem, and the
install is one large file inside it (`/user/app/chromeos.img` for ChromeOS,
`/user/app/ps4linux.img` for this project) that Linux sees as a loop device.
Deleting the file deletes the install. Nothing is repartitioned, and no live USB
is involved:

- **From the app:** the removal screen lists every file with its size and asks
  twice. The dry run prints the same list and changes nothing.
- **From OrbisOS over FTP** (GoldHEN's FTP server): delete
  `/user/app/chromeos.img` and the artifacts in `/data/linux/boot/`
  (`chromeos.img.xz`, `chromeos.img.size`, `chromeos.img.alloc*`,
  `ps4-layer.sqfs`, `chromeos-target`, `build-id`, and the loader `.bin` in both
  `/data/linux/boot` and `/data/payloads`).
- **Never** reach for "Initialize PS4" or any system-format option to get the
  space back. That erases games and saves; the files above are the only things
  that need to go. If free space does not update at once, reboot once.

A PC cannot do this for you either: the PS4 drive is encrypted with the console's
own EAP key, which exists only in the memory of a running, jailbroken console. A
Linux live USB on a laptop sees an unreadable disk, not a filesystem to edit.

## Starting Linux when BinLoader is off

The installer hands the loader to GoldHEN's BinLoader on `127.0.0.1:9090`, and it
also copies `ps4linux-loader.bin` into `/data/payloads` so the file appears in
GoldHEN's **Payloads** menu. If BinLoader is disabled - which is the usual
default - the app reports that it could not start the loader, and nothing boots.
The install itself is already finished at that point; only the launch is missing.

Start it by hand:

1. GoldHEN menu -> **Utilitys** -> **PayLoader** -> **LaunchPad**
   (older builds call the section **Payloads**)
2. choose `ps4linux-loader.bin`
3. the console restarts into Linux

This is the route with the strongest evidence behind it. The reference console
runs ChromeOS for PS4, which uses the same loader family (`ps4-linux-loader`) and
is started from that same menu, so launching the payload by hand is proven on
that hardware even where the automatic path is not.

GoldHEN needs to be **2.4b18.10 or newer** for the built-in payloader according to
upstream's guide, though the reference console runs an older build and its menu
works. If your menu is missing or empty, that is the first thing to check.

The loader lives in two places: `/data/linux/boot/ps4linux-loader.bin` (what the
loader reads at boot) and `/data/payloads/ps4linux-loader.bin` (what the menu
lists). If the menu is empty, the second copy is missing - copy it over FTP from
the first path. That copy is never required for booting, only for launching.

## The console will not boot into Linux

1. Hold the power button until it turns off. Start it normally.
2. If it still goes to a black screen or the LED stays white, the kernel started
   before OrbisOS finished writing. Wait a minute, then start the console and
   launch the app again - the install resumes.
3. Check `/data/ps4linux/manifest.txt` and the GoldHEN log (port 3232) over FTP.

## Rescue shell (works even with a broken install)

Put a USB stick (FAT32 or exFAT) with an empty file named `ps4linux-recovery` in
its root, plug it in, and start Linux from the app. The initramfs stops before
touching the image and gives a shell.

This works because the loader checks USB **first** - the flag is read before the
internal image is even opened. From that shell you can mount the image, read
`/var/log/`, fix `fstab`, or copy data off.

## Boot loop after enabling payload autoload

**Symptom:** the console loads the exploit and immediately restarts, over and
over, before you can reach the home screen.

**Cause:** a Linux payload in an autoload location. Every jailbreak autoloads it,
and the payload immediately shuts OrbisOS down and starts Linux, so the loop never
ends. This project never writes an autoload entry - the installer explicitly
refuses to - so the entry came from a manual step or a third-party autoloader.

**Fix (the path that worked on the reporting console):**

1. Power off fully (hold the button).
2. Boot the exploit chain with a homebrew enabler that does **not** autoload
   payloads - NextHEN is what was used successfully. PS4HEN Lite or Mira are the
   same idea.
3. Once you have FTP or a file manager, delete the Linux payload from wherever it
   was autoloaded, and any autoload list entry that names it. Known locations
   differ between GoldHEN builds and third-party loaders:
   `/data/GoldHEN/autoload/`, `/data/GoldHEN/autoload.txt`,
   `/data/bdj_autoload.cfg`, `/data/payloads/autoload.txt`.
4. Reboot, re-enable GoldHEN, and confirm the console stays on the home screen.
5. Launch Linux only from the app from then on.

**Honest limits of this advice:** I could not verify NextHEN's supported-firmware
matrix, so step 2 is not universal. The autoload path also differs by GoldHEN
version. Inspect the GoldHEN menu and folders on *your* firmare instead of
trusting a path from a document. If no non-autoloading enabler exists for your
firmware, treat that firmare as unproven for recovery and record it in
`docs/TEST-MATRIX.md`.

## Linux boots but the desktop does not start

Switch to a text console (`Ctrl+Alt+F2`) and check:

```
systemctl --failed
journalctl -b -p err
cat /var/log/ps4-hwprophile.txt
```

The most likely causes, in order: the PS4-patched Mesa is missing from
`/opt/ps4-mesa` (so `radeonsi` never binds), or `/boot` was not remounted
read-only and something wrote to it.

## A bad update broke the boot

The kernel and initramfs are not managed by apt. If a *PS4 components update*
fails, the boot counter falls back to the previous slot after three attempts. If
both slots are broken, use the USB rescue shell and restore from
`/var/backups/ps4linux/`.

## Uninstall

1. Delete the app from the PS4 home screen.
2. Over FTP, delete `/user/app/ps4linux.img` (or reformat the USB drive).
3. Delete `/data/ps4linux/` and the `ps4linux-*` files in `/data/linux/boot`
   and `/data/payloads`.
4. If `backups.txt` lists files that were moved aside, rename them back.

Nothing else on the console is affected.
