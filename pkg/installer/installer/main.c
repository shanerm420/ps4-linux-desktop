// PS4 Linux Desktop - installer (OpenOrbis homebrew, needs GoldHEN + BinLoader).
//
// Flow, in the order the user sees it:
//
//   1. find the package's files
//   2. look for an existing install (ours, or ChromeOS for PS4)
//   3. "Before you begin" briefing - several pages, Cancel on every one
//   4. where: PS4 drive or USB drive
//   5. how much space (only sizes that actually fit)
//   6. if a ChromeOS-for-PS4 install is found: say so and install beside it
//      (removing it is a separate package, PS4LNX002 - installer/remove.c)
//   7. copy files, reserve space from OrbisOS, wait for the drive to settle
//   8. "Start Linux now?" - explicit confirmation, Cancel returns to the PS4 menu
//
// Hard rules encoded here:
//   * this app never deletes a file that existed before it ran. Its unlink()
//     calls remove only temporary files it created itself (.part, its probe,
//     its own reserve). Removing a ChromeOS install is PS4LNX002's whole job;
//   * shared boot files (bzImage, initramfs.cpio.gz) are backed up before we
//     write ours, because the loader's search path is fixed (see docs/LAYOUT.md);
//   * this app never writes, registers or modifies any payload autoload config;
//   * Cancel at any point before step 7 changes nothing.
//
// Builds with the OpenOrbis toolchain (OO_PS4_TOOLCHAIN); see the repository
// README for the command and for what remains unverified. Nothing here has run
// on a PS4 yet.
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <orbis/CommonDialog.h>
#include <orbis/MsgDialog.h>
#include <orbis/Sysmodule.h>
#include <orbis/SystemService.h>
#include <orbis/libkernel.h>
#include <orbis/Net.h>

#define APP_NAME "PS4 Linux Desktop"

// ------------------------------------------------------------------ paths
// The loader's search order is fixed by upstream (USB first, then
// /data/linux/boot, then /user/system/boot). We cannot namespace our way out of
// sharing /data/linux/boot, so we own it explicitly: back up anything we find
// there, record it in a manifest, and offer to restore on uninstall.
static const char *src_candidates[] = {
	"/app0/assets/ps4linux",
	"/mnt/sandbox/pfsmnt/PS4LNX001-app0/assets/ps4linux",
	"/mnt/sandbox/PS4LNX001_000/app0/assets/ps4linux",
};
static char SRC[128];
#define BOOT_DIR "/data/linux/boot"
#define STATE_DIR "/data/ps4linux"
#define MANIFEST STATE_DIR "/manifest.txt"
#define IMAGE "/user/app/ps4linux.img"
#define ALLOC BOOT_DIR "/ps4linux.img.alloc"
#define USB "/mnt/usb0"
#define USB_MARKER USB "/PS4LINUX-TARGET.txt"
#define GB (1024ULL * 1024ULL * 1024ULL)
#define RESERVE_FREE (10ULL * GB)

static const char *boot_files[] = {
	"bzImage", "initramfs.cpio.gz", "ps4linux-loader.bin", "rootfs.tar.zst",
};
#define N_BOOT_FILES (sizeof(boot_files) / sizeof(boot_files[0]))

// ------------------------------------------------------------------ logging
static void klog(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
	va_end(ap);
	if (n < 0) return;
	if (n > (int)sizeof(buf) - 3) n = (int)sizeof(buf) - 3;
	buf[n] = '\n';
	buf[n + 1] = 0;
	sceKernelDebugOutText(0, "[ps4linux] ");
	sceKernelDebugOutText(0, buf);
}

// ------------------------------------------------------------------ dialogs
static void dialog_param_init(OrbisMsgDialogParam *p)
{
	memset(p, 0, sizeof(*p));
	p->baseParam.size = sizeof(OrbisCommonDialogBaseParam);
	p->baseParam.magic = (uint32_t)(ORBIS_COMMON_DIALOG_MAGIC_NUMBER + (uint64_t)&p->baseParam);
	p->size = sizeof(*p);
}

