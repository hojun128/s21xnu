/* Placeholder for the launchd test slot: does nothing (the GPU now composites the UI in the kernel). */
#include <unistd.h>
int main(void) { for (;;) pause(); return 0; }
