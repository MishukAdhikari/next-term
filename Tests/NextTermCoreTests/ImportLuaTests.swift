import Foundation
import Testing
@testable import NextTermCore

/// The static scan of Lua configs: values written out are kept, anything Lua works out is only named, and nothing
/// is ever run. Hostile files are refused quickly.
@Suite struct ImportLuaTests {
    @Test func literalAssignmentsAndTheReturnedTable() {
        let scan = LuaConfigScan("""
            local wezterm = require 'wezterm'
            local act = wezterm.action
            local config = wezterm.config_builder()
            config.font_size = 13.5
            config.enable_tab_bar = false
            config.color_scheme = "Batman"
            config.colors = { foreground = '#ffffff', ansi = { '#000000', '#111111' } }
            config.colors.background = '#222222'
            config['scrollback_lines'] = 0x10
            config.font = wezterm.font('Fira Code', { weight = 'Bold' })
            config.keys = { { key = 't', mods = 'CMD', action = act.SpawnTab 'CurrentPaneDomain' } }
            return config
            """)
        #expect(!scan.unreadable && scan.computed.isEmpty)
        #expect(scan.fields["font_size"] == .number(13.5))
        #expect(scan.fields["enable_tab_bar"] == .bool(false))
        #expect(scan.fields["color_scheme"] == .string("Batman"))
        #expect(scan.fields["colors"]?["background"] == .string("#222222"))
        let ansi: Int? = scan.fields["colors"]?["ansi"]?.items?.count
        #expect(ansi == 2)
        #expect(scan.fields["scrollback_lines"] == .number(16))
        #expect(scan.fields["font"] == .call("wezterm.font", [.string("Fira Code"), .table(items: [], fields: ["weight": .string("Bold")])]))
        let key = scan.fields["keys"]?.items?.first
        #expect(key?["action"] == .call("wezterm.action.SpawnTab", [.string("CurrentPaneDomain")]))

        let returned = LuaConfigScan("return { font_size = 12, keys = {} }")
        #expect(returned.fields["font_size"] == .number(12))
    }

    @Test func codeIsNamedNeverKept() {
        let scan = LuaConfigScan("""
            local wezterm = require 'wezterm'
            local config = {}
            local size = 14
            config.font_size = size                -- a variable
            config.line_height = 1 + 0.2           -- an operator
            config.font = wezterm.font(os.getenv('FONT'))
            config.window_padding = { left = size }
            config.term = 'xterm'
            if wezterm.target_triple:find('darwin') then
              config.term = 'wezterm'             -- inside an if: code may change it
            end
            for _, name in ipairs({ 'a' }) do config.default_cursor_style = name end
            wezterm.on('gui-startup', function() config.initial_cols = 80 end)
            os.execute('rm -rf /')                  -- a call: never run
            config.colors = require('colors')
            return config
            """)
        #expect(!scan.unreadable)
        // A table with code in it is kept, and named as partly code.
        #expect(Array(scan.fields.keys) == ["window_padding"] && scan.partlyComputed == ["window_padding"])
        let names = Set(scan.computed)
        let expected: Set<String> = ["font_size", "line_height", "font", "term", "default_cursor_style", "initial_cols", "colors"]
        #expect(names == expected)
    }

    @Test func tokensStringsAndComments() throws {
        let tokens = try #require(LuaTokens.read(#"""
            -- a comment
            --[==[ a long
            comment ]] still ]==]
            local s = [[
            long string]] .. 'a\'b' .. "c\nd" -- tail
            x = 1e3 + 0x1F + .5 // 2 ~= 3
            """#))
        #expect(tokens.contains(.string("long string")))
        #expect(tokens.contains(.string("a'b")))
        #expect(tokens.contains(.string("c\nd")))
        #expect(tokens.contains(.number(1000)) && tokens.contains(.number(31)) && tokens.contains(.number(0.5)))
        #expect(tokens.contains(.symbol("~=")) && tokens.contains(.symbol("//")) && tokens.contains(.symbol("..")))
        #expect(!tokens.contains(.name("comment")))
    }

    /// Hostile files: left open, too deep, too big, not Lua. Each is refused whole and quickly.
    @Test func hostileInput() {
        let unreadable = [
            "local s = 'open",
            "local s = [[ never closed",
            "--[[ a comment never closed",
            "config.x = {{{{",
            "return config end",
            "config.x = ` backtick",
            "local function f( return",
            "if x then",
        ]
        for text in unreadable {
            #expect(LuaConfigScan(text).unreadable, "\(text)")
        }
        let deepTables = "return { a = " + String(repeating: "{", count: 5_000) + String(repeating: "}", count: 5_000) + " }"
        #expect(LuaConfigScan(deepTables).unreadable)
        let deepParens = "return { a = " + String(repeating: "(", count: 5_000) + "1" + String(repeating: ")", count: 5_000) + " }"
        #expect(LuaConfigScan(deepParens).unreadable)
        let deepBlocks = String(repeating: "do ", count: 5_000) + String(repeating: "end ", count: 5_000)
        #expect(LuaConfigScan(deepBlocks).unreadable)
        let huge = String(repeating: "-- filler\n", count: LuaConfigScan.maxBytes / 10 + 10)
        #expect(LuaConfigScan(huge).unreadable)
        // A long but flat file is read.
        let many = "local config = {}\n" + (0..<5_000).map { "config.k\($0) = \($0)" }.joined(separator: "\n") + "\nreturn config"
        let scan = LuaConfigScan(many)
        #expect(!scan.unreadable && scan.fields.count == 5_000)
    }
}
