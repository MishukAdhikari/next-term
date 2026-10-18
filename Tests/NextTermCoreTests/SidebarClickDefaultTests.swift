import Foundation
import Testing
@testable import NextTermCore

/// Each test has a defaults domain of its own, removed after: never the app's.
@Suite struct SidebarClickDefaultTests {
    static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "NextTermCoreTests.singleClick.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("no defaults domain \(name)")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func theRule() {
        #expect(SidebarClick.firstLaunchValue(stored: nil, usedBefore: false) == true)
        #expect(SidebarClick.firstLaunchValue(stored: nil, usedBefore: true) == false)
        #expect(SidebarClick.firstLaunchValue(stored: true, usedBefore: true) == nil)
        #expect(SidebarClick.firstLaunchValue(stored: false, usedBefore: false) == nil)
    }

    @Test func aNewInstallGetsSingleClicks() {
        Self.withDefaults { defaults in
            #expect(SidebarClick.settleDefault(in: defaults) == true)
            #expect(defaults.object(forKey: SidebarClick.settingKey) as? Bool == true)
        }
    }

    /// Any one sign of an install used before keeps it on double clicks, an empty session list too.
    @Test func anInstallUsedBeforeKeepsDoubleClicks() {
        let markers: [(String, Any)] = [("sessionProjects", [String]()), ("sessionProjects", ["/tmp/p"]), ("recentProjects", ["/tmp/p"]),
                                        ("lastUpdateCheck", 1_700_000_000.0), ("lastUpdateFailure", 1_700_000_000.0), ("importOffered", true)]
        for (key, value) in markers {
            Self.withDefaults { defaults in
                defaults.set(value, forKey: key)
                #expect(SidebarClick.settleDefault(in: defaults) == false, "\(key)")
                #expect(defaults.object(forKey: SidebarClick.settingKey) as? Bool == false, "\(key)")
            }
        }
        #expect(Set(markers.map(\.0)) == Set(SidebarClick.usedInstallKeys))
    }

    @Test func aChoiceMadeIsNeverChanged() {
        for stored in [true, false] {
            for used in [true, false] {
                Self.withDefaults { defaults in
                    defaults.set(stored, forKey: SidebarClick.settingKey)
                    if used { defaults.set([String](), forKey: "sessionProjects") }
                    #expect(SidebarClick.settleDefault(in: defaults) == nil, "stored \(stored), used \(used)")
                    #expect(defaults.object(forKey: SidebarClick.settingKey) as? Bool == stored, "stored \(stored), used \(used)")
                }
            }
        }
    }

    /// Decided once: the next launch finds the value and writes nothing, though the install is used by then.
    @Test func aSecondLaunchWritesNothing() {
        Self.withDefaults { defaults in
            #expect(SidebarClick.settleDefault(in: defaults) == true)
            defaults.set(["/tmp/p"], forKey: "sessionProjects")
            #expect(SidebarClick.settleDefault(in: defaults) == nil)
            #expect(defaults.object(forKey: SidebarClick.settingKey) as? Bool == true)
        }
    }
}
