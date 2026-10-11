// Injected into a test copy of Next Term only (scripts/orphan-check.sh): answers the quit and close alerts with
// their first button ("Quit"/"Close"), quits on SIGUSR1 as ⌘Q does ([NSApp terminate:]), and logs the quit's
// timeline and the alerts' text. Its first line is the home the app really runs with, which the check verifies.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/time.h>
static IMP origRunModal;
static char logPath[1024];
static double now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
static void logLine(const char *fmt, NSString *a, NSString *b) {
    FILE *f = fopen(logPath, "a"); if (!f) return;
    fprintf(f, "%.3f ", now()); fprintf(f, fmt, a ? a.UTF8String : "", b ? b.UTF8String : ""); fprintf(f, "\n"); fclose(f);
}
static NSModalResponse fakeRunModal(NSAlert *self, SEL _cmd) {
    NSString *t = self.messageText ?: @"";
    logLine("alert: %s | %s", t, self.informativeText);
    if ([t hasPrefix:@"Quit"] || [t hasPrefix:@"Close"] || [t hasPrefix:@"Reopen"]) return NSAlertFirstButtonReturn;
    return ((NSModalResponse(*)(id, SEL))origRunModal)(self, _cmd);
}
static void atExit(void) { logLine("exit%s%s", nil, nil); }
__attribute__((constructor)) static void shimInit(void) {
    const char *p = getenv("NT_SHIM_LOG");
    snprintf(logPath, sizeof logPath, "%s", p ? p : "/dev/null");
    const char *home = getenv("HOME"), *fixed = getenv("CFFIXED_USER_HOME");
    logLine("home %s | %s", [NSString stringWithFormat:@"%s %s", home ? home : "(none)", fixed ? fixed : "(none)"], NSHomeDirectory());
    unsetenv("DYLD_INSERT_LIBRARIES"); unsetenv("NT_SHIM_LOG"); // the tabs' shells and programs never see the shim
    Method m = class_getInstanceMethod([NSAlert class], @selector(runModal));
    origRunModal = method_setImplementation(m, (IMP)fakeRunModal);
    atexit(atExit);
    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{ logLine("quit requested%s%s", nil, nil); [NSApp terminate:nil]; });
    dispatch_resume(s);
    static id observer; observer = s; // keep the source alive
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
        usingBlock:^(NSNotification *n) { logLine("willTerminate%s%s", nil, nil); }];
    logLine("shim loaded pid %s%s", [NSString stringWithFormat:@"%d", getpid()], nil);
}
