-- kaku.lua in the shape Kaku writes it: its bundled defaults first (code, never run), then your overrides.
local wezterm = require 'wezterm'

local function resolve_bundled_config()
  local resource_dir = wezterm.executable_dir:gsub('MacOS/?$', 'Resources')
  local bundled = resource_dir .. '/kaku.lua'
  local f = io.open(bundled, 'r')
  if f then f:close(); return bundled end
  return '/Applications/Kaku.app/Contents/Resources/kaku.lua'
end

local config = {}
local bundled = resolve_bundled_config()
if bundled then
  local ok, loaded = pcall(dofile, bundled)
  if ok and type(loaded) == 'table' then config = loaded end
end

-- User overrides:
config.font_size = 16
config.color_scheme = "Kaku Dark"
config.send_composed_key_when_left_alt_is_pressed = true

table.insert(config.keys, {
  key = 'RightArrow',
  mods = 'CMD|SHIFT',
  action = wezterm.action.ActivatePaneDirection('Right'),
})

return config
