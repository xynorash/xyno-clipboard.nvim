# xyno-clipboard.nvim

A Neovim clipboard provider for sessions whose yanks must reach another machine: tmux, SSH and herdr panes get OSC 52 copy, with sensible detection and no change anywhere else.

## Why

I work in tmux over SSH a lot. The default clipboard detection picks nothing useful there, and a plain OSC 52 provider breaks pasting from other applications on my Wayland desktop. This one copies through OSC 52 (inside tmux that becomes a tmux buffer shared by every attached client) and, when a local Wayland clipboard exists, also keeps it in sync and pastes from it.

## Requirements

- Neovim 0.12+
- Linux (see Platforms)
- Optional: `wl-copy` and `wl-paste` with `WAYLAND_DISPLAY` set

## Install (lazy.nvim)

```lua
{
  "xynorash/xyno-clipboard.nvim",
  lazy = false, -- the provider should exist before the first yank
  opts = {},
}
```

## Options

```lua
require("xyno_clipboard").setup({
  commands = true, -- register :XynoClipboardStatus
  osc52 = true,    -- emit OSC 52 on copy
})
```

`vim.g.xyno_clipboard_osc52 = false` stops the OSC 52 emit at runtime (the local Wayland copy still happens). No global keymaps are set; the plugin has no dependencies on other plugins.

## Commands

- `:XynoClipboardStatus` shows whether the provider is active and why, or why it is not.

## Lua API

- `require("xyno_clipboard").setup(opts)`
- `require("xyno_clipboard").status()` returns `{ active, reason, skipped }`.

## Keys

None. It works through the normal `"+` and `"*` registers (for example with `vim.o.clipboard = "unnamedplus"`).

## How it works

The provider is installed only when `$TMUX`, `$SSH_TTY`, `$SSH_CONNECTION` or `$HERDR_PANE_ID` is set, or when an ancestor process (up to 16 levels, read from `/proc`) has a name containing `herdr`. Copy runs `wl-copy --sensitive --type text/plain` first when Wayland tools are present, then emits OSC 52. Paste uses `wl-paste --no-newline` in that case, otherwise an OSC 52 query that tmux or the terminal has to answer. In a plain local session the provider is also installed when Neovim has nothing to work with (no `wl-copy`+`wl-paste` on Wayland, no `xclip` or `xsel` on X11, none of the other native tools): copy is then OSC 52 only, paste returns the last copy of the session, and a single notice names the missing package. A `vim.g.clipboard` set by the user is never replaced there. A failing `wl-copy` is reported once (the OSC 52 copy still happens). Otherwise nothing is installed.

## Platforms

- Linux: covered by the specs in this repository (`nvim -l tests/run.lua`).
- Windows and macOS: Linux only by design. `setup()` returns early without installing anything. In xynovim's own CI this module was skipped on both, so nothing about it is demonstrated there.

## Extracted from xynovim

This is the clipboard module of my Neovim config, [xynovim](https://github.com/xynorash/xynovim), published on its own. Differences: the provider is named `XynoClipboard`, the runtime switch is `vim.g.xyno_clipboard_osc52`, and `setup(opts)`, `status()` and `:XynoClipboardStatus` are new.

## License

MIT, see [LICENSE](LICENSE).
