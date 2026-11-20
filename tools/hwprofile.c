// ps4-hwprofile - report what the running Linux kernel actually detects on a PS4.
//
// Design rule: this tool never guesses. Every line is either read from the kernel
// (cpuid-derived /proc/cpuinfo, sysfs, /proc/asound) or printed as "unknown" with a
// note about what evidence would settle it. It never infers the southbridge from the
// console's marketing model, and never claims a CPU feature that CPUID does not have.
//
// Build: cc -O2 -Wall -Wextra -o hwprofile hwprofile.c
// Usage: ./hwprofile [--json]

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXF 256

static int g_json;

// ------------------------------------------------------------------ helpers

static int slurp(const char *path, char *buf, size_t cap)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	size_t n = fread(buf, 1, cap - 1, f);
	fclose(f);
	buf[n] = 0;
	while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' '))
		buf[--n] = 0;
	return 0;
}

static int exists(const char *path)
{
	return access(path, F_OK) == 0;
}

// Basename of the symlink target of path (e.g. the driver bound to a device).
static void link_base(const char *path, char *out, size_t cap)
{
	char buf[512];
	out[0] = 0;
	ssize_t n = readlink(path, buf, sizeof(buf) - 1);
	if (n <= 0)
		return;
	buf[n] = 0;
	const char *b = strrchr(buf, '/');
	snprintf(out, cap, "%.*s", (int)(cap - 1), b ? b + 1 : buf);
}

// Iterate a directory of device dirs and call cb for each entry name.
typedef void (*ent_cb)(const char *name, void *ud);
static int for_each(const char *dir, ent_cb cb, void *ud)
{
	DIR *d = opendir(dir);
	if (!d)
		return -1;
	struct dirent *e;
	int n = 0;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		cb(e->d_name, ud);
		n++;
	}
	closedir(d);
	return n;
}

// ------------------------------------------------------------------ cpuinfo

struct cpu {
	char vendor[32];
	char model_name[128];
	int family, model, stepping, cores, siblings;
	char flags[4096];
	int nproc;
};

static void parse_cpuinfo(struct cpu *c)
{
	memset(c, 0, sizeof(*c));
	FILE *f = fopen("/proc/cpuinfo", "r");
	if (!f)
		return;
	char line[8192];
	// Keys must be matched EXACTLY, not by prefix: "model" is a prefix of
	// "model name", and a strncmp("model", 5) therefore parses the brand
	// string as the CPU model number. That is how an earlier version of this
	// tool reported model 0x13 on a machine whose real model is 0x01.
	int have_vendor = 0;
	while (fgets(line, sizeof(line), f)) {
		char *colon = strchr(line, ':');
		if (!colon)
			continue;
		*colon = 0;
		char *key = line;
		char *end = key + strlen(key);
		while (end > key && (end[-1] == ' ' || end[-1] == '\t'))
			*--end = 0;
		const char *val = colon + 1;
		while (*val == ' ' || *val == '\t')
			val++;

		if (!strcmp(key, "processor"))
			c->nproc++;
		else if (!strcmp(key, "vendor_id") && !have_vendor) {
			snprintf(c->vendor, sizeof(c->vendor), "%.31s", val);
			have_vendor = 1;
		} else if (!strcmp(key, "model name") && !c->model_name[0]) {
			snprintf(c->model_name, sizeof(c->model_name), "%s", val);
		} else if (!strcmp(key, "cpu family"))
			c->family = atoi(val);
		else if (!strcmp(key, "model"))
			c->model = atoi(val);
		else if (!strcmp(key, "stepping"))
			c->stepping = atoi(val);
		else if (!strcmp(key, "cpu cores"))
			c->cores = atoi(val);
		else if (!strcmp(key, "siblings"))
			c->siblings = atoi(val);
		else if (!strcmp(key, "flags") && !c->flags[0])
			snprintf(c->flags, sizeof(c->flags), "%s", val);
	}
	fclose(f);
}

static int has_flag(const struct cpu *c, const char *flag)
{
	size_t n = strlen(flag);
	const char *p = c->flags;
	while ((p = strstr(p, flag))) {
		int left = (p == c->flags) || isspace((unsigned char)p[-1]);
		int right = (p[n] == 0) || isspace((unsigned char)p[n]);
		if (left && right)
			return 1;
		p += n;
	}
	return 0;
}

