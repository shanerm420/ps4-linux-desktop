# Architecture

## Stack

| Component | Source | Why this one |
|---|---|---|
| Kernel | `rmuxnet/linux` (Strawberry): `zaebiz/7.1.7-Stable` for Aeolia/Belize, `baikal/7.0.8-Stable` for Baikal | Actively maintained; built-in PS4 GPU firmware; LLVM/ThinLTO; `-march=btver2`. **Two kernels, not one:** upstream keeps Baikal on a separate branch (7.0.8) from Aeolia/Belize (7.1.7), and the prebuilt releases follow the same split. Only the one matching the detected southbridge is built and shipped. |
| Kernel alternative | `feeRnt/ps4-linux-12xx` (6.15.4) | Has the Torus 2 Wi-Fi fixes and MT7668 WIP; use where the Strawberry tree lacks a chip. |
| Loader | `ps4-linux/ps4-linux-loader` | Firmware-agnostic 5.05-14.00, runtime southbridge/Pro detection, `vram.txt`. Unforked on purpose. |
| Initramfs base | `GattoDev-debug/initramfs-ps4` | Already opens the encrypted PS4 HDD container (EAP key, AES-XTS, UFS2 at `/ps4hdd`). |
| Rootfs | Debian 13 (trixie) + XFCE | Security updates without a new PKG; Mesa >= 24.2 for conformant Vulkan 1.3 on GFX6/7; baseline x86-64; DFSG-redistributable. |
| Graphics | PS4-patched Mesa in `/opt/ps4-mesa` | Stock Mesa does not bind Liverpool/Gladius. Kept out of the distro's paths so upgrades cannot replace it. |
| Installer | OpenOrbis C app (this repo) | Same proven recipe as the reference project. |

Why the southbridge must be detected and not inferred from the model: on Slim and
Pro, Belize and Baikal both occur on the same chassis. Only CUH-70xx is pinned to
one board (Belize). `tools/hwprofile` reads PCI `0000:00:14.4` and nothing else.

## Reference console

The target this tree is developed against: **PS4 Pro, Baikal southbridge,
firmware 12.52.** The loader lists 12.50/12.52 as supported, and a ChromeOS
install has already booted on this machine, so the encrypted-drive path (EAP key,
AES-XTS, UFS2 with `--skip 111669149696`) is proven on this exact hardware. Every
other column in `TEST-MATRIX.md` is still untested.

## Boot chain

```
OrbisOS + GoldHEN
 └─ PS4LNX001 (briefing → target → size → reserve → confirm)
     PS4LNX002 removes a ChromeOS install; it is a separate app and the only
     one that deletes user data
     └─ BinLoader 127.0.0.1:9090 → ps4linux-loader.bin
         └─ kexec → kernel + initramfs
             ├─ ps4hdd_open (EAP key, AES-XTS, UFS2 /ps4hdd)
             ├─ recovery flag on USB? → rescue shell
             ├─ locate image (internal file | external device by UUID)
             ├─ blockmap the image, mount it read-write as /
             └─ switch_root → Debian (systemd, lightdm, XFCE)
```

## What runs where

The console has no compiler, no `debootstrap` and no reliable network at install
time, so nothing that needs one runs there:

| Step | Where | Tool |
|---|---|---|
| rootfs (packages, desktop) | host | `debootstrap` + `apt`, into a directory or tarball |
| root image | host | `mke2fs -d` over that tarball, fully allocated, label `*-PS4` |
| kernel + modules | host | cross or native build from the Strawberry tree |
| initramfs | host | `cpio`/`gzip` over the PS4 hook set |
| validation | host | `scripts/check-image.sh`, `tools/test-chromeos-scan.sh` |
| reserve space, copy image, write boot files | console | the PKG installer |

The console side is therefore small and boring, which is what makes it
reviewable: it moves bytes and writes a manifest, and it never formats,
compiles, or resolves dependencies.

## Three update tiers

The requirement "normal updates must work, but must not break boot" is met by
splitting updates into three tiers that cannot interfere:

| Tier | What | How it updates | Can it break boot? |
|---|---|---|---|
| 1. Userland | everything from Debian, Flatpak, Steam | `apt upgrade` / `flatpak update` / Steam | No. The kernel is pinned out; Mesa is in `/opt`. |
| 2. PS4 components | kernel, initramfs, loader, patched Mesa, firmware | "PS4 components update" in the app, from a signed PKG | Only through its own rollback-protected path. |
| 3. Boot partition | `bzImage`, `initramfs`, `bootargs.txt`, `vram.txt` | Tier 2 only; read-only after boot (`ps4-boot-ro.service`) | Deliberately, with a boot counter and previous-slot fallback. |

Why the kernel is not a distro package: a Debian kernel has no PS4 southbridge
support, no built-in Liverpool/Gladius firmware, and no PS4 HDD container driver.
Installing one produces a console that cannot boot. The dummy `linux-image-ps4`
package plus `apt` pin makes that impossible rather than merely discouraged.

Why Mesa lives in `/opt`: the PS4 patch is a device-ID and chip-init patch. If it
replaced `/usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0`, the next Debian Mesa update
would either overwrite it (graphics die) or be blocked (security updates stop).
Two copies plus an ICD JSON sidesteps both. The long-term fix is upstreaming the
IDs; that is worth doing and is noted as such.

## Safety invariants

These are properties of the code, each with a test or a review step:

1. **No PS4 system writes.** The installer only writes `/user/app/ps4linux.img`,
   `/data/ps4linux/*`, `/data/linux/boot/*`, `/data/payloads/ps4linux-loader.bin`.
   It never repartitions, never touches `/user/home`, `/user/app/CUSA*`, `/data/pkg`.
2. **No deletion without an itemised list.** The ChromeOS removal flow prints the
   exact paths and requires two separate confirmations. The rule set is tested by
   `tools/test-chromeos-scan.sh`.
3. **Shared files are never claimed.** `bzImage`, `initramfs.cpio.gz`,
   `bootargs.txt`, `vram.txt` belong to whoever put them there; we back them up
   and record the move (see `docs/LAYOUT.md`).
4. **No autoload, ever.** The app writes no autoload config, and it warns if it
   finds one. Starting Linux requires launching the app and confirming twice
   (once at install, once per boot).
5. **Nothing boots without a confirmation.** After the reserve there is an
   explicit "Start Linux now?" with a "Not now" that leaves the console in
   OrbisOS.
6. **Cancel is always available** and changes nothing until the reserve begins.

## Known risks

- **Aeolia internal storage** is a USB 3 bridge that can fail to re-link after
  OrbisOS shuts down; the reference project's port power-cycle workaround must be
  carried over into this initramfs. Without it every Fat console fails to boot.
- **Fan control** appears to be missing in at least one kernel tree. Sustained
  gaming load on an unverified thermal path is a real hazard; treat gaming as
  gated on fan verification.
- **Memory is unified.** 8 GB total minus the VRAM the loader carves out (1 GB
  typical). Steam plus a browser plus a Proton prefix will not fit comfortably;
  this, not the GPU, bounds gaming.
- **Ethernet and HDMI audio** have conflicting reports upstream. Neither may be
  claimed until tested per unit.
