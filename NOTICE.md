# Third-party notices

This project builds on other people's work. Nothing here re-licenses it.

| Component | Used for | Licence |
|---|---|---|
| [OpenOrbis PS4 Toolchain](https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain) | SDK, `PkgTool.Core`, `create-gp4`, `create-fself`, runtime modules | GPL-3.0 |
| [LibOrbisPkg](https://github.com/maxton/LibOrbisPkg) | PKG building (inside `PkgTool.Core`) | GPL-3.0 |
| [Strawberry kernel](https://github.com/rmuxnet/linux) | PS4 kernel trees (`zaebiz/7.1.7-Stable`, `baikal/7.0.8-Stable`) | GPL-2.0 |
| [ps4-linux-loader](https://github.com/ps4-linux/ps4-linux-loader) | Firmware-agnostic kexec loader | see upstream |
| [initramfs-ps4](https://github.com/GattoDev-debug/initramfs-ps4) | Base initramfs that opens the encrypted PS4 drive | see upstream |
| [chromeos-ps4](https://github.com/theJetsetlife/chromeos-ps4) | Installer recipe, reserve/settle logic, ChromeOS removal rules | see upstream |
| [PS4-patched Mesa](https://github.com/rmuxnet) | GPU acceleration on Liverpool/Gladius | MIT (Mesa) plus PS4 patches |
| Debian 13 (trixie) | The distribution itself | DFSG-free |

Firmware blobs (AMD GPU, MediaTek MT7668, Marvell 88W8797/8897) come from
[linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)
and remain under their own terms. They are not in this repository.

## Deliberately not included

- **ChromeOS Flex.** It is not redistributable. This project replaces it rather
  than shipping it.
- **Any Sony code or keys.** The PS4 drive key is read at runtime from the
  console's own kernel memory; nothing of Sony's is stored or redistributed here.
- **The `sce_module` runtime modules and package artwork.** They ship with the
  OpenOrbis toolchain, so the Makefile copies them at build time instead of
  committing binaries.
- **Kernel sources, the Debian rootfs and the disk image.** Built separately;
  far too large for a repository.

## This project's own licence

Not declared yet. The build links against GPL-3.0 components, so the practical
choice is GPL-3.0 or a compatible licence - but that decision is deliberately
left open rather than defaulted.