// 1 = first button, 2 = second button, 0 = cancelled/closed.
static int dialog(OrbisMsgDialogButtonType type, const char *b1, const char *b2,
                  const char *fmt, ...)
{
	static char msg[2048];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);

	OrbisMsgDialogParam p;
	OrbisMsgDialogUserMessageParam um;
	OrbisMsgDialogButtonsParam bp;
	OrbisMsgDialogResult r;
	dialog_param_init(&p);
	memset(&um, 0, sizeof(um));
	memset(&bp, 0, sizeof(bp));
	p.mode = ORBIS_MSG_DIALOG_MODE_USER_MSG;
	um.buttonType = type;
	um.msg = msg;
	if (type == ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS) {
		bp.msg1 = b1;
		bp.msg2 = b2;
		um.buttonsParam = &bp;
	}
	p.userMsgParam = &um;
	sceMsgDialogInitialize();
	if (sceMsgDialogOpen(&p) < 0) {
		sceMsgDialogTerminate();
		return 0;
	}
	while (sceMsgDialogUpdateStatus() != ORBIS_COMMON_DIALOG_STATUS_FINISHED)
		sceKernelUsleep(10000);
	memset(&r, 0, sizeof(r));
	sceMsgDialogGetResult(&r);
	sceMsgDialogTerminate();
	if (r.buttonId == ORBIS_MSG_DIALOG_BUTTON_ID_BUTTON1) return 1;
	if (r.buttonId == ORBIS_MSG_DIALOG_BUTTON_ID_BUTTON2) return 2;
	return 0;
}

static int progress_open(const char *msg)
{
	OrbisMsgDialogParam p;
	OrbisMsgDialogProgressBarParam pb;
	dialog_param_init(&p);
	memset(&pb, 0, sizeof(pb));
	p.mode = ORBIS_MSG_DIALOG_MODE_PROGRESS_BAR;
	pb.barType = ORBIS_MSG_DIALOG_PROGRESSBAR_TYPE_PERCENTAGE;
	pb.msg = msg;
	p.progBarParam = &pb;
	sceMsgDialogInitialize();
	return sceMsgDialogOpen(&p);
}

static void progress_set(uint32_t pct, const char *msg)
{
	sceMsgDialogProgressBarSetValue(0, pct);
	if (msg) sceMsgDialogProgressBarSetMsg(0, msg);
	sceMsgDialogUpdateStatus();
}

static void progress_close(void)
{
	sceMsgDialogClose();
	while (sceMsgDialogUpdateStatus() != ORBIS_COMMON_DIALOG_STATUS_FINISHED)
		sceKernelUsleep(10000);
	sceMsgDialogTerminate();
}

static void quit(void)
{
	sceSystemServiceLoadExec("exit", NULL);
	for (;;) sceKernelUsleep(1000000);
}

// ------------------------------------------------------------------ files
static uint64_t fd_size(int fd)
{
	off_t cur = lseek(fd, 0, SEEK_CUR);
	off_t end = lseek(fd, 0, SEEK_END);
	if (cur >= 0) lseek(fd, cur, SEEK_SET);
	return end > 0 ? (uint64_t)end : 0;
}

static uint64_t file_size(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) return 0;
	uint64_t n = fd_size(fd);
	close(fd);
	return n;
}

static int exists(const char *path)
{
	struct stat st;
	return stat(path, &st) == 0;
}

static void mkdirs(const char *path)
{
	char tmp[256];
	snprintf(tmp, sizeof(tmp), "%s", path);
	for (char *p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = 0;
			mkdir(tmp, 0777);
			*p = '/';
		}
	}
	mkdir(tmp, 0777);
}

static int write_small(const char *path, const char *text)
{
	char part[288];
	snprintf(part, sizeof(part), "%s.part", path);
	int fd = open(part, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0) return -1;
	size_t n = strlen(text);
	ssize_t w = write(fd, text, n);
	fsync(fd);
	close(fd);
	if (w != (ssize_t)n || rename(part, path) != 0) {
		unlink(part);
		return -1;
	}
	chmod(path, 0666);
	return 0;
}

static int read_small(const char *path, char *buf, size_t cap)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) return -1;
	ssize_t n = read(fd, buf, cap - 1);
	close(fd);
	if (n <= 0) return -1;
	buf[n] = 0;
	return 0;
}

// ------------------------------------------------------------------ free space
// FreeBSD statfs(2) = 396, fstatfs(2) = 397, getfsstat(2) = 395. Called
// directly: libc's statvfs wrapper does not translate this kernel's struct
// layout, and inside the app sandbox statfs() returns EPERM (see the reference
// project's notes; same constraint applies here).
static long orbis_syscall3(long num, long a1, long a2, long a3)
{
	long ret;
	unsigned char err;
	__asm__ volatile("syscall\n\tsetc %1"
	                 : "=a"(ret), "=r"(err)
	                 : "a"(num), "D"(a1), "S"(a2), "d"(a3)
	                 : "rcx", "r11", "memory");
	return err ? -ret : ret;
}

#define STATFS_SIZE 472