// ------------------------------------------------------------------ pci

struct pcidev {
	char addr[32];
	char vendor[16];
	char device[16];
	char cls[16];
	char driver[64];
};

static struct pcidev g_pci[MAXF];
static int g_npci;

static void pci_cb(const char *name, void *ud)
{
	(void)ud;
	if (g_npci >= MAXF)
		return;
	struct pcidev *d = &g_pci[g_npci];
	char path[512], buf[64];
	memset(d, 0, sizeof(*d));
	snprintf(d->addr, sizeof(d->addr), "%s", name);
	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vendor", name);
	if (slurp(path, buf, sizeof(buf)) == 0)
		snprintf(d->vendor, sizeof(d->vendor), "%.15s", buf + (buf[0] == '0' && buf[1] == 'x' ? 2 : 0));
	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/device", name);
	if (slurp(path, buf, sizeof(buf)) == 0)
		snprintf(d->device, sizeof(d->device), "%.15s", buf + (buf[0] == '0' && buf[1] == 'x' ? 2 : 0));
	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/class", name);
	if (slurp(path, buf, sizeof(buf)) == 0)
		snprintf(d->cls, sizeof(d->cls), "%.15s", buf + (buf[0] == '0' && buf[1] == 'x' ? 2 : 0));
	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/driver", name);
	link_base(path, d->driver, sizeof(d->driver));
	g_npci++;
}

static int class_is(const struct pcidev *d, unsigned prefix)
{
	unsigned v = 0;
	sscanf(d->cls, "%x", &v);
	return (v >> 8) == prefix;   // 0x03 = display, 0x04 = multimedia, 0x0c = serial bus
}

// ------------------------------------------------------------------ detection

// Definitive PS4 evidence: the ps4-ccp driver exposes /sys/firmware/ps4 (it also
// publishes the EAP HDD key there). Module names are secondary evidence.
static int ps4_evidence(char *why, size_t cap)
{
	if (exists("/sys/firmware/ps4")) {
		snprintf(why, cap, "/sys/firmware/ps4 present (ps4-ccp driver)");
		return 2;
	}
	static const char *mods[] = { "ps4_ccp", "xhci_aeolia", "ps4_bridge", "snd_ps4",
				      "mts", "baikal", NULL };
	char path[256], buf[512];
	for (int i = 0; mods[i]; i++) {
		snprintf(path, sizeof(path), "/sys/module/%s", mods[i]);
		if (exists(path)) {
			snprintf(why, cap, "kernel module %s loaded", mods[i]);
			return 1;
		}
	}
	snprintf(path, sizeof(path), "/sys/bus/pci/drivers");
	DIR *d = opendir(path);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (strstr(e->d_name, "ps4") || strstr(e->d_name, "aeolia") ||
			    strstr(e->d_name, "baikal")) {
				snprintf(why, cap, "PCI driver %.200s registered", e->d_name);
				closedir(d);
				return 1;
			}
		}
		closedir(d);
	}
	if (exists("/proc/device-tree")) {
		if (slurp("/proc/device-tree/model", buf, sizeof(buf)) == 0 &&
		    strstr(buf, "PS4")) {
			snprintf(why, cap, "device-tree model %.200s", buf);
			return 2;
		}
	}
	snprintf(why, cap, "no PS4 signature found");
	return 0;
}

