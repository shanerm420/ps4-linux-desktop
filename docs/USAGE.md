# Using PS4 Linux

Everything a person needs, in order: what to have ready, how to install, how to
start Linux afterwards, and what to do when something goes wrong.

Nothing in this project has been tested on a console yet. Read
[`docs/TEST-MATRIX.md`](TEST-MATRIX.md) before you trust it with a console you
care about, and read the "before you begin" pages the app shows you.

## 1. What you need

- A **jailbroken PS4** running **GoldHEN**, not v2.4b18.8 (that build does not
  boot the loader). GoldHEN's **BinLoader server** on port 9090 must be enabled.
- **`PS4Linux.pkg`** - the app. It installs Linux and is how you start it from
  then on.
- **A PS4 Linux loader payload** - `ps4-linux-1gb.bin`, or the `.elf`, from the
  loader project. Any VRAM size will do: the app sets that itself. This is the one
  file this project does not ship, because it is somebody else's binary and it is
  rebuilt per firmware generation.
- **A USB stick** if you want to install to USB, or to keep the payload on.
- **A USB keyboard** for the first start, to pick the install target on the TV.

Optional: **`PS4Linux-Remove-ChromeOS.pkg`** if an old ChromeOS-for-PS4 install is
taking up space. It is a separate app and it only removes that.

## 2. Install

1. Copy `PS4Linux.pkg` to a USB stick and install it on the console the usual way
   (the homebrew package installer you already use).
2. Put the loader payload in the **root of a USB stick**, or in
   `/data/payloads` over FTP. Name it something with `linux` in it and end it in
   `.bin` or `.elf`.
3. Launch **PS4 Linux** from the home screen.
4. **Autoload** - if anything is armed, the app lists it and asks whether to remove
   it. Remove it unless you set it on purpose. (See section 5.)
5. Choose **Install Linux**.
6. Read the six "before you begin" pages. **Cancel** on any page changes nothing.
7. Choose where Linux lives:
   - **PS4 drive** - games and saves stay; the space you choose becomes invisible
     to the PS4, and 10 GB always stay free.
   - **USB drive** - that drive is **erased** and Linux lives on it. Faster on an
     SSD, and the PS4 drive is untouched.
8. Choose a size. 32 GB is the recommended starting point.
9. Wait. Files copy first (about a minute), then space is reserved at full drive
   speed, then Linux is installed into it. **Do not power off** while the LED is
   orange or while it says "Finishing writing to the PS4 drive".
10. Confirm **Start Linux**. The console restarts into Linux and finishes the
    install there. The first install takes roughly 15-40 minutes depending on the
    drive.

The app writes `vram.txt` at **1024 MB** for this first start: installing and the
first boot need system memory more than the GPU does.

## 3. First boot

The screen goes to the Debian boot, then a login as user **`ps4`**, password
**`ps4linux`**, and an XFCE desktop.

- **To get back to the PS4:** use **Restart** inside Linux. The console comes back
  up in the PS4 system, exactly as before.
- **Sound and picture** are over HDMI. The DualShock 4 works over USB or Bluetooth.
- **Wi-Fi** is set up with NetworkManager (the network icon in the panel).
- **Software** installs normally: `sudo apt update && sudo apt install ...`,
  Flatpak, Steam. Updates do not need a new PKG. The kernel, the initramfs and the
  loader are pinned and are only changed by a new package, so a bad update cannot
  break the boot path.

If the desktop does not come up, switch to a text console with `Ctrl+Alt+F2` and
see [`docs/RECOVERY.md`](RECOVERY.md).

## 4. Everyday use: the menu

Launching **PS4 Linux** from the PS4 home screen opens a menu. One entry per
category, each with its own submenu. The dialog API has two buttons and no list
control, so a menu is one entry per screen: **Select** opens the entry shown,
**Next** shows the next one. Cancel closes the menu and changes nothing.

| Entry | What it does |
|---|---|
| **Start Linux** | Sends the loader and restarts into Linux. This is the everyday button. |
| **Graphics memory (VRAM)** | Shows the current size, or lets you change it: 1024 / 2048 / 3072 / 4096 MB. |
| **Autoload** | Check what is armed, remove the entry, and set the boot behaviour. |
| **Remove ChromeOS** | Reports what a ChromeOS-for-PS4 install is using, and points at the separate app that removes it. |
| **Recovery** | Writes the rescue flag to a USB stick, and shows the boot-loop steps. |
| **Install Linux** | Only appears when nothing is installed. |

### Graphics memory

The console has **one 8 GB pool** shared by the CPU and the GPU. `2048 MB` of VRAM
means 6 GB of system memory, not 8. The loader reads the number from `vram.txt`
next to the kernel and it overrides whatever the payload was built with, so
changing it is a menu choice - no FTP, no editing files.