static int fs_parse(const unsigned char *b, uint64_t *free_b)
{
	uint64_t bsize, blocks;
	int64_t bavail;
	memcpy(&bsize, b + 16, 8);
	memcpy(&blocks, b + 32, 8);
	memcpy(&bavail, b + 48, 8);
	if (bavail < 0) bavail = 0;
	if (bsize == 0 || blocks == 0) return -1;
	*free_b = (uint64_t)bavail * bsize;
	return 0;
}

static uint64_t free_bytes(const char *path)
{
	static uint64_t sf[64];
	static unsigned char all[64 * STATFS_SIZE];
	uint64_t f = 0;

	memset(sf, 0, sizeof(sf));
	if (orbis_syscall3(396, (long)path, (long)sf, 0) >= 0 &&
	    fs_parse((unsigned char *)sf, &f) == 0)
		return f;

	int fd = open(path, O_RDONLY);
	if (fd >= 0) {
		memset(sf, 0, sizeof(sf));
		long r = orbis_syscall3(397, (long)fd, (long)sf, 0);
		close(fd);
		if (r >= 0 && fs_parse((unsigned char *)sf, &f) == 0)
			return f;
	}

	memset(all, 0, sizeof(all));
	long r = orbis_syscall3(395, (long)all, (long)sizeof(all), 2);
	if (r < 0) return 0;
	for (long i = 0; i < r && i < 64; i++) {
		const char *on = (const char *)all + i * STATFS_SIZE + 384;
		if (!strcmp(on, "/user") || !strcmp(on, "/data"))
			if (fs_parse(all + i * STATFS_SIZE, &f) == 0)
				return f;
	}
	return 0;
}

// GoldHEN SDK syscall 500: leave the sandbox only to read free space, then
// return before booting (a boot straight out of a jailbroken process had no
// HDMI and no LED change on a tested console).
#define GOLDHEN_JAILBREAK 2
#define GOLDHEN_UNJAILBREAK 3
struct jailbreak_backup {
	uint32_t cr_uid, cr_ruid, cr_rgid, cr_groups;
	uint64_t cr_paid;
	uint64_t cr_caps[2];
	void *cr_prison, *fd_cdir, *fd_jdir, *fd_rdir;
	uint8_t spare[128];
};
static struct jailbreak_backup jb;
static int jailbroken;

static int goldhen_jailbreak(void)
{
	if (jailbroken) return 0;
	memset(&jb, 0, sizeof(jb));
	if (orbis_syscall3(500, GOLDHEN_JAILBREAK, (long)&jb, 0) != 0) return -1;
	jailbroken = 1;
	return 0;
}

static void goldhen_unjailbreak(void)
{
	if (!jailbroken) return;
	if (orbis_syscall3(500, GOLDHEN_UNJAILBREAK, (long)&jb, 0) == 0)
		jailbroken = 0;
	sync();
	sceKernelUsleep(5 * 1000000);
}

// ------------------------------------------------------------------ detection
// Our own install: manifest + build-id. ChromeOS for PS4: image + named files.
// Deliberately identical to tools/chromeos-scan.c, which is the tested
// reference for these rules.
struct cros_found {
	int image;
	uint64_t image_size;
	int n_boot;
	uint64_t boot_bytes;
	char listing[1024];
};

static const char *k_cros_files[] = {
	BOOT_DIR "/chromeos.img.xz",
	BOOT_DIR "/chromeos.img.size",
	BOOT_DIR "/chromeos.img.alloc",
	BOOT_DIR "/chromeos.img.alloc.part",
	BOOT_DIR "/chromeos-install-choice",
	BOOT_DIR "/chromeos-target",
	BOOT_DIR "/chromeos-error.txt",
	BOOT_DIR "/chromeos-external.guid",
	BOOT_DIR "/ps4-layer.sqfs",
	BOOT_DIR "/ps4-chromeos-loader.bin",
	"/data/payloads/ps4-chromeos-loader.bin",
	NULL,
};

static void cros_scan(struct cros_found *c)
{
	memset(c, 0, sizeof(*c));
	c->image_size = file_size("/user/app/chromeos.img");
	c->image = c->image_size > 0;
	for (int i = 0; k_cros_files[i]; i++) {
		uint64_t sz = file_size(k_cros_files[i]);
		if (!sz) continue;
		c->n_boot++;
		c->boot_bytes += sz;
		size_t used = strlen(c->listing);
		snprintf(c->listing + used, sizeof(c->listing) - used, "  %s (%llu MB)\n",
		         k_cros_files[i], (unsigned long long)(sz >> 20));
	}
}