// Southbridge from the PCI id at 0000:00:14.4 - the same method the PS4
// initramfs and the loader use: 0x90a1 Aeolia, 0x90cc Belize, 0x90db Baikal.
// Only if that device is absent (not a PS4, or an unusual kernel) fall back to
// looking for southbridge driver names. Never infer it from the console model.
#define SB_PCI_PATH "/sys/bus/pci/devices/0000:00:14.4"
static const char *detect_sb(char *ev, size_t cap)
{
	char buf[64], rev[32];
	rev[0] = 0;
	if (slurp(SB_PCI_PATH "/device", buf, sizeof(buf)) == 0) {
		unsigned id = 0;
		sscanf(buf, "%x", &id);
		if (slurp(SB_PCI_PATH "/revision", rev, sizeof(rev)) == 0) {
			char tmp[32];
			snprintf(tmp, sizeof(tmp), "%s", rev);
			snprintf(rev, sizeof(rev), " rev 0x%s", tmp + (tmp[0] == '0' && tmp[1] == 'x' ? 2 : 0));
		} else {
			rev[0] = 0;
		}
		const char *n = id == 0x90a1 ? "aeolia" : id == 0x90cc ? "belize"
		              : id == 0x90db ? "baikal" : NULL;
		snprintf(ev, cap, "PCI 0000:00:14.4 device 0x%04x%s%s", id, rev,
		         n ? "" : " (unrecognised)");
		return n;
	}

	static const char *dirs[] = { "/sys/bus/pci/drivers", "/sys/bus/platform/drivers", NULL };
	static const char *needles[] = { "aeolia", "baikal", "belize", "ps4sb", NULL };
	for (int d = 0; dirs[d]; d++) {
		DIR *dh = opendir(dirs[d]);
		if (!dh)
			continue;
		struct dirent *e;
		while ((e = readdir(dh))) {
			for (int n = 0; needles[n]; n++) {
				if (strstr(e->d_name, needles[n])) {
					snprintf(ev, cap, "driver %.200s", e->d_name);
					const char *r = !strcmp(needles[n], "ps4sb") ? "belize"
							: needles[n];
					closedir(dh);
					return r;
				}
			}
		}
		closedir(dh);
	}
	snprintf(ev, cap, "no PCI 0000:00:14.4 and no southbridge driver name found");
	return NULL;
}

// ---------------------------------------------------------------- subreports

static void report_cpu(const struct cpu *c, int ps4)
{
	printf("cpu\n");
	printf("  vendor            : %s\n", c->vendor[0] ? c->vendor : "unknown");
	printf("  family/model/step : 0x%x / 0x%x / 0x%x\n", c->family, c->model, c->stepping);
	printf("  logical cpus      : %d\n", c->nproc);
	printf("  cores / siblings  : %d / %d\n", c->cores, c->siblings);
	printf("  model name        : %s\n", c->model_name[0] ? c->model_name : "(none reported)");

	// Jaguar is AMD family 16h, models 30h-3Fh (btver2). Only claim it on that match.
	int jaguar = !strcmp(c->vendor, "AuthenticAMD") && c->family == 0x16 &&
		     c->model >= 0x30 && c->model <= 0x3f;
	if (jaguar)
		printf("  family id         : AMD Jaguar (16h/3%xh)%s\n", c->model & 0xf,
		       ps4 ? " - matches the PS4 CPU" : " - console not confirmed");
	else
		printf("  family id         : not Jaguar (no claim made)\n");

	// Feature truth from CPUID-derived flags. Report what is there and what is not.
	struct { const char *n; const char *note; } f[] = {
		{ "sse4_2", "baseline for x86-64-v2" },
		{ "avx", "Jaguar has AVX" },
		{ "f16c", "" },
		{ "bmi1", "" },
		{ "aes", "" },
		{ "avx2", "Jaguar does NOT have this - never require it" },
		{ "fma", "Jaguar does NOT have this" },
		{ "bmi2", "Jaguar does NOT have this" },
		{ "xsave", "" },
		{ NULL, NULL },
	};
	printf("  features          :\n");
	for (int i = 0; f[i].n; i++) {
		int on = has_flag(c, f[i].n);
		printf("    %-8s %-3s %s%s%s\n", f[i].n, on ? "yes" : "no",
		       on ? "" : "absent", f[i].note[0] && !on ? " - " : "",
		       f[i].note[0] && !on ? f[i].note : "");
	}
	if (has_flag(c, "avx2"))
		printf("  WARNING           : AVX2 reported. On a Jaguar this is unexpected - "
		       "verify the CPU before trusting it.\n");
	else
		printf("  x86-64 level      : v2 is safe; v3 is NOT (needs AVX2)\n");

	// Cache topology as the kernel sees it.
	for (int i = 0; i < 4; i++) {
		char p[128], lv[32], sz[32], ty[32], sh[128];
		snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu0/cache/index%d/level", i);
		if (slurp(p, lv, sizeof(lv)) != 0)
			continue;
		snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu0/cache/index%d/size", i);
		if (slurp(p, sz, sizeof(sz)) != 0)
			continue;
		snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu0/cache/index%d/type", i);
		if (slurp(p, ty, sizeof(ty)) != 0)
			continue;
		snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu0/cache/index%d/shared_cpu_list", i);
		if (slurp(p, sh, sizeof(sh)) != 0)
			snprintf(sh, sizeof(sh), "?");
		printf("  cache L%-2s %-5s : %-6s shared by cpus %s\n", lv, ty, sz, sh);
	}
}

