local path = "__WePlayChooChooTaxi__/graphics/"

data:extend({
  {
    type = "custom-input",
    name = "wp-choo-choo-taxi",
    key_sequence = "ALT + J",
    consuming = "game-only",
    order = "a",
  },
  {
    type = "shortcut",
    name = "wp-choo-choo-taxi",
    order = "m[wp-choo-choo-taxi]",
    action = "lua",
    toggleable = false,
    associated_control_input = "wp-choo-choo-taxi",
    icon = path .. "shortcut.png",
    icon_size = 64,
    small_icon = path .. "shortcut-small.png",
    small_icon_size = 32,
  },
  {
    type = "sprite",
    name = "wp-choo-choo-taxi-icon",
    filename = path .. "shortcut.png",
    size = 64,
  },
})