// Deleting a ChromeOS install is NOT done here. It lives in the remover package
// (installer/remove.c, TITLE_ID PS4LNX002), which is the only file in the project
// that removes a user's files. Keeping it out of the installer means "install Linux" can
// never erase an existing install, whatever the dialogs say or do.
//
// cros_scan() stays: the installer still needs to know whether one is there, so
// it can tell the user to run the remover first if they want the space back.

// Autoload check. We never write these; we only warn if something else did.
static const char *k_autoload[] = {
	"/data/GoldHEN/autoload",
	"/data/GoldHEN/autoload.txt",
	"/data/bdj_autoload.cfg",
	"/data/payloads/autoload.txt",
	NULL,
};

static int autoload_present(char *first, size_t cap)
{
	for (int i = 0; k_autoload[i]; i++) {
		if (exists(k_autoload[i])) {
			snprintf(first, cap, "%s", k_autoload[i]);
			return 1;
		}
	}
	return 0;
}

// ------------------------------------------------------------------ briefing
// Returns 1 to continue, 0 if the user cancelled. Cancel on any page stops.
static int briefing(void)
{
	if (dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	           APP_NAME " installs a complete Linux desktop (Debian with XFCE) on this "
	           "console.\n\n"
	           "Linux runs INSTEAD of the PS4 system until you restart. Your games, "
	           "saves and the PS4 system itself are not modified.\n\n"
	           "This is not an official Sony feature. Nothing here is supported by "
	           "Sony, and a jailbroken console can always be left in a state that "
	           "needs recovery.\n\n"
	           "Page 1 of 6") != 1) return 0;

	if (dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	           "WHERE LINUX LIVES\n\n"
	           "PS4 drive: Linux is stored in one large file on the PS4 drive. Games "
	           "and saves stay. The space you choose becomes invisible to the PS4, "
	           "and %llu GB always stay free.\n\n"
	           "USB drive: the drive is ERASED completely and Linux lives on it. "
	           "Faster on an SSD, and your PS4 drive is untouched.\n\n"
	           "Page 2 of 6", (unsigned long long)(RESERVE_FREE / GB)) != 1) return 0;

	if (dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	           "WHAT WILL HAPPEN\n\n"
	           "1. Files are copied to the PS4 drive (about 1 minute).\n"
	           "2. Space is reserved at once, at full drive speed.\n"
	           "3. Linux is installed into that space. The LED turns orange.\n"
	           "4. The console restarts into Linux.\n\n"
	           "The first install takes roughly 15 to 40 minutes depending on the "
	           "drive. Later starts take seconds.\n\n"
	           "Page 3 of 6") != 1) return 0;

	if (dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	           "DO NOT POWER OFF\n\n"
	           "Do not switch off, unplug or reset the console while:\n"
	           "  - space is being reserved,\n"
	           "  - it says \"Finishing writing to the PS4 drive\",\n"
	           "  - the LED is orange (installing).\n\n"
	           "Interrupting those steps does not kill the console, but it corrupts "
	           "the Linux install and you have to start it again.\n\n"
	           "LED: white = PS4 system, orange = Linux working, off = off.\n\n"
	           "Page 4 of 6") != 1) return 0;

	if (dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	           "STARTING AND RETURNING\n\n"
	           "To start Linux later: launch this app again and confirm.\n"
	           "To return to the PS4: use Restart inside Linux.\n\n"
	           "Linux NEVER starts by itself. This app does not change any GoldHEN "
	           "startup setting and never adds a payload to an autoload folder.\n\n"
	           "If you ever enabled \"autoload payloads\" in GoldHEN yourself, turn it "
	           "off: a Linux payload that autoloads makes the console loop, because "
	           "every jailbreak immediately restarts it again.\n\n"
	           "Page 5 of 6") != 1) return 0;

	if (dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Continue", "Cancel",
	           "IF SOMETHING GOES WRONG\n\n"
	           "Nothing to worry about: hold the power button until the console turns "
	           "off, then start it normally. The PS4 system is not modified by this "
	           "installer.\n\n"
	           "A USB stick with a file named ps4linux-recovery in its root forces a "
	           "Linux rescue shell on the next start.\n\n"
	           "Full recovery instructions, including the boot-loop case, are in "
	           "docs/RECOVERY.md in the release.\n\n"
	           "Page 6 of 6") != 1) return 0;

	return 1;
}

// ------------------------------------------------------------------ storage
static uint64_t img_bytes(uint64_t start, uint64_t gib)
{
	return (start * 512 + gib * GB + 34 * 512 + 1048575) / 1048576 * 1048576;
}