static void report_gpu(void)
{
	int found = 0;
	for (int i = 0; i < g_npci; i++) {
		if (!class_is(&g_pci[i], 0x03))
			continue;
		found = 1;
		printf("  %s  1002:%s  driver=%s\n", g_pci[i].addr, g_pci[i].device,
		       g_pci[i].driver[0] ? g_pci[i].driver : "none");
	}
	if (!found)
		printf("  no display-class PCI device found\n");
	printf("  note: PS4 GPUs are GCN (amdgpu gfx_v7: Liverpool on Fat/Slim, Gladius on Pro).\n"
	       "        A stock Mesa will not bind the PS4 device id; the PS4-patched Mesa is\n"
	       "        required. Device ids above are the ground truth for a support table.\n");
}

struct sdio_ev {
	char id[64];
	char driver[64];
};

static struct sdio_ev g_sdio[MAXF];
static int g_nsdio;

static void sdio_cb(const char *name, void *ud)
{
	(void)ud;
	if (g_nsdio >= MAXF)
		return;
	char path[512], buf[4096];
	struct sdio_ev *s = &g_sdio[g_nsdio];
	memset(s, 0, sizeof(*s));
	snprintf(path, sizeof(path), "/sys/bus/sdio/devices/%s/uevent", name);
	if (slurp(path, buf, sizeof(buf)) == 0) {
		char *p = strstr(buf, "SDIO_ID=");
		if (p)
			sscanf(p + 8, "%63s", s->id);
	}
	snprintf(path, sizeof(path), "/sys/bus/sdio/devices/%s/driver", name);
	link_base(path, s->driver, sizeof(s->driver));
	g_nsdio++;
}

static void report_wifi(void)
{
	printf("wifi / bluetooth (SDIO and USB devices as bound by the kernel)\n");
	int n = for_each("/sys/bus/sdio/devices", sdio_cb, NULL);
	if (n <= 0)
		printf("  no SDIO devices\n");
	for (int i = 0; i < g_nsdio; i++)
		printf("  sdio %-12s driver=%s\n", g_sdio[i].id,
		       g_sdio[i].driver[0] ? g_sdio[i].driver : "none (no driver bound)");

	// Marvell/MediaTek wifi over USB (some cards) and Bluetooth.
	DIR *d = opendir("/sys/bus/usb/devices");
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (e->d_name[0] == '.')
				continue;
			char p[512], v[16], pr[16], drv[64];
			snprintf(p, sizeof(p), "/sys/bus/usb/devices/%s/idVendor", e->d_name);
			if (slurp(p, v, sizeof(v)) != 0)
				continue;
			snprintf(p, sizeof(p), "/sys/bus/usb/devices/%s/idProduct", e->d_name);
			if (slurp(p, pr, sizeof(pr)) != 0)
				continue;
			snprintf(p, sizeof(p), "/sys/bus/usb/devices/%s/driver", e->d_name);
			link_base(p, drv, sizeof(drv));
			// 0bda/0e8d/02df/1286: Realtek, MediaTek, Marvell, Marvell wifi/bt
			if (!strcmp(v, "0e8d") || !strcmp(v, "02df") || !strcmp(v, "1286") ||
			    !strcmp(v, "0bda"))
				printf("  usb  %s:%s  driver=%s\n", v, pr,
				       drv[0] ? drv : "none");
		}
		closedir(d);
	}
	printf("  known PS4 parts: Marvell 88W8797 (mwifiex_sdio + btmrvl_sdio, custom fw),\n"
	       "                   Marvell 88W8897 (mwifiex_sdio + btmrvl_sdio, mainline fw),\n"
	       "                   MediaTek MT7668 (vendor mt76x8/MT6632 driver, out of tree).\n"
	       "  The SDIO id above decides which one this console has; it is not implied\n"
	       "  by the console model.\n");
}

