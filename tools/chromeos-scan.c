// chromeos-scan - identify a ChromeOS-for-PS4 installation and produce an
// itemised removal plan. Host-side reference implementation of the rules the
// installer app embeds (the app cannot spawn processes on OrbisOS).
//
// The point of this tool is the SAFETY RULE, not the scanning:
//
//   * only paths that belong to ChromeOS-for-PS4 are ever claimed;
//   * /data/linux/boot is SHARED with any plain Linux install (the loader reads
//     bzImage + initramfs.cpio.gz from there), so those files are never claimed
//     even when a ChromeOS install exists next to them;
//   * /data/payloads is shared with GoldHEN / Payload Guest, so only the exact
//     ChromeOS payload filename is claimed;
//   * nothing is deleted without --apply AND an explicit confirmation token;
//   * everything skipped is printed with the reason, so a user can see what was
//     deliberately left alone.
//
// Build: cc -O2 -Wall -Wextra -o chromeos-scan chromeos-scan.c
// Test:  see test-chromeos-scan.sh (synthetic tree, no PS4 needed)

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAXITEMS 512
#define CONFIRM_TOKEN "ERASE-CHROMEOS"

enum kind { K_IMAGE, K_BOOT, K_PAYLOAD, K_STATE, K_MARKER };
enum action { A_DELETE, A_KEEP_SHARED, A_KEEP_FOREIGN };

struct item {
	char path[512];
	unsigned long long size;
	enum kind kind;
	enum action action;
	const char *why;
};

static struct item g_items[MAXITEMS];
static int g_n;

static int stat_size(const char *p, unsigned long long *sz)
{
	struct stat st;
	if (stat(p, &st) != 0)
		return -1;
	if (!S_ISREG(st.st_mode))
		return -1;
	*sz = (unsigned long long)st.st_size;
	return 0;
}

static void add(const char *root, const char *rel, enum kind k, enum action a, const char *why)
{
	if (g_n >= MAXITEMS)
		return;
	struct item *it = &g_items[g_n];
	snprintf(it->path, sizeof(it->path), "%s%s", root, rel);
	it->kind = k;
	it->action = a;
	it->why = why;
	it->size = 0;
	if (stat_size(it->path, &it->size) != 0) {
		// Not a regular file (or gone): do not claim it.
		return;
	}
	g_n++;
}

// Files whose names are unambiguous ChromeOS-for-PS4 artifacts. "build-id" is
// not: any installer of ours writes one too, so it is only claimed when a
// chromeos image is present (checked by the caller).
static const struct {
	const char *rel;
	enum kind kind;
} k_chromeos_named[] = {
	{ "/data/linux/boot/chromeos.img.xz", K_IMAGE },
	{ "/data/linux/boot/chromeos.img.size", K_STATE },
	{ "/data/linux/boot/chromeos.img.alloc", K_STATE },
	{ "/data/linux/boot/chromeos.img.alloc.part", K_STATE },
	{ "/data/linux/boot/chromeos-install-choice", K_STATE },
	{ "/data/linux/boot/chromeos-target", K_STATE },
	{ "/data/linux/boot/chromeos-error.txt", K_STATE },
	{ "/data/linux/boot/chromeos-external.guid", K_STATE },
	{ "/data/linux/boot/chromeos-dryrun", K_STATE },
	{ "/data/linux/boot/ps4-layer.sqfs", K_BOOT },
	{ "/data/linux/boot/ps4-chromeos-loader.bin", K_PAYLOAD },
	{ "/data/payloads/ps4-chromeos-loader.bin", K_PAYLOAD },
	{ "/mnt/usb0/CHROMEOS-PS4-TARGET.txt", K_MARKER },
	{ "/mnt/usb1/CHROMEOS-PS4-TARGET.txt", K_MARKER },
	{ NULL, K_STATE },
};

// Shared paths: reported, never claimed. This is the list that keeps a
// coexisting plain-Linux install alive.
static const char *k_shared[] = {
	"/data/linux/boot/bzImage",
	"/data/linux/boot/initramfs.cpio.gz",
	"/data/linux/boot/bootargs.txt",
	"/data/linux/boot/vram.txt",
	"/data/linux/boot/build-id",
	"/user/system/boot/bzImage",
	"/user/system/boot/initramfs.cpio.gz",
	NULL,
};

