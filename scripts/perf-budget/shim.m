// Injected into a test copy of Next Term only (scripts/perf-budget.sh): hides the app on SIGUSR1 as ⌘H does, shows
// it again on SIGUSR2, counts the terminals' draw calls, and every second writes to NT_SHIM_STATUS
// "draws visible-windows windows active hidden tab-draws row-draws". The last two are the terminal's tabs drawn, on
// the top bar and in the tab list, or -1 for a build that has no such view. Its first log line is the home the app
// really runs with, which the check verifies before measuring anything. With NT_SHIM_FRONT=1 it also brings the app to
// the front. On SIGINFO it asks the allocator to give freed memory back (malloc_zone_pressure_relief), and logs what
// that returned.
//
// Suggestions while typing (G1): when the file NT_SHIM_TYPE appears it reads it, removes it, clicks the key window's
// terminal (giving it the keyboard, as a hand would), and types the file's characters into its own app, one every
// NT_SHIM_TYPE_GAP_MS (80 ms), as key events posted to the key window (no permission needed; ^U is Control-U). It stamps, with the system's uptime, each key down for a terminal (-[NSApplication
// sendEvent:]), each -[NTGhostText ghostShown:] with its argument (when the shell's report it answers was read), and
// each -[NTGhostText drawRect:], and every second appends the stamps to NT_SHIM_STATUS's file with ".ghost" after it:
// "typing <t>", "key <t>", "shown <arrival> <t>", "draw <t>".
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <malloc/malloc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static char logPath[1024], statusPath[1024], typePath[1024], samplesPath[1024];
static double typeGap = 0.08;
static NSMutableString *samples;
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

// MARK: suggestions while typing (G1)

static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }

static void stamp(NSString *line) {
    if (!samples) samples = [NSMutableString string];
    [samples appendString:line];
    [samples appendString:@"\n"];
}

static void flushSamples(void) {
    if (!samples.length || !samplesPath[0]) return;
    FILE *f = fopen(samplesPath, "a");
    if (!f) return;
    fputs(samples.UTF8String, f);
    fclose(f);
    [samples setString:@""];
}

/// The key codes of what G1 types (ANSI layout); anything else goes as code 0, with its characters.
static unsigned short keyCode(unichar c) {
    static const struct { char key; unsigned short code; } codes[] = {
        {'a', 0}, {'s', 1}, {'d', 2}, {'f', 3}, {'h', 4}, {'g', 5}, {'z', 6}, {'x', 7}, {'c', 8}, {'v', 9}, {'b', 11},
        {'q', 12}, {'w', 13}, {'e', 14}, {'r', 15}, {'y', 16}, {'t', 17}, {'o', 31}, {'u', 32}, {'i', 34}, {'p', 35},
        {'l', 37}, {'j', 38}, {'k', 40}, {'n', 45}, {'m', 46}, {'-', 27}, {'/', 44}, {'.', 47}, {' ', 49},
    };
    for (size_t i = 0; i < sizeof codes / sizeof codes[0]; i++) if (codes[i].key == c) return codes[i].code;
    return 0;
}

static void typeKeys(NSString *text, NSUInteger at) {
    if (at >= text.length) return;
    unichar c = [text characterAtIndex:at];
    NSWindow *window = NSApp.keyWindow;
    if (window) {
        BOOL control = c < 0x20;
        unichar plain = control ? c + 0x60 : c;
        NSString *characters = [NSString stringWithCharacters:&c length:1];
        NSString *ignoring = [NSString stringWithCharacters:&plain length:1];
        NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                    modifierFlags:control ? NSEventModifierFlagControl : 0 timestamp:uptime()
                                     windowNumber:window.windowNumber context:nil characters:characters
                      charactersIgnoringModifiers:ignoring isARepeat:NO keyCode:keyCode(plain)];
        if (down) [NSApp postEvent:down atStart:NO];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(typeGap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeKeys(text, at + 1);
    });
}

/// The first terminal in view under `view`.
static NSView *terminalIn(NSView *view, Class terminal) {
    if ([view isKindOfClass:terminal] && !view.isHiddenOrHasHiddenAncestor && view.bounds.size.height > 0) return view;
    for (NSView *sub in view.subviews) {
        NSView *found = terminalIn(sub, terminal);
        if (found) return found;
    }
    return nil;
}