static void report_net(void)
{
	printf("network interfaces\n");
	DIR *d = opendir("/sys/class/net");
	if (!d) {
		printf("  none\n");
		return;
	}
	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.' || !strcmp(e->d_name, "lo"))
			continue;
		char p[512], drv[64], st[32], mac[32];
		snprintf(p, sizeof(p), "/sys/class/net/%s/device/driver", e->d_name);
		link_base(p, drv, sizeof(drv));
		snprintf(p, sizeof(p), "/sys/class/net/%s/operstate", e->d_name);
		if (slurp(p, st, sizeof(st)) != 0)
			snprintf(st, sizeof(st), "?");
		snprintf(p, sizeof(p), "/sys/class/net/%s/address", e->d_name);
		if (slurp(p, mac, sizeof(mac)) != 0)
			snprintf(mac, sizeof(mac), "?");
		printf("  %-10s state=%-6s mac=%s driver=%s\n", e->d_name, st, mac,
		       drv[0] ? drv : "none");
	}
	closedir(d);
}

static void report_audio(void)
{
	printf("audio\n");
	FILE *f = fopen("/proc/asound/cards", "r");
	if (!f) {
		printf("  no /proc/asound - ALSA not available\n");
		return;
	}
	char line[512];
	int any = 0;
	while (fgets(line, sizeof(line), f)) {
		if (line[0] == ' ' || line[0] == '\n')
			continue;
		printf("  %s", line);
		any = 1;
	}
	fclose(f);
	if (!any)
		printf("  no sound cards\n");
}

static void report_storage(void)
{
	printf("storage\n");
	DIR *d = opendir("/sys/block");
	if (!d)
		return;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.' || strncmp(e->d_name, "sd", 2))
			continue;
		char p[512], sz[64], drv[64], rm[8];
		snprintf(p, sizeof(p), "/sys/block/%s/size", e->d_name);
		if (slurp(p, sz, sizeof(sz)) != 0)
			continue;
		snprintf(p, sizeof(p), "/sys/block/%s/device/driver", e->d_name);
		link_base(p, drv, sizeof(drv));
		snprintf(p, sizeof(p), "/sys/block/%s/removable", e->d_name);
		if (slurp(p, rm, sizeof(rm)) != 0)
			snprintf(rm, sizeof(rm), "?");
		unsigned long long sectors = strtoull(sz, NULL, 10);
		printf("  %-6s %6llu GiB removable=%s driver=%s\n", e->d_name,
		       sectors / 2097152ULL, rm, drv[0] ? drv : "?");
	}
	closedir(d);
	printf("  note: on Aeolia the internal drive is a USB-attached SATA bridge, so it\n"
	       "        appears as a USB disk here. On Belize/Baikal it is AHCI.\n");
}

// ------------------------------------------------------------------ main

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--json"))
			g_json = 1;

	struct cpu cpu;
	parse_cpuinfo(&cpu);
	for_each("/sys/bus/pci/devices", pci_cb, NULL);

	char why[256];
	int ev = ps4_evidence(why, sizeof(why));
	char sbev[256];
	const char *sb = detect_sb(sbev, sizeof(sbev));

	printf("ps4-hwprofile 0.1 - what this kernel actually detects\n");
	printf("=====================================================\n\n");
	printf("console\n");
	printf("  PS4 evidence      : %s (%s)\n",
	       ev == 2 ? "confirmed" : ev == 1 ? "probable" : "not found", why);
	printf("  southbridge       : %s (%s)\n", sb ? sb : "unknown - not guessed",
	       sbev);
	if (!sb)
		printf("                      settle it with: ls /sys/bus/pci/drivers, "
		       "dmesg | grep -i -e aeolia -e baikal -e ps4\n");
	printf("\n");

	report_cpu(&cpu, ev > 0);

	printf("\ndisplay\n");
	report_gpu();

	printf("\n");
	report_wifi();

	printf("\n");
	report_net();

	printf("\n");
	report_audio();

	printf("\n");
	report_storage();

	printf("\nUnknown values above are reported as unknown on purpose: this tool does not\n"
	       "infer hardware from the console model. Paste this output when reporting a\n"
	       "compatibility result.\n");
	return 0;
}