static void scan(const char *root)
{
	char p[600];

	// 1. The image. This is the one artifact that proves an install exists.
	add(root, "/user/app/chromeos.img", K_IMAGE, A_DELETE,
	    "the ChromeOS disk image (all ChromeOS data lives inside it)");

	int have_image = 0;
	for (int i = 0; i < g_n; i++)
		if (g_items[i].kind == K_IMAGE)
			have_image = 1;

	// 2. Unambiguously named artifacts.
	for (int i = 0; k_chromeos_named[i].rel; i++) {
		snprintf(p, sizeof(p), "%s%s", root, k_chromeos_named[i].rel);
		unsigned long long sz;
		if (stat_size(p, &sz) == 0)
			add(root, k_chromeos_named[i].rel, k_chromeos_named[i].kind, A_DELETE,
			    "ChromeOS-for-PS4 artifact");
	}

	// 3. The loader payload under /data/payloads may have other names; list
	//    anything that looks like ours but is not the exact name as foreign.
	char dir[600];
	snprintf(dir, sizeof(dir), "%s/data/payloads", root);
	DIR *d = opendir(dir);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (e->d_name[0] == '.')
				continue;
			if (!strstr(e->d_name, "chromeos"))
				continue;
			if (!strcmp(e->d_name, "ps4-chromeos-loader.bin"))
				continue;   // already added
			char rel[400];
			snprintf(rel, sizeof(rel), "/data/payloads/%s", e->d_name);
			add(root, rel, K_PAYLOAD, A_KEEP_FOREIGN,
			    "name suggests ChromeOS but is not the known payload; left alone");
		}
		closedir(d);
	}

	// 4. Shared files: reported, never claimed.
	for (int i = 0; k_shared[i]; i++) {
		snprintf(p, sizeof(p), "%s%s", root, k_shared[i]);
		unsigned long long sz;
		if (stat_size(p, &sz) != 0)
			continue;
		if (!strcmp(k_shared[i], "/data/linux/boot/build-id") && !have_image)
			continue;   // our own stamp, not ChromeOS's
		add(root, k_shared[i], K_BOOT, A_KEEP_SHARED,
		    "shared with plain-Linux installs; not ChromeOS-owned");
	}

	// 5. Anything else under the ChromeOS boot dir that we cannot attribute.
	snprintf(dir, sizeof(dir), "%s/data/linux/boot", root);
	d = opendir(dir);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (e->d_name[0] == '.')
				continue;
			int known = 0;
			for (int i = 0; i < g_n; i++) {
				char tail[400];
				snprintf(tail, sizeof(tail), "/data/linux/boot/%s", e->d_name);
				if (strlen(g_items[i].path) >= strlen(tail) &&
				    !strcmp(g_items[i].path + strlen(g_items[i].path) - strlen(tail), tail))
					known = 1;
			}
			if (known)
				continue;
			char rel[400];
			snprintf(rel, sizeof(rel), "/data/linux/boot/%s", e->d_name);
			add(root, rel, K_BOOT, A_KEEP_FOREIGN,
			    "not attributable to ChromeOS; left alone");
		}
		closedir(d);
	}
}

int main(int argc, char **argv)
{
	const char *root = "";
	int apply = 0;
	const char *confirm = NULL;
	for (int i = 1; i < argc; i++) {
		if (!strncmp(argv[i], "--root=", 7))
			root = argv[i] + 7;
		else if (!strcmp(argv[i], "--apply"))
			apply = 1;
		else if (!strncmp(argv[i], "--confirm=", 10))
			confirm = argv[i] + 10;
		else {
			fprintf(stderr, "usage: %s [--root=DIR] [--apply --confirm=%s]\n",
				argv[0], CONFIRM_TOKEN);
			return 2;
		}
	}

	scan(root);

	unsigned long long total = 0;
	int n_delete = 0, found = 0;
	for (int i = 0; i < g_n; i++) {
		if (g_items[i].action == A_DELETE) {
			total += g_items[i].size;
			n_delete++;
			found = 1;
		}
	}

	printf("ChromeOS for PS4: %s\n", found ? "FOUND" : "not found");
	if (!found) {
		for (int i = 0; i < g_n; i++)
			printf("  keep  %-56s %s\n", g_items[i].path, g_items[i].why);
		return 0;
	}

	printf("\nWill be removed (%d files, %llu MiB):\n", n_delete,
	       total / (1024ULL * 1024ULL));
	for (int i = 0; i < g_n; i++)
		if (g_items[i].action == A_DELETE)
			printf("  DELETE %-56s %8llu KiB  %s\n", g_items[i].path,
			       g_items[i].size / 1024ULL, g_items[i].why);

	int n_keep = 0;
	for (int i = 0; i < g_n; i++)
		if (g_items[i].action != A_DELETE)
			n_keep++;
	if (n_keep) {
		printf("\nLeft alone (%d):\n", n_keep);
		for (int i = 0; i < g_n; i++)
			if (g_items[i].action != A_DELETE)
				printf("  keep   %-56s %8llu KiB  %s\n", g_items[i].path,
				       g_items[i].size / 1024ULL, g_items[i].why);
	}

	if (!apply) {
		printf("\nDry run. Nothing was deleted. Re-run with:\n"
		       "  --apply --confirm=%s\n", CONFIRM_TOKEN);
		return 0;
	}
	if (!confirm || strcmp(confirm, CONFIRM_TOKEN) != 0) {
		fprintf(stderr, "\nrefusing to delete: --confirm=%s is required\n",
			CONFIRM_TOKEN);
		return 3;
	}

	int failed = 0;
	for (int i = 0; i < g_n; i++) {
		if (g_items[i].action != A_DELETE)
			continue;
		if (unlink(g_items[i].path) != 0) {
			fprintf(stderr, "  FAILED %s: %s\n", g_items[i].path, strerror(errno));
			failed++;
		} else {
			printf("  removed %s\n", g_items[i].path);
		}
	}
	printf("\n%d removed, %d failed. Shared boot files were not touched.\n", n_delete - failed,
	       failed);
	return failed ? 1 : 0;
}
