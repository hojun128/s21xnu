#!/bin/bash
# S21 per-process CPU top (boot-arg sweetcputop=<s>, default 20; 0 off): run189's big cores sat at 100 % busy with the
# GPU idle; this names the processes. Idea from PixOS 0341 (proccpu top), own code.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

cat > bsd/dev/sweet_cputop.c <<'EOF_SWEET_SRC'
/*
 * Every sweetcputop seconds: CPU time (user + system, live and dead threads: TASK_ABSOLUTETIME_INFO) of every
 * process since the last sample; one kept line "dvfs cputop: <s>s total <pct> | name pct ..." with the six largest,
 * in percent of one core, when the total is over 40 % (an idle phone stays quiet). At most 60 lines a boot.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/proc.h>
#include <sys/proc_internal.h>
#include <mach/task_info.h>
#include <kern/clock.h>
#include <kern/thread_call.h>
#include <pexpert/pexpert.h>

extern kern_return_t task_info(task_t task, task_flavor_t flavor, task_info_t task_info_out, mach_msg_type_number_t *count);
extern void sweet_mali_log_str(const char *s);
int sweet_cputop_start(void);

#define CT_N 384
static struct { int pid; uint64_t last, delta; uint32_t gen; char name[17]; } ct[CT_N];
static uint32_t ct_gen, ct_lines;
static uint32_t ct_secs = 20;
static thread_call_t ct_tc;
static uint64_t ct_t0;

static int
ct_visit(proc_t p, __unused void *arg)
{
	task_t t = proc_task(p);
	int pid = proc_pid(p);
	if (t == TASK_NULL) {
		return PROC_RETURNED;
	}
	task_absolutetime_info_data_t ti;
	mach_msg_type_number_t n = TASK_ABSOLUTETIME_INFO_COUNT;
	if (task_info(t, TASK_ABSOLUTETIME_INFO, (task_info_t)&ti, &n) != KERN_SUCCESS) {
		return PROC_RETURNED;
	}
	uint64_t tot = ti.total_user + ti.total_system;
	int fr = -1;
	for (int i = 0; i < CT_N; i++) {
		if (ct[i].gen && ct[i].pid == pid) {
			ct[i].delta = tot >= ct[i].last ? tot - ct[i].last : tot;
			ct[i].last = tot;
			ct[i].gen = ct_gen;
			return PROC_RETURNED;
		}
		if (fr < 0 && (ct[i].gen == 0 || (ct[i].gen != ct_gen && ct[i].gen != ct_gen - 1))) {
			fr = i;
		}
	}
	if (fr >= 0) {
		ct[fr].pid = pid;
		ct[fr].last = tot;
		ct[fr].delta = ct_gen > 1 ? tot : 0;   /* started inside the window: all of its time is new */
		ct[fr].gen = ct_gen;
		strlcpy(ct[fr].name, proc_best_name(p), sizeof(ct[fr].name));
	}
	return PROC_RETURNED;
}

static void
ct_run(__unused thread_call_param_t p0, __unused thread_call_param_t p1)
{
	uint64_t now = mach_absolute_time(), win_ns = 0, dl = 0;
	ct_gen++;
	proc_iterate(PROC_ALLPROCLIST, ct_visit, NULL, NULL, NULL);
	absolutetime_to_nanoseconds(now - ct_t0, &win_ns);
	ct_t0 = now;
	if (ct_gen > 1 && win_ns > 0 && ct_lines < 60) {
		int top[6] = { -1, -1, -1, -1, -1, -1 };
		uint64_t total = 0;
		for (int i = 0; i < CT_N; i++) {
			if (ct[i].gen != ct_gen) {
				continue;
			}
			total += ct[i].delta;
			for (int k = 0; k < 6; k++) {
				if (top[k] < 0 || ct[i].delta > ct[top[k]].delta) {
					for (int m = 5; m > k; m--) {
						top[m] = top[m - 1];
					}
					top[k] = i;
					break;
				}
			}
		}
		uint64_t tot_ns = 0;
		absolutetime_to_nanoseconds(total, &tot_ns);
		uint32_t tot_pct = (uint32_t)(tot_ns * 100 / win_ns);
		if (tot_pct >= 40) {
			char ln[220];
			int L = snprintf(ln, sizeof(ln), "dvfs cputop: %llus total %u%% |", win_ns / 1000000000ULL, tot_pct);
			for (int k = 0; k < 6 && top[k] >= 0 && L < (int)sizeof(ln) - 30; k++) {
				uint64_t d_ns = 0;
				absolutetime_to_nanoseconds(ct[top[k]].delta, &d_ns);
				L += snprintf(ln + L, sizeof(ln) - L, " %s %llu", ct[top[k]].name, d_ns * 100 / win_ns);
			}
			sweet_mali_log_str(ln);
			ct_lines++;
		}
	}
	clock_interval_to_deadline(ct_secs, NSEC_PER_SEC, &dl);
	thread_call_enter_delayed(ct_tc, dl);
}

int
sweet_cputop_start(void)
{
	static int started;
	if (started) {
		return 0;
	}
	started = 1;
	PE_parse_boot_argn("sweetcputop", &ct_secs, sizeof(ct_secs));
	if (!ct_secs) {
		return -1;
	}
	ct_tc = thread_call_allocate(ct_run, NULL);
	if (!ct_tc) {
		return -1;
	}
	ct_t0 = mach_absolute_time();
	uint64_t dl = 0;
	clock_interval_to_deadline(ct_secs, NSEC_PER_SEC, &dl);
	thread_call_enter_delayed(ct_tc, dl);
	return 0;
}
#endif /* ARM64_BOARD_CONFIG_SWEET */
EOF_SWEET_SRC

grep -q 'bsd/dev/sweet_cputop.c' bsd/conf/files || printf 'bsd/dev/sweet_cputop.c\t\t\tstandard\n' >> bsd/conf/files
