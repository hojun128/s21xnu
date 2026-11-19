/* The launchd test slot (com.sweet.malitest, /usr/local/bin/malitest; the GPU composites the UI in the kernel).
 *  1. Sets the calendar clock: the phone has no RTC driver, so it booted in 1969 and the Astronomy wallpaper drew the
 *     night side. /usr/local/etc/sweet_epoch holds the Mac's time written when the rootfs was updated.
 *  2. Maintenance over Wi-Fi: iOS has no adb, and in everyday mode nothing reboots the phone by itself, so every test
 *     needed the user's hands to reach TWRP. A TCP listener (port 6021) takes one line, "<token> <command>", and only with
 *     the token from /usr/local/etc/sweet_token (written by the Mac's push_rootfs.sh, never in git; no token file = no
 *     listener). Commands: "ping" (answers uptime) and "twrp" (SweetMali selector 7: the kernel's reboot into recovery).
 *     Every 20 s a UDP broadcast "SWEET21 6021" (port 6022) tells the Mac where the phone is. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <unistd.h>
#include <mach/mach.h>

typedef mach_port_t io_connect_t, io_service_t;
extern const mach_port_t kIOMasterPortDefault;
extern io_service_t IOServiceGetMatchingService(mach_port_t, void *);
extern void *IOServiceMatching(const char *);
extern kern_return_t IOServiceOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t *, uint32_t, const void *, size_t,
    uint64_t *, uint32_t *, void *, size_t *);

static char token[80];
static io_connect_t gc;

static void klog(const char *s)
{
	if (!gc) {
		io_service_t sv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetMali"));
		if (sv) IOServiceOpen(sv, mach_task_self(), 0, &gc);
	}
	if (gc) IOConnectCallMethod(gc, 5, NULL, 0, s, strlen(s), NULL, NULL, NULL, NULL);
}

static void *announce(void *a)
{
	(void)a;
	int s = socket(AF_INET, SOCK_DGRAM, 0), on = 1;
	if (s < 0) return NULL;
	setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, sizeof on);
	struct sockaddr_in to = { .sin_len = sizeof to, .sin_family = AF_INET, .sin_port = htons(6022), .sin_addr.s_addr = htonl(INADDR_BROADCAST) };
	for (;;) {
		const char *m = "SWEET21 6021";
		sendto(s, m, strlen(m), 0, (struct sockaddr *)&to, sizeof to);
		sleep(20);
	}
	return NULL;
}

static void serve(void)
{
	int s = socket(AF_INET, SOCK_STREAM, 0), on = 1;
	if (s < 0) return;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
	struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(6021), .sin_addr.s_addr = htonl(INADDR_ANY) };
	if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 2)) { close(s); return; }
	for (;;) {
		int c = accept(s, NULL, NULL);
		if (c < 0) { sleep(1); continue; }
		struct timeval tv = { 3, 0 };
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
		char b[160] = { 0 }; ssize_t n = recv(c, b, sizeof b - 1, 0);
		if (n > 0) {
			b[strcspn(b, "\r\n")] = 0;
			size_t tl = strlen(token);
			if (tl >= 16 && !strncmp(b, token, tl) && b[tl] == ' ') {
				const char *cmd = b + tl + 1;
				if (!strcmp(cmd, "ping")) {
					struct timeval bt; size_t l = sizeof bt; int mib[2] = { CTL_KERN, KERN_BOOTTIME };
					struct timeval nw; gettimeofday(&nw, NULL);
					long up = sysctl(mib, 2, &bt, &l, NULL, 0) == 0 ? (long)(nw.tv_sec - bt.tv_sec) : -1;
					char r[64]; snprintf(r, sizeof r, "pong up %ld\n", up); send(c, r, strlen(r), 0);
				} else if (!strcmp(cmd, "twrp")) {
					send(c, "rebooting to recovery\n", 22, 0);
					klog("malinop: reboot to recovery asked over Wi-Fi");
					close(c); c = -1;
					sync(); sleep(1);
					if (gc) IOConnectCallMethod(gc, 7, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
				} else send(c, "?\n", 2, 0);
			} else send(c, "no\n", 3, 0);
		}
		if (c >= 0) close(c);
	}
}

int main(void)
{
	FILE *f = fopen("/usr/local/etc/sweet_epoch", "r");
	long e = 0;
	if (f) { if (fscanf(f, "%ld", &e) != 1) e = 0; fclose(f); }
	struct timeval now; gettimeofday(&now, NULL);
	if (e > 1700000000L && now.tv_sec < e) {
		struct timeval tv = { e, 0 };
		int r = settimeofday(&tv, NULL);
		fprintf(stderr, "malinop: clock set to %ld: %d\n", e, r);
	}
	f = fopen("/usr/local/etc/sweet_token", "r");
	if (f) { if (!fgets(token, sizeof token, f)) token[0] = 0; fclose(f); token[strcspn(token, "\r\n ")] = 0; }
	if (strlen(token) < 16) { for (;;) pause(); }
	for (int i = 0; i < 30 && !gc; i++) { klog("malinop: maintenance listener on 6021"); if (!gc) sleep(2); }
	pthread_t t; pthread_create(&t, NULL, announce, NULL);
	serve();
	for (;;) pause();
	return 0;
}
