// Injected into a test copy of Next Term only (scripts/perf-budget.sh): hides the app on SIGUSR1 as ⌘H does, shows
// it again on SIGUSR2, counts the terminals' draw calls, and every second writes to NT_SHIM_STATUS
// "draws visible-windows windows active hidden tab-draws row-draws". The last two are the terminal's tabs drawn, on
// the top bar and in the tab list, or -1 for a build that has no such view. Its first log line is the home the app
// really runs with, which the check verifies before measuring anything. With NT_SHIM_FRONT=1 it also brings the app to
// the front. On SIGINFO it asks the allocator to give freed memory back (malloc_zone_pressure_relief), and logs what
// that returned.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <malloc/malloc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static char logPath[1024], statusPath[1024];
static BOOL front;
static unsigned long long draws, tabDraws, rowDraws;
static int tabClasses, rowClasses;
static IMP origDraw;

static void logLine(NSString *line) {
    FILE *f = fopen(logPath, "a");
    if (!f) return;
    fprintf(f, "%s\n", line.UTF8String);
    fclose(f);
}

static void relieve(void) {
    struct timeval a, b;
    gettimeofday(&a, NULL);
    size_t freed = malloc_zone_pressure_relief(NULL, 0);
    gettimeofday(&b, NULL);
    double ms = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_usec - a.tv_usec) / 1e3;
    logLine([NSString stringWithFormat:@"relief %.1f MB in %.1f ms", freed / 1e6, ms]);
}

static void countedDraw(id self, SEL _cmd, NSRect rect) {
    draws++;
    ((void (*)(id, SEL, NSRect))origDraw)(self, _cmd, rect);
}

/// Counts the draws of `cls` into `counter`: its own drawRect: wrapped when it has one, else one added that calls what
/// it inherits. Never the inherited method itself, which every view of that kind shares.
static BOOL countDraws(Class cls, unsigned long long *counter) {
    SEL sel = @selector(drawRect:);
    Class parent = class_getSuperclass(cls);
    Method own = class_getInstanceMethod(cls, sel), inherited = parent ? class_getInstanceMethod(parent, sel) : NULL;
    if (!own || !inherited) return NO;
    if (own != inherited) {
        IMP original = method_getImplementation(own);
        method_setImplementation(own, imp_implementationWithBlock(^(id view, NSRect rect) {
            (*counter)++;
            ((void (*)(id, SEL, NSRect))original)(view, sel, rect);
        }));
        return YES;
    }
    IMP drawn = method_getImplementation(inherited);
    return class_addMethod(cls, sel, imp_implementationWithBlock(^(id view, NSRect rect) {
        (*counter)++;
        ((void (*)(id, SEL, NSRect))drawn)(view, sel, rect);
    }), method_getTypeEncoding(inherited));
}

/// The top bar's tab is a private Swift class: its runtime name is mangled, but ends in its own. It is looked for among
/// the names of the app's own classes, so no other class is loaded for it. It draws itself (its separator and the
/// selected tab's edge). A tab-list row draws nothing of its own, only its text, whose class has a stable name
/// (NTTabListText): a release build adds no drawRect: of its own to it, so one is added.
static void countTabStrips(void) {
    Class bar = NSClassFromString(@"NextTerm.TabBarView");
    const char *image = bar ? class_getImageName(bar) : NULL;
    unsigned int count = 0;
    const char **names = image ? objc_copyClassNamesForImage(image, &count) : NULL;
    const char *suffix = "TabItemView";
    size_t suffixLength = strlen(suffix);
    for (unsigned int i = 0; i < count; i++) {
        size_t length = strlen(names[i]);
        if (length < suffixLength || strcmp(names[i] + length - suffixLength, suffix) != 0) continue;
        Class tab = objc_getClass(names[i]);
        if (tab && countDraws(tab, &tabDraws)) tabClasses++;
    }
    free(names);
    Class rowText = NSClassFromString(@"NTTabListText");
    if (rowText && countDraws(rowText, &rowDraws)) rowClasses++;
}

static void writeStatus(void) {
    NSInteger visible = 0, windows = 0;
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible || [w isKindOfClass:[NSPanel class]]) continue;
        windows++;
        if (w.occlusionState & NSWindowOcclusionStateVisible) visible++;
    }
    FILE *f = fopen(statusPath, "w");
    if (!f) return;
    long long tabs = tabClasses ? (long long)tabDraws : -1, rows = rowClasses ? (long long)rowDraws : -1;
    fprintf(f, "%llu %ld %ld %d %d %lld %lld\n", draws, (long)visible, (long)windows, NSApp.isActive ? 1 : 0, NSApp.isHidden ? 1 : 0,
            tabs, rows);
    fclose(f);
}

static void toFront(void) {
    if (!front) return;
    [NSApp activateIgnoringOtherApps:YES];
    for (NSWindow *w in NSApp.windows) if (w.isVisible) [w orderFront:nil];
}

static dispatch_source_t onSignal(int sig, dispatch_block_t handler) {
    signal(sig, SIG_IGN);
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, handler);
    dispatch_resume(s);
    return s;
}

__attribute__((constructor)) static void shimInit(void) {
    const char *p = getenv("NT_SHIM_LOG"), *st = getenv("NT_SHIM_STATUS"), *fr = getenv("NT_SHIM_FRONT");
    snprintf(logPath, sizeof logPath, "%s", p ? p : "/dev/null");
    snprintf(statusPath, sizeof statusPath, "%s", st ? st : "/dev/null");
    front = fr && fr[0] == '1';
    const char *home = getenv("HOME"), *fixed = getenv("CFFIXED_USER_HOME");
    logLine([NSString stringWithFormat:@"home %s %s | %@", home ? home : "(none)", fixed ? fixed : "(none)", NSHomeDirectory()]);
    // The tabs' shells and programs never see the shim.
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("NT_SHIM_LOG");
    unsetenv("NT_SHIM_STATUS");
    unsetenv("NT_SHIM_FRONT");
    static dispatch_source_t sources[4];
    sources[0] = onSignal(SIGUSR1, ^{ [NSApp hide:nil]; });
    sources[1] = onSignal(SIGUSR2, ^{ [NSApp unhide:nil]; toFront(); });
    sources[3] = onSignal(SIGINFO, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ relieve(); });
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        Class terminal = NSClassFromString(@"SwiftTerm.TerminalView");
        Method m = terminal ? class_getInstanceMethod(terminal, @selector(drawRect:)) : NULL;
        if (m) origDraw = method_setImplementation(m, (IMP)countedDraw);
        countTabStrips();
        logLine([NSString stringWithFormat:@"shim loaded pid %d, counting draws %s, top tabs %s, tab-list rows %s", getpid(),
                 m ? "yes" : "NO", tabClasses ? "yes" : "no", rowClasses ? "yes" : "no"]);
        sources[2] = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(sources[2], DISPATCH_TIME_NOW, NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(sources[2], ^{ writeStatus(); });
        dispatch_resume(sources[2]);
        toFront();
    });
}
