/* Placeholder for the launchd test slot (the GPU composites the UI in the kernel). It also sets the calendar
 * clock: the phone has no RTC driver, so it booted in 1969 and the Astronomy wallpaper drew the night side.
 * /usr/local/etc/sweet_epoch holds the Mac's time written when the rootfs was updated. */
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>
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
	for (;;) pause();
	return 0;
}