- **1024 MB** - until Linux is installed, and for troubleshooting.
- **2048 MB** - the usual desktop choice.
- **3072 / 4096 MB** - heavier graphics, less RAM for programs.

It applies to the next start, including the one you launch straight after.

## 5. Autoload: starting Linux by itself

By default Linux only starts when you press **Start Linux**. If you want the
console to be a computer and nothing else, GoldHEN can start the payload by itself.

**The console still boots into the PS4 system.** Autoload is a GoldHEN feature, so
nothing happens at power-on: you get the normal home screen, games and all. The
payload fires the moment you run GoldHEN, and Linux starts instead.

To turn it on, once Linux starts correctly from the app:

1. The app has already put the real payload at
   `/data/payloads/ps4linux-loader.bin`, with a copy at
   `/data/linux/boot/ps4linux-loader.bin`.
2. In GoldHEN's settings, enable payload autoload and point it at that file. The
   wording and the location differ between builds: some read a folder
   (`/data/GoldHEN/autoload/`), others a list (`/data/GoldHEN/autoload.txt`,
   `/data/bdj_autoload.cfg`, `/data/payloads/autoload.txt`).
3. Run GoldHEN. Going into Linux instead of the payload menu is the confirmation.

### Boot behaviour

**Autoload -> Boot behaviour** decides what a *Linux start* does about an entry
that is still armed:

- **`ask`** (default) - leave it, leave a note, and the app asks on its next
  launch.
- **`remove`** - delete the known autoload files during the boot, so a console that
  reaches Linux cannot loop again.
- **`keep`** - never touch them.

It is stored in `/data/linux/boot/autoload-policy` and read by the initramfs before
it hands over to Linux.

### The way back

**With autoload on, the app cannot help you get out** - it only runs after GoldHEN
loads, and by then the payload has already taken the console. So:

1. Power on and do **not** run the exploit. You are in the normal PS4 system.
2. To remove the entry, either use **Autoload -> Remove the entry** in the app (this
   works when the entry is not currently firing), or load a homebrew enabler that
   does not autoload payloads (NextHEN, PS4HEN Lite, Mira) and delete the entry and
   the payload over FTP.
3. Reboot, run GoldHEN, and confirm the console stays on the home screen.

## 6. If something goes wrong

| What you see | What to do |
|---|---|
| Menu says there is no loader payload | Put a payload on a USB stick or in `/data/payloads`, launch the app again. |
| "The loader could not be started" | GoldHEN's BinLoader (port 9090) is off. Turn it on and try again. |
| Linux stops at a rescue shell | A `ps4linux-recovery` file is on a USB stick. Remove it. |
| Black screen, LED white | Wait a minute, power off by holding the button, start the console, launch the app again - the install resumes. |
| Console restarts over and over | An autoload entry is firing. See the boot-loop section of [`docs/RECOVERY.md`](RECOVERY.md). |
| Desktop does not start | `Ctrl+Alt+F2`, then `systemctl --failed` and `journalctl -b -p err`. |

The rescue shell is always available: put an empty file named `ps4linux-recovery`
in the root of a FAT32 stick (**Recovery -> Rescue flag on a USB stick** writes it
for you) and start Linux. The initramfs stops before touching the image and gives
you a shell, because the loader checks USB first.

## 7. Updating

- **Linux itself:** `sudo apt update && sudo apt full-upgrade`. Normal Debian.
- **The kernel, initramfs and loader:** only change with a new package. That is
  deliberate - they are the boot path.
- **The app:** install the newer `PS4Linux.pkg` over the old one. Your install,
  your image and your files are untouched.

## 8. Removing it

1. Delete the app from the PS4 home screen.
2. Over FTP, delete `/user/app/ps4linux.img` (or reformat the USB drive).
3. Delete `/data/ps4linux/` and the `ps4linux-*` files in `/data/linux/boot` and
   `/data/payloads`.
4. If `/data/ps4linux/backups.txt` lists files that were moved aside, rename them
   back.

Nothing else on the console is affected. Never use "Initialize PS4" to get the
space back - that erases games and saves, and the files above are the only ones
that need to go.

## 9. Building it yourself

See [`docs/BUILD-PKG.md`](BUILD-PKG.md) for the package, and
[ps4-linux-kernel](https://github.com/shanerm420/ps4-linux-kernel) for the kernel
on its own (provenance, `build.sh`, checksums).

## 10. What is still missing

- **Mesa is unpatched Debian.** `/opt/ps4-mesa` is not in the image, so expect
  software rendering until `scripts/build-mesa.sh` has been run on a host with
  Docker.
- **Nothing has run on a console.** Every hardware row in
  [`docs/TEST-MATRIX.md`](TEST-MATRIX.md) is `untested`.