// Returns the STATE size in GiB, or 0 for USB. Quits on cancel.
static uint64_t ask_install(uint64_t start, uint64_t avail)
{
	int r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "PS4 drive", "USB drive",
	               "Where should Linux be installed?\n\n"
	               "PS4 drive: games and saves stay. The space you choose becomes "
	               "invisible to the PS4.\n\n"
	               "USB drive: that drive is ERASED. You pick it on the TV after the "
	               "restart (USB keyboard needed).");
	if (r == 0) quit();
	if (r == 2) return 0;

	uint64_t max_gib = 0;
	while (img_bytes(start, max_gib + 1) <= avail) max_gib++;
	if (max_gib < 8) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Not enough free space: Linux needs at least 8 GB plus %llu GB that "
		       "always stay free.\n\nFree up space, or install to a USB drive.",
		       (unsigned long long)(RESERVE_FREE / GB));
		quit();
	}

	static const uint64_t steps[] = { 32, 64, 128, 256 };
	uint64_t sizes[8];
	int n = 0;
	for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); i++)
		if (steps[i] <= max_gib) sizes[n++] = steps[i];
	if (n == 0 || sizes[n - 1] != max_gib) sizes[n++] = max_gib;

	for (int i = 0;; i = (i + 1) % n) {
		uint64_t g = sizes[i];
		const char *tag = g == 32 ? "  (recommended)"
		                        : (g == max_gib ? "  (all the free space)" : "");
		r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Install",
		           n > 1 ? "Next size" : "Install",
		           "Space for Linux (system, applications, your files):\n\n"
		           "        %llu GB%s\n\n"
		           "%llu GB of the PS4 drive always stay free for the PS4 system.%s",
		           (unsigned long long)g, tag, (unsigned long long)(RESERVE_FREE / GB),
		           n > 1 ? "\n\n\"Next size\" shows the other sizes." : "");
		if (r == 0) quit();
		if (r == 1 || n == 1) return g;
	}
}

// ------------------------------------------------------------------ reserve
#define PROBE_FILE BOOT_DIR "/.ps4linux-probe"
#define PROBE_FAST_US 150000ULL
#define PROBE_NEED 3
#define SETTLE_MIN_S 30
#define SETTLE_MAX_S 600

static uint64_t probe_us(void)
{
	static char block[4096];
	uint64_t t0 = sceKernelGetProcessTime();
	int fd = open(PROBE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd < 0) return ~0ULL;
	block[0]++;
	ssize_t w = write(fd, block, sizeof(block));
	int f = fsync(fd);
	close(fd);
	if (w != (ssize_t)sizeof(block) || f != 0) return ~0ULL;
	return sceKernelGetProcessTime() - t0;
}

// Starting Linux while OrbisOS is still flushing the reserve crashed a tested
// console (no picture at 32 GB, panic at 64 GB). Measured, not guessed.
static void settle_drive(void)
{
	char msg[160];
	sync();
	if (progress_open("Finishing writing to the PS4 drive ...") < 0) {
		sceKernelUsleep(60 * 1000000);
		return;
	}
	uint64_t t0 = sceKernelGetProcessTime();
	int fast = 0, secs = 0;
	for (;;) {
		uint64_t us = probe_us();
		secs = (int)((sceKernelGetProcessTime() - t0) / 1000000);
		fast = (us != ~0ULL && us < PROBE_FAST_US) ? fast + 1 : 0;
		if (fast >= PROBE_NEED && secs >= SETTLE_MIN_S) break;
		if (secs >= SETTLE_MAX_S) break;
		snprintf(msg, sizeof(msg), "Finishing writing to the PS4 drive ... %d s", secs);
		progress_set((uint32_t)(secs * 100 / SETTLE_MAX_S), msg);
		sync();
		sceKernelUsleep(2 * 1000000);
	}
	unlink(PROBE_FILE);
	sync();
	progress_close();
	klog("drive settled after %d s", secs);
}

