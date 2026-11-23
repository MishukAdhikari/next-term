// A process's counters, from proc_pid_rusage (scripts/perf-budget.sh builds and runs this). Instructions retired
// are the measure the budgets use: unlike CPU time they stay the same whether the work ran on a P or an E core, or
// on a busy machine. CPU times are in nanoseconds (the kernel counts in mach ticks); the children's are those of
// the children the process has reaped (git runs, for Next Term); the footprint is what Activity Monitor shows.
// The wakeups (interrupt-level, and those that took the package out of idle) and the kernel's energy estimate are
// what Activity Monitor's Energy Impact weighs for an idle app.
// Usage: ru <pid>...   one line per pid: pid instructions cycles user_ns system_ns child_user_ns child_system_ns footprint
//                      interrupt_wakeups idle_wakeups energy_nj
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: ru <pid>...\n");
        return 2;
    }
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    int failed = 0;
    for (int i = 1; i < argc; i++) {
        struct rusage_info_v6 ri;
        if (proc_pid_rusage(atoi(argv[i]), RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) {
            printf("%s none\n", argv[i]);
            failed = 1;
            continue;
        }
#define NS(ticks) ((unsigned long long)((ticks) * base.numer / base.denom))
        printf("%s %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu\n", argv[i], (unsigned long long)ri.ri_instructions,
               (unsigned long long)ri.ri_cycles, NS(ri.ri_user_time), NS(ri.ri_system_time), NS(ri.ri_child_user_time),
               NS(ri.ri_child_system_time), (unsigned long long)ri.ri_phys_footprint,
               (unsigned long long)ri.ri_interrupt_wkups, (unsigned long long)ri.ri_pkg_idle_wkups,
               (unsigned long long)ri.ri_energy_nj);
    }
    return failed;
}
