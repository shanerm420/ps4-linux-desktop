# PS4 Linux

A full Linux distribution for jailbroken PS4 consoles, installed from a PS4 PKG.
Replaces the ChromeOS-based installer with Debian + XFCE.

**This tree is a working skeleton, not a release.** Read the status table before
assuming anything works.

**Start here:** [`docs/USAGE.md`](docs/USAGE.md) is the full guide - what you need,
installing, the menu, autoload, recovery, updating and removing. The kernel has its
own project: [ps4-linux-kernel](https://github.com/shanerm420/ps4-linux-kernel)
(provenance, `build.sh`, checksums).

## Status

| Area | State |
|---|---|
| App source (`pkg/installer/`) | Written; type-checks against the real Orbis headers |
| App compiled to `eboot.bin` | **Built** — 122,432 bytes with clang 18 + `ld.lld` against `link.x` |
| PKG produced | **Built and validated** — `pkg_validate` 28/28, 278,659,072 bytes; carries the real kernel, a real initramfs, the Debian/XFCE rootfs and the PS4-patched Mesa. The loader payload is still a placeholder |
| PKG installed on a console | **Not done** |
| ChromeOS detection / removal rules | **Implemented and tested** (24 assertions, synthetic tree) |
| Hardware detection tool | **Built and run** on a normal Linux host |
| Image validator (`scripts/check-image.sh`) | **Run** against real images: passes a good one, rejects an `orphan_file` one |
| Kernel build (`scripts/build-kernel.sh`) | **Run** — produced a 14,251,008-byte `bzImage`, release `7.3.4-PS4Linux-baikal+` |
| Initramfs built (`scripts/build-initramfs.sh`) | **Run** — 29,548,535 bytes from the feeRnt base, with the boot handoff spliced into its init and the autoload policy step |
| Debian rootfs built (`scripts/build-rootfs-rootless.sh`) | **Run** — Debian 13 + XFCE, 405 packages, 231,872,740-byte `rootfs.tar.zst` |
| PS4-patched Mesa (`scripts/build-mesa.sh`) | **Built** — Mesa 25.0.7 (the version Debian 13 ships), 1,470 targets, 0 failures, 42 MB; radeonsi + RADV, `LIVERPOOL`/`GLADIUS` in the driver. Inside the PKG at `/opt/ps4-mesa` |
| Debian rootfs booted on a PS4 | **Not done** |
| Anything at all tested on PS4 hardware | **Nothing** |

`docs/TEST-MATRIX.md` lists every hardware test with its real status. Every console
row is `untested`, because no console was available.

## The two packages

| Package | TITLE_ID | What it does |
|---|---|---|
| PS4 Linux | `PS4LNX001` | The app: installs Linux, starts it, and holds the menu for graphics memory, autoload and recovery |
| PS4 Linux: Remove ChromeOS | `PS4LNX002` | Removes a ChromeOS-for-PS4 install, and nothing else |

Separate on purpose. The app deletes nothing that existed before it ran - its
`unlink()` calls only clean up temporary files it created itself - with one
exception the user asks for by name: a payload autoload entry, which it lists
first. The remover is the only code that removes a ChromeOS install, it lists
every path with its size first, and it asks twice. It cannot install anything.

If a ChromeOS install is present, the app says so and installs beside it,
pointing at the remover for the space. Both apps are built from one tree:
`make APP=install` and `make APP=remove`, which `scripts/make-pkg.sh` runs in
sequence and cleans between, because the intermediate names are shared.

## The menu

Launching the app opens a menu with one entry per category, and each entry has its
own submenu. Start Linux is always the first entry, so the everyday case stays one
press away.

| Entry | Submenu |
|---|---|
| Start Linux | none - it sends the loader and boots |
| Graphics memory (VRAM) | show the current size, change it (1024/2048/3072/4096 MB) |
| Autoload | check what is armed, remove the entry, boot behaviour |
| Remove ChromeOS | what was found, and why the separate app does the deleting |
| Recovery | write the rescue flag to a USB stick, what to do after a boot loop |
| Install Linux | only when nothing is installed: briefing, target, size, reserve, start |

The dialog API has two buttons and no list control, so a menu is one entry per
screen: **Select** opens the entry shown, **Next** shows the next one.

**Boot behaviour** (the third Autoload entry) decides what a *Linux start* does
about an autoload entry - which matters because the app cannot run during a live
loop:

- `ask` (default) - leave the entry alone, leave a note, and this app offers to
  remove it the next time it launches;
- `remove` - delete the known autoload files during the boot, so a console that
  reaches Linux cannot loop again;
- `keep` - never touch them.

It is stored in `/data/linux/boot/autoload-policy` and read by the initramfs before
it switches to the root filesystem.

## Graphics: why Mesa is built here

Stock Mesa does not bind the PS4 GPU. Liverpool (original/Slim) and Gladius (Pro)
are GCN parts whose device ids are not in Mesa's chip tables, so radeonsi refuses
the card and the desktop comes up on llvmpipe - software rendering, unusable for
anything 3D.

`scripts/build-mesa.sh` fixes that the same way fail0verflow did in 2016: a small
patch (`patches/ps4-mesa.patch`) that adds the two chips as Bonaire-class GFX7
parts, with their raster configuration. It builds Mesa 25.0.7 - the version
Debian 13 ships, so the image's libglvnd, libLLVM and libdrm match exactly - with
radeonsi and RADV, without root and without Docker, by unpacking Debian 13's own
build dependencies into a sysroot and compiling against that.

The result goes to `/opt/ps4-mesa`, not into the distro's paths: an `apt upgrade`
cannot replace it, and the vendor files (`libGLX_ps4-mesa.so.0`,
`10-ps4-mesa.json`) point libglvnd at it. `etc/environment` selects it for GLX and
Vulkan; EGL tries it first and keeps the distro build as a fallback, so a GPU that
does not come up gives a slow desktop rather than a black screen.

**What is proven:** it builds, it links against the right glibc, and the chip names
are in the driver. **What is not:** that radeonsi binds on a real console. That is
one row in the test matrix, and it needs a PS4.

## Reference console

Development target: **PS4 Pro, Baikal southbridge, firmware 12.52, GoldHEN.**

The `Baikal (Pro)` column of the test matrix is the one to fill first. Two facts
about this machine are established, and neither is a claim about this software:
the Linux loader lists firmware 12.50/12.52 as supported, and a ChromeOS-for-PS4
install has booted on it — which proves the drive key, AES-XTS and UFS2 with
`--skip 111669149696` work on this exact board. Everything else here is still
unproven.

Two traps that cost people a boot, both documented upstream:

- **GoldHEN v2.4b18.8 does not boot the loader.** Use the latest GoldHEN.
- **The kernel tree is GitLab `gitlab.com/rmuxnet/linux`, branch `ps4/7.3.4`.**
  One branch covers Aeolia, Belize and Baikal; the southbridge is detected at
  runtime. `scripts/build-kernel.sh` clones exactly that and nothing else.

## Using the console as a computer only

Starting Linux is a deliberate press in the app, every time. If you would rather
have it start on its own, that is a supported choice - with one thing worth being
precise about: **the console still boots into the PS4 system.** Autoload is a
GoldHEN feature, so nothing happens until you run GoldHEN. Power the console on
and you get the normal PS4 home screen, games and all; the moment the exploit
loads, the payload fires and the console goes into Linux instead.

That is also why it is set in GoldHEN and not here: the app never writes an
autoload entry, because an entry that fires on every jailbreak is how consoles end
up in a restart loop.

To turn it on, once Linux installs and starts correctly from the app:

1. The app has already put the real payload in
   `/data/payloads/ps4linux-loader.bin`, with a copy in
   `/data/linux/boot/ps4linux-loader.bin`.
2. In GoldHEN's settings, enable payload autoload and point it at that file. The
   wording differs between GoldHEN builds, so check yours: some read a folder
   (`/data/GoldHEN/autoload/`), others a list (`/data/GoldHEN/autoload.txt`,
   `/data/bdj_autoload.cfg`, `/data/payloads/autoload.txt`).
3. Run GoldHEN. Going into Linux instead of the payload menu is the confirmation;
   if it loads GoldHEN normally, autoload is not active yet.

**Know the way back before you need it.** With autoload on, this app cannot undo
it: it only runs *after* GoldHEN loads, and by then the payload has already
started Linux. So:

- Power on and do **not** run the exploit. You are in the normal PS4 system, with
  games, saves and the store, exactly as before.
- To remove the entry itself, load a homebrew enabler that does not autoload
  payloads (NextHEN, PS4HEN Lite, Mira), FTP in, and delete both the entry and
  the payload copy it names.
- If the entry is not currently firing - the payload it names is already gone, so
  the console boots normally - **PS4 Linux** removes it for you: it lists
  the file(s), asks, and deletes only those (**Autoload -> Remove the entry**).
  No FTP and no second enabler. It cannot do that during a live loop, because it
  only runs after GoldHEN loads.
- To get Linux back afterwards, put the payload file back - a fresh download in
  the root of a USB stick, or in `/data/payloads` - and launch this app. It copies
  it next to the kernel again and starts Linux. Nothing needs reinstalling: the
  install, the image and your files are untouched.
- `docs/RECOVERY.md` has the same steps written for the case where the console is
  already looping.

The app checks for an autoload entry on every launch, and the Autoload menu lists
the four known list files plus whatever sits in GoldHEN's autoload folder, so you
can see exactly what is armed.

## Layout

```
pkg/installer/          the PS4 app (OpenOrbis C) + Makefile
scripts/                build-kernel.sh, build-initramfs.sh, build-rootfs.sh,
                        build-rootfs-rootless.sh, build-mesa.sh, make-pkg.sh
patches/                ps4-mesa.patch - the PS4 device-id patch for Mesa
initramfs/              our boot/install function + the early recovery hook
rootfs/                 files installed into the Debian image (apt pins, units, ICD json)
tools/                  hwprofile.c (hardware truth), chromeos-scan.c (removal rules + test)
docs/                   ARCHITECTURE, LAYOUT, RECOVERY, USAGE, TEST-MATRIX
```

## Fastest path to a result on hardware

`scripts/make-test-usb.sh` builds a testable USB set with **no toolchain and no
PKG**: a prebuilt kernel (pinned URL), an initramfs repacked from the
initramfs-ps4 base, and a Debian rootfs as `distro.tar.xz` (the stock installer
refuses `.zst`). You then use two sticks on the console: a SOURCE stick holding
those three files, and an empty TARGET stick that gets erased and installed onto.

```sh
sudo PROFILE=minimal bash scripts/make-test-usb.sh   # console only, fastest
sudo PROFILE=desktop bash scripts/make-test-usb.sh   # XFCE
```

This deliberately uses the stock kernel and stock initramfs, so a failure is
attributable. Our app, the PKG and the recovery flag come in later stages.

## Build order

Prerequisites: x86-64 Linux host, ~30 GB free, `debootstrap`, `zstd`,
`squashfs-tools`, `sgdisk`, and a **built** OpenOrbis toolchain. No Docker, and no
root: Mesa and the rootfs both build unprivileged.

```sh
# The scripts are invoked through bash because the executable bit is not set in
# this repository yet (`git update-index --chmod=+x scripts/*.sh` fixes that).

# Use the toolchain *release*, not the git repository: bin/linux/ is empty until
# a release build. This is the archive the PKGs here were built with.
curl -LO https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain/releases/download/v0.5.4/toolchain-llvm-18.tar.gz
tar -xzf toolchain-llvm-18.tar.gz
export OO_PS4_TOOLCHAIN=$PWD/OpenOrbis/PS4Toolchain

SB=baikal        bash scripts/build-kernel.sh          # -> out/kbuild/out/bzImage
# already have a bzImage + .config? skip the build and point K at that directory:
#   K=/path/to/kernel  bash scripts/make-pkg.sh
                 bash scripts/build-mesa.sh            # -> out/ps4-mesa (15-40 min)
PS4_MESA=...     bash scripts/build-rootfs.sh
# or, on a host where you cannot be root:
#   PS4_MESA=$PWD/out/ps4-mesa ZSTD=/path/to/static/zstd PROOT=/path/to/proot \
#                  bash scripts/build-rootfs-rootless.sh
                 bash scripts/build-initramfs.sh
                 bash scripts/make-pkg.sh
```

The git repository of the toolchain is **not** enough: `bin/linux/` is empty
until `build.sh` runs, and `PkgTool.Core` (Sony's packaging tool) is only present
in a built toolchain. `make-pkg.sh` fails with a clear message if it is missing.

`make-pkg.sh` warns and carries on if `PS4_MESA` was not used for the rootfs: the
package still builds, it just has no GPU acceleration.

## What has actually been checked

| Check | Command | Result |
|---|---|---|
| Hardware tool builds, runs | `cc -O2 -Wall -Wextra -o hwprofile tools/hwprofile.c` | 0 warnings; reports "not a PS4" on a PC, as designed |
| Removal rules | `tools/test-chromeos-scan.sh` | 24/24 assertions pass |
| App type-checks | `cc -fsyntax-only -D__ORBIS__ -I$OO/include -isystem $OO/include/orbis pkg/installer/installer/main.c` | pass |
| Shell scripts parse | `bash -n scripts/*.sh`, `sh -n initramfs/functions/55-ps4linux.sh` | pass |
| Dummy kernel package builds | `dpkg-deb --build` | pass |
| Kernel builds | `SB=baikal bash scripts/build-kernel.sh` | pass — `bzImage` 14,251,008 bytes, sha256 `a70b0935…b889`, `HdrS` at 0x202 |
| Mesa builds | `bash scripts/build-mesa.sh` | pass — 25.0.7, 1,470 targets, 0 failures, 42 MB, `LIVERPOOL`/`GLADIUS` present, newest glibc symbol 2.38 |
| Mesa is in the packaged image | unpack `rootfs.tar.zst` from the PKG | pass — 40 files under `/opt/ps4-mesa` plus the glvnd symlinks |
| App compiles | `make APP=install` | pass — `eboot.bin`, 122,432 bytes |
| PKG builds and validates | `WITH_ROOTFS=1 bash scripts/make-pkg.sh`, `PkgTool.Core pkg_validate` | pass — 278,659,072 bytes, 28/28 checks OK, all four assets byte-identical to their sources |
| Package title | read `TITLE` back out of the packaged `param.sfo` | pass — `PS4 Linux` |
| Initramfs handoff is really in the init | unpack the packaged `initramfs.cpio.gz`, read `init` | pass — the block after the base's `mount ... /ps4hdd` calls `ps4linux_boot` |
| Autoload policy is in the packaged initramfs | unpack, read `functions/55-ps4linux.sh` | pass — `ps4l_autoload_policy` present, `bin/zstd` still there |
| Rootfs has a desktop and a login | unpack `rootfs.tar.zst` | pass — `systemd`, `xfce4-session`, `lightdm` (linked as `display-manager.service`), `Xorg`, user `ps4` |

Not checked: installing a PKG on a console, whether radeonsi binds the GPU, and
every hardware behaviour. The package now carries a real kernel, a real initramfs,
a real Debian/XFCE rootfs and the patched Mesa; the one placeholder left is
`ps4linux-loader.bin`, and until that is replaced the package cannot boot.

## Design decisions worth knowing before you change anything

- **Graphics memory is a menu choice, not a file edit.** The loader reads `vram.txt`
  (a plain number in MB) next to the `bzImage`, and that file beats whichever
  payload was launched — which is why we ship one payload path and four numbers
  instead of four payloads. The app writes 1024 MB for the first start
  (installing needs the RAM more than the GPU does) and offers 1024/2048/3072/4096
  from its Graphics memory menu afterwards. The PS4 has a single 8 GB pool: every
  megabyte given to the GPU is taken from system memory.
- **Mesa lives in `/opt`, not in the distro paths.** The PS4 support is a
  device-id and chip-init patch. If it replaced `/usr/lib/.../libGLX_mesa.so.0`,
  the next Debian Mesa update would silently take the GPU away. In `/opt` it
  survives upgrades, and `libglvnd` is pointed at it by name.
- **The loader payload is adopted, not shipped.** It is somebody else's binary,
  rebuilt per firmware, so the package carries a placeholder. Put a current
  payload (`ps4-linux-1gb.bin`, or the `.elf`) in the root of a USB stick or in
  `/data/payloads`; the app copies it next to the kernel as
  `ps4linux-loader.bin` and starts Linux from its own Start Linux entry over
  BinLoader. GoldHEN's payload menu is never opened, and no autoload entry is ever
  written — which is what would make a console restart into Linux on every
  jailbreak.
- **The boot directory cannot be namespaced.** The loader's search path is fixed
  upstream, so we own `/data/linux/boot` explicitly and back up what was there.
  See `docs/LAYOUT.md`.
- **Space is reserved from OrbisOS, not Linux.** Linux's UFS driver writes at
  ~13 MB/s; OrbisOS reaches 60–150 MB/s. The reserve also must settle before
  booting, or the console crashes (measured by the reference project: no picture
  at 32 GB, panic at 64 GB).
- **Never put firmware in the initramfs.** GPU/Wi-Fi firmware is built into the
  kernel; `regulatory.db` there deadlocks the MediaTek driver and takes DHCP down
  with it.
- **Never write a payload autoload entry.** A boot loop is the result. The app
  lists what is armed and can remove it when asked, the boot side can do it under
  the `remove` policy, and `docs/RECOVERY.md` has the escape route. Autoload is
  still available deliberately — it is GoldHEN's setting, not ours; see
  "Using the console as a computer only".

## Licensing

Kernel GPL-2.0 (publish sources and patches), Mesa MIT (publish the patch),
initramfs base GPL-3.0/BSD, OpenOrbis GPL-3.0. Debian packages keep their
copyright files.

**Do not bundle Sony-extracted blobs** — `liverpool_*.bin`, `gladius_*.bin`, or the
EAP HDD key. The loader extracts those from OrbisOS memory at boot; that is what
keeps the release distributable. ChromeOS Flex is not redistributable at all,
which is one more reason this project ships Debian.