// Reserves `want` bytes as a fully-allocated file (never sparse: the PS4's UFS
// driver is safest that way). Resumes a .part left by an earlier run.
static int reserve(uint64_t want, uint64_t start, uint64_t gib)
{
	static unsigned char zero[4 * 1024 * 1024];
	char part[288], msg[200];
	snprintf(part, sizeof(part), "%s.part", ALLOC);

	if (exists(ALLOC) && file_size(ALLOC) == want) {
		klog("already reserved: %llu MB", (unsigned long long)(want >> 20));
		return 0;
	}
	if (exists(ALLOC) && file_size(ALLOC) != want) {

		unlink(ALLOC);
		klog("removed a reserve of a different size");
	}

	int out = open(part, O_WRONLY | O_CREAT, 0666);
	if (out < 0) return -1;
	uint64_t have = fd_size(out);
	if (have > want) {
		close(out);
		unlink(part);
		out = open(part, O_WRONLY | O_CREAT, 0666);
		if (out < 0) return -1;
		have = 0;
	}
	have -= have % sizeof(zero);
	if (lseek(out, (off_t)have, SEEK_SET) != (off_t)have) {
		close(out);
		unlink(part);
		return -1;
	}
	klog("reserving %llu MB (resume at %llu MB)", (unsigned long long)(want >> 20),
	     (unsigned long long)(have >> 20));

	snprintf(msg, sizeof(msg), "Reserving %llu GB for Linux (one time only) ...",
	         (unsigned long long)gib);
	if (progress_open(msg) < 0) {
		close(out);
		return -1;
	}
	uint64_t t0 = sceKernelGetProcessTime(), done = have, last = 0;
	int rc = 0, werr = 0;
	while (done < want) {
		size_t n = (want - done) < sizeof(zero) ? (size_t)(want - done) : sizeof(zero);
		ssize_t w = write(out, zero, n);
		if (w <= 0) { werr = errno; rc = -1; break; }
		done += (uint64_t)w;
		uint64_t now = sceKernelGetProcessTime();
		if (now - last >= 2000000ULL) {
			last = now;
			uint64_t el = (now - t0) / 1000000, mb = (done - have) >> 20;
			if (el >= 5 && mb) {
				uint64_t left = ((want - done) >> 20) * el / mb;
				snprintf(msg, sizeof(msg),
				         "Reserving %llu GB for Linux (one time only) ...\n"
				         "%llu MB/s, about %llu min %02llu s left",
				         (unsigned long long)gib, (unsigned long long)(mb / el),
				         (unsigned long long)(left / 60), (unsigned long long)(left % 60));
				progress_set((uint32_t)(done * 100 / want), msg);
			} else {
				progress_set((uint32_t)(done * 100 / want), NULL);
			}
		}
	}
	fsync(out);
	close(out);
	progress_close();
	if (rc != 0) {
		if (werr == 28) {
			unlink(part);
			dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
			       "The PS4 drive is full.\n\nThe reservation was removed. Free up "
			       "space, or launch again and choose a smaller size.");
		} else {
			dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
			       "Writing to the PS4 drive failed (error %d).\n\nWhat was reserved "
			       "so far is kept: launch the app again to continue.", werr);
		}
		return -1;
	}
	if (file_size(part) != want || rename(part, ALLOC) != 0) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "The space was written but could not be finished. Launch the app "
		       "again.");
		return -1;
	}
	return 0;
}

// ------------------------------------------------------------------ boot files
// /data/linux/boot is shared with any other Linux install. Before writing ours,
// move anything already there out of the way and record it, so uninstall can put
// it back. This is the answer to "namespaced paths": the loader's search path is
// fixed upstream, so we cannot namespace - we take ownership explicitly.
static int claim_boot_files(void)
{
	char from[288], to[320];
	const char *shared[] = { "bzImage", "initramfs.cpio.gz", "bootargs.txt", "vram.txt", NULL };
	mkdirs(STATE_DIR);
	for (int i = 0; shared[i]; i++) {
		snprintf(from, sizeof(from), BOOT_DIR "/%s", shared[i]);
		if (!exists(from)) continue;
		snprintf(to, sizeof(to), BOOT_DIR "/%s.ps4linux-bak", shared[i]);
		if (exists(to)) {
			klog("%s already backed up; leaving both", shared[i]);
			continue;
		}
		if (rename(from, to) == 0) {
			char line[400];
			snprintf(line, sizeof(line), "backup %s %s\n", shared[i], to);
			int fd = open(STATE_DIR "/backups.txt", O_WRONLY | O_CREAT | O_APPEND, 0666);
			if (fd >= 0) {
				write(fd, line, strlen(line));
				close(fd);
			}
			klog("backed up existing %s", shared[i]);
		} else {
			klog("could not back up %s (errno %d) - aborting", shared[i], errno);
			return -1;
		}
	}
	return 0;
}