/// A click in the middle of the key window's terminal, as you would give it the keyboard (a tab an agent opened waits
/// for that): a mouse down and up at one point, so nothing is selected.
static void clickTerminal(void) {
    NSWindow *window = NSApp.keyWindow;
    Class terminal = NSClassFromString(@"SwiftTerm.TerminalView");
    NSView *view = window && terminal ? terminalIn(window.contentView.superview ?: window.contentView, terminal) : nil;
    if (!view) return;
    NSPoint point = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
        NSEvent *click = [NSEvent mouseEventWithType:(NSEventType)type.integerValue location:point modifierFlags:0 timestamp:uptime()
                                        windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        if (click) [NSApp postEvent:click atStart:NO];
    }
}

/// The keys run.py asked for, once the file is there: the terminal is clicked first, and the keys start a moment after.
static void typeIfAsked(void) {
    if (!typePath[0]) return;
    NSString *text = [NSString stringWithContentsOfFile:@(typePath) encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    unlink(typePath);
    clickTerminal();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        stamp([NSString stringWithFormat:@"typing %.6f", uptime()]);
        typeKeys(text, 0);
    });
}

static void stampGhost(void) {
    Class terminal = NSClassFromString(@"SwiftTerm.TerminalView");
    Method send = class_getInstanceMethod([NSApplication class], @selector(sendEvent:));
    IMP sent = method_getImplementation(send);
    method_setImplementation(send, imp_implementationWithBlock(^(NSApplication *app, NSEvent *event) {
        if (event.type == NSEventTypeKeyDown && terminal && [event.window.firstResponder isKindOfClass:terminal]) {
            stamp([NSString stringWithFormat:@"key %.6f", uptime()]);
        }
        ((void (*)(id, SEL, NSEvent *))sent)(app, @selector(sendEvent:), event);
    }));
    Class ghost = NSClassFromString(@"NTGhostText");
    if (!ghost) return;
    Method shown = class_getInstanceMethod(ghost, @selector(ghostShown:));
    if (shown) {
        IMP original = method_getImplementation(shown);
        method_setImplementation(shown, imp_implementationWithBlock(^(id view, double arrival) {
            stamp([NSString stringWithFormat:@"shown %.6f %.6f", arrival, uptime()]);
            ((void (*)(id, SEL, double))original)(view, @selector(ghostShown:), arrival);
        }));
    }
    Method draw = class_getInstanceMethod(ghost, @selector(drawRect:));
    if (draw) {
        IMP original = method_getImplementation(draw);
        method_setImplementation(draw, imp_implementationWithBlock(^(id view, NSRect rect) {
            stamp([NSString stringWithFormat:@"draw %.6f", uptime()]);
            ((void (*)(id, SEL, NSRect))original)(view, @selector(drawRect:), rect);
        }));
    }
    logLine([NSString stringWithFormat:@"suggestions while typing: stamped %s%s", shown ? "ghostShown: " : "", draw ? "drawRect:" : ""]);
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
    const char *ty = getenv("NT_SHIM_TYPE"), *gap = getenv("NT_SHIM_TYPE_GAP_MS");
    snprintf(logPath, sizeof logPath, "%s", p ? p : "/dev/null");
    snprintf(statusPath, sizeof statusPath, "%s", st ? st : "/dev/null");
    snprintf(typePath, sizeof typePath, "%s", ty ? ty : "");
    if (st) snprintf(samplesPath, sizeof samplesPath, "%s.ghost", st);
    if (gap && atoi(gap) > 0) typeGap = atoi(gap) / 1000.0;
    front = fr && fr[0] == '1';
    const char *home = getenv("HOME"), *fixed = getenv("CFFIXED_USER_HOME");
    logLine([NSString stringWithFormat:@"home %s %s | %@", home ? home : "(none)", fixed ? fixed : "(none)", NSHomeDirectory()]);
    // The tabs' shells and programs never see the shim.
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("NT_SHIM_LOG");
    unsetenv("NT_SHIM_STATUS");
    unsetenv("NT_SHIM_FRONT");
    unsetenv("NT_SHIM_TYPE");
    unsetenv("NT_SHIM_TYPE_GAP_MS");
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
        stampGhost();
        logLine([NSString stringWithFormat:@"shim loaded pid %d, counting draws %s, top tabs %s, tab-list rows %s", getpid(),
                 m ? "yes" : "NO", tabClasses ? "yes" : "no", rowClasses ? "yes" : "no"]);
        sources[2] = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(sources[2], DISPATCH_TIME_NOW, NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(sources[2], ^{
            writeStatus();
            flushSamples();
            typeIfAsked();
        });
        dispatch_resume(sources[2]);
        toFront();
    });
}