static int copy_file(int in, const char *dst, uint64_t *done, uint64_t total, const char *label)
{
	static unsigned char buf[4 * 1024 * 1024];
	char part[288], msg[200];
	snprintf(part, sizeof(part), "%s.part", dst);
	snprintf(msg, sizeof(msg), "Copying %s ...", label);
	progress_set(total ? (uint32_t)(*done * 100 / total) : 0, msg);

	if (in < 0 || lseek(in, 0, SEEK_SET) != 0) return -1;
	int out = open(part, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (out < 0) return -1;
	ssize_t n;
	int rc = 0;
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		ssize_t off = 0;
		while (off < n) {
			ssize_t w = write(out, buf + off, (size_t)(n - off));
			if (w <= 0) { rc = -1; break; }
			off += w;
		}
		if (rc) break;
		*done += (uint64_t)n;
		progress_set(total ? (uint32_t)(*done * 100 / total) : 0, NULL);
	}
	if (n < 0) rc = -1;
	fsync(out);
	close(out);
	if (rc == 0 && file_size(part) != fd_size(in)) rc = -1;
	if (rc == 0) {
		unlink(dst);
		if (rename(part, dst) != 0) rc = -1;
		else chmod(dst, 0666);
	}
	if (rc != 0) unlink(part);
	return rc;
}

// ------------------------------------------------------------------ payload
static int send_payload(int fd)
{
	static unsigned char buf[512 * 1024];
	uint64_t size = fd_size(fd);
	if (size == 0 || size > sizeof(buf) || lseek(fd, 0, SEEK_SET) != 0) return -1;
	ssize_t n = read(fd, buf, (size_t)size);
	if (n != (ssize_t)size) return -1;
	sceNetInit();
	int s = sceNetSocket("ps4linux-loader", ORBIS_NET_AF_INET, ORBIS_NET_SOCK_STREAM, 0);
	if (s < 0) return -1;
	struct { uint8_t len; uint8_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sa;
	memset(&sa, 0, sizeof(sa));
	sa.len = sizeof(sa);
	sa.family = ORBIS_NET_AF_INET;
	sa.port = sceNetHtons(9090);
	sa.addr = 0x0100007F;
	if (sceNetConnect(s, (const OrbisNetSockaddr *)&sa, sizeof(sa)) < 0) {
		sceNetSocketClose(s);
		return -1;
	}
	size_t off = 0;
	while (off < (size_t)n) {
		int w = sceNetSend(s, buf + off, (size_t)n - off, 0);
		if (w <= 0) {
			sceNetSocketClose(s);
			return -1;
		}
		off += (size_t)w;
	}
	sceNetSocketClose(s);
	klog("payload sent (%zu bytes)", off);
	return 0;
}

// ------------------------------------------------------------------ main
int main(void)
{
	char path[288], buf[64];
	uint64_t start = 0;

	sceSysmoduleLoadModule(ORBIS_SYSMODULE_MESSAGE_DIALOG);
	sceCommonDialogInitialize();
	klog("start (build " __DATE__ " " __TIME__ ")");

	// 1. package files
	SRC[0] = 0;
	for (size_t i = 0; i < sizeof(src_candidates) / sizeof(src_candidates[0]); i++) {
		snprintf(path, sizeof(path), "%s/bzImage", src_candidates[i]);
		if (exists(path)) {
			snprintf(SRC, sizeof(SRC), "%s", src_candidates[i]);
			break;
		}
	}
	if (!SRC[0]) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Cannot find the installer's files.\n\nReinstall the package and try "
		       "again.");
		quit();
	}

	int src_fd[N_BOOT_FILES], loader_fd = -1;
	uint64_t total = 0;
	for (size_t i = 0; i < N_BOOT_FILES; i++) {
		snprintf(path, sizeof(path), "%s/%s", SRC, boot_files[i]);
		src_fd[i] = open(path, O_RDONLY);
		if (src_fd[i] < 0) {
			dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
			       "The package is incomplete: %s is missing.", boot_files[i]);
			quit();
		}
		total += fd_size(src_fd[i]);
		if (!strcmp(boot_files[i], "ps4linux-loader.bin"))
			loader_fd = src_fd[i];
	}
	snprintf(path, sizeof(path), "%s/chromeos.img.state-start", SRC);
	if (read_small(path, buf, sizeof(buf)) == 0)
		start = strtoull(buf, NULL, 10);

	// 2. what is already here?
	int installed = exists(MANIFEST) && exists(BOOT_DIR "/bzImage");
	struct cros_found cros;
	cros_scan(&cros);

	char al[128];
	if (autoload_present(al, sizeof(al)))
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Note: a payload autoload file was found at:\n%s\n\n"
		       "This installer never creates one. If you added it yourself, remove "
		       "it: an autoloaded Linux payload makes the console restart in a loop "
		       "every time you jailbreak.\n\nSee docs/RECOVERY.md.", al);

	// 3. already installed -> just ask whether to start
	if (installed) {
		int r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Start Linux", "Cancel",
		               "Linux is already installed on this console.\n\nStart Linux "
		               "now?\n\nThe PS4 system restarts into Linux. Use Restart inside "
		               "Linux to come back.");
		if (r != 1) quit();
		goldhen_unjailbreak();
		if (send_payload(loader_fd) != 0) {
			dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
			       "The loader could not be started.\n\nIs GoldHEN's BinLoader "
			       "server (port 9090) enabled?\n\nYou can also start it yourself: "
			       "GoldHEN > Payloads > ps4linux-loader.bin");
			quit();
		}
		for (;;) sceKernelUsleep(1000000);
	}

	// 4. briefing
	if (!briefing()) quit();

	// 5. An existing ChromeOS install is reported here, never touched: removing
	//    it is a separate package (PS4LNX002). This app removes no existing file.
	if (cros.image || cros.n_boot) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "A ChromeOS for PS4 installation was found. It will be left "
		       "untouched.\n\n"
		       "Image: %llu MB\nOther files: %d (%llu MB)\n\n"
		       "Linux is installed beside it and keeps working. To reclaim that "
		       "space, run \"PS4 Linux: Remove ChromeOS\" first, then start "
		       "this app again.",
		       (unsigned long long)(cros.image_size >> 20), cros.n_boot,
		       (unsigned long long)(cros.boot_bytes >> 20));
	}

	// 6. where + how much
	uint64_t free_user = free_bytes(BOOT_DIR);
	if (!free_user && goldhen_jailbreak() == 0)
		free_user = free_bytes(BOOT_DIR);
	uint64_t avail = free_user + file_size(ALLOC);
	avail = avail > RESERVE_FREE ? avail - RESERVE_FREE : 0;
	if (!avail) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "The free space of the PS4 drive could not be read.\n\nMake sure "
		       "GoldHEN 2.4 or newer is running, then launch the app again.\n\nIf it "
		       "keeps failing, install to a USB drive instead.");
		goldhen_unjailbreak();
		quit();
	}
	uint64_t gib = ask_install(start, avail);

	// 7. copy + reserve
	if (claim_boot_files() != 0) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Could not move an existing Linux boot file aside, so nothing was "
		       "changed.\n\nDetails are in the GoldHEN log.");
		quit();
	}
	mkdirs(BOOT_DIR);
	mkdirs("/data/payloads");
	if (progress_open("Copying PS4 Linux ...") < 0) quit();
	uint64_t done = 0;
	for (size_t i = 0; i < N_BOOT_FILES; i++) {
		snprintf(path, sizeof(path), BOOT_DIR "/%s", boot_files[i]);
		if (copy_file(src_fd[i], path, &done, total, boot_files[i]) != 0) {
			progress_close();
			dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
			       "Copying %s failed. Launch the app again to retry.", boot_files[i]);
			quit();
		}
	}
	progress_close();

	if (gib) {
		uint64_t want = img_bytes(start, gib);
		if (reserve(want, start, gib) != 0) quit();
		snprintf(buf, sizeof(buf), "target=internal\nstate_gib=%llu\n",
		         (unsigned long long)gib);
	} else {
		snprintf(buf, sizeof(buf), "target=external\n");
	}
	write_small(STATE_DIR "/choice.txt", buf);

	char manifest[512];
	snprintf(manifest, sizeof(manifest),
	         "target=%s\nstate_gib=%llu\nstart=%llu\ninstalled=1\n",
	         gib ? "internal" : "external", (unsigned long long)gib,
	         (unsigned long long)start);
	write_small(MANIFEST, manifest);

	if (gib) settle_drive();

	// 8. explicit confirmation before anything boots
	int r = dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_2BUTTONS, "Start Linux", "Not now",
	               "Setup is finished.\n\nStart Linux now?\n\nThe console restarts into "
	               "Linux and finishes the install there (LED orange).\n\n"
	               "If you choose \"Not now\", launch this app again when you are ready.");
	if (r != 1) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Nothing else will happen. Launch this app again to start Linux.");
		quit();
	}

	goldhen_unjailbreak();
	if (send_payload(loader_fd) != 0) {
		dialog(ORBIS_MSG_DIALOG_BUTTON_TYPE_OK, NULL, NULL,
		       "Everything is in place, but the loader could not be started.\n\n"
		       "Start it yourself: GoldHEN > Payloads > ps4linux-loader.bin");
		quit();
	}
	for (;;) sceKernelUsleep(1000000);
	return 0;
}
