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
  commands = true,      -- register :XynoClipboardStatus
  osc52 = true,         -- emit OSC 52 on copy
  tmux = "auto",        -- "auto" | "raw" | "passthrough": how the sequence travels inside tmux
  max_bytes = 1000000,  -- longest base64 payload sent as OSC 52 (0 = no limit)
  on_exceed = "skip",   -- "skip" (say so once) | "send" (try anyway) for a longer one
  chunk_bytes = 4096,   -- piece size of the tmux passthrough (64 .. 1000000)
  hint = true,          -- statusline() text when something is missing
})
```

Invalid values are reported once and ignored. `vim.g.xyno_clipboard_osc52 = false` stops the OSC 52 emit at runtime (the local Wayland copy still happens). No global keymaps are set; the plugin has no dependencies on other plugins.

### tmux

Neovim writes a bare OSC 52. tmux only accepts that from an application when `set-clipboard` is `on`; the default is `external`, which makes tmux drop it: yanks silently go nowhere. Checked here with tmux 3.8 and a real TUI Neovim (2026-11-12): `set-clipboard external` gives no paste buffer at all, `on` gives one and forwards it to the terminal. The tmux wiki says the same about `on` ([Clipboard](https://github.com/tmux/tmux/wiki/Clipboard)). So with `tmux = "auto"` the plugin asks tmux (`show-options -gv set-clipboard`, `allow-passthrough`, the attached client's terminal features) at `setup()` and on `FocusGained`, and:

| tmux says | copy goes | what you see |
| --- | --- | --- |
| `set-clipboard on` | raw OSC 52; tmux makes a paste buffer and forwards it | nothing |
| otherwise, `allow-passthrough on` or `all` (tmux 3.3+) | wrapped in `ESC P tmux; ... ESC \` in pieces of `chunk_bytes`; straight to the terminal, **no tmux paste buffer** | nothing |
| otherwise | raw OSC 52 anyway (it is all Neovim can do) | `clip: tmux drops OSC52` in `statusline()`, one notice with the fix, `:checkhealth xyno_clipboard` as an error |
| tmux does not answer | raw (as before) | nothing |

When the answer changes (you edit tmux.conf) the next copy asks again, at most every 5 seconds, while the route is "drop". The attached client's terminal must also have tmux's `clipboard` feature (tmux adds it for `xterm*`; otherwise `set -as terminal-features ',<TERM>:clipboard'`): when the client reports features without it, the hint says so. Measured with a nested pair of tmux servers (the outer one standing in for the terminal): passthrough with `set-clipboard external` reached the outer one, and `external` without passthrough reached nothing (spec `tests/specs/robust_spec.lua`).

### Size limit and chunking

A longer OSC 52 is silently dropped by some terminals and multiplexers; there is no common figure (a search on 2026-11-12 found one blog quoting about 75 kB of base64 as typical for some terminals, no authoritative table; vim-oscyank, which has a max-length option, defaults to unlimited). I could not verify limits per terminal, so `max_bytes` is yours to tune: a copy whose base64 payload is longer is not sent as OSC 52 (`on_exceed = "skip"`: one notice with the size, `last_skipped()` and `:checkhealth` remember it; the Wayland copy still happens) or is sent anyway (`"send"`). The default 1,000,000 characters is a guess at "bigger than anything tmux and the usual terminals refuse", not a measured limit. `chunk_bytes` only splits what the plugin writes itself (the tmux passthrough, one DCS wrapper per piece, tmux forwards the pieces in order and the terminal sees one sequence). The raw path is Neovim's own writer, in one piece.

### Statusline

`require("xyno_clipboard").statusline()` returns `""` when nothing is wrong, else `clip: no tool` (no `wl-clipboard`/`xclip`/`xsel`; OSC 52 copy only), `clip: no wl-copy` (Wayland without the tools), `clip: tmux drops OSC52` or `clip: no tmux clipboard`; the second return value is the group (`XynoClipboardWarn` or `XynoClipboardError`, links to `DiagnosticWarn`/`DiagnosticError`, also `XynoClipboardOk`; your own colours are kept). `statusline_hl()` returns just the group. `hint()` returns `{ kind, text, fix, level }`. For lualine: `{ function() return (require("xyno_clipboard").statusline()) end, cond = function() return package.loaded["xyno_clipboard"] ~= nil and require("xyno_clipboard").statusline() ~= "" end, color = function() return require("xyno_clipboard").statusline_hl() end }`.

## Commands

- `:XynoClipboardStatus` shows whether the provider is active and why, or why it is not, plus the current hint and its fix.
- `:checkhealth xyno_clipboard`: tools found, the display variables, the effective options, and in tmux its version, `set-clipboard`, `allow-passthrough`, the client's terminal features, the route a copy takes and what to change; an SSH session without tmux is reminded that the terminal must allow OSC 52 (not detectable).

## Lua API

- `require("xyno_clipboard").setup(opts)`
- `require("xyno_clipboard").status()` returns `{ active, reason, skipped }`.
- `.statusline()`, `.statusline_hl()`, `.hint()`, `.route()` (`"raw"`, `"passthrough"` or `"dropped"`), `.tmux()` (facts last seen), `.query_tmux()` (asks now, blocking), `.last_skipped()`, `.config()`.

## Keys

None. It works through the normal `"+` and `"*` registers (for example with `vim.o.clipboard = "unnamedplus"`).

## How it works

The provider is installed only when `$TMUX`, `$SSH_TTY`, `$SSH_CONNECTION` or `$HERDR_PANE_ID` is set, or when an ancestor process (up to 16 levels, read from `/proc`) has a name containing `herdr`. Copy queues `wl-copy --sensitive --type text/plain` (run in the background, in order, killed after 3 s) when Wayland tools are present, then emits OSC 52. Paste uses `wl-paste --no-newline` in that case, otherwise an OSC 52 query that tmux or the terminal has to answer. In a plain local session the provider is also installed when Neovim has nothing to work with (no `wl-copy`+`wl-paste` on Wayland, no `xclip` or `xsel` on X11, none of the other native tools): copy is then OSC 52 only, paste returns the last copy of the session, and a single notice names the missing package. A `vim.g.clipboard` set by the user is never replaced there. A failing `wl-copy` is reported once (the OSC 52 copy still happens). Otherwise nothing is installed. Limits: SSH without tmux depends on the terminal allowing OSC 52 and the plugin cannot see that; a linewise yank is sent without its trailing newline (Neovim's own OSC 52 writer does that); tmux facts are read from the tmux of `$TMUX` only, so a nested or remote tmux between you and the terminal is not seen.

## Platforms

- Linux: covered by the specs in this repository (`nvim -l tests/run.lua`, 41 tests, including three that run real tmux servers; they skip without tmux). The fake `wl-copy` flow is covered by stubs here and by xynovim's `clipboard-e2e` spec.
- Windows and macOS: Linux only by design. `setup()` returns early without installing anything. In xynovim's own CI this module was skipped on both, so nothing about it is demonstrated there.

## Extracted from xynovim

This is the clipboard module of my Neovim config, [xynovim](https://github.com/xynorash/xynovim), published on its own. Differences: the provider is named `XynoClipboard`, the runtime switch is `vim.g.xyno_clipboard_osc52`, and `setup(opts)`, `status()` and `:XynoClipboardStatus` are new.

## License

MIT, see [LICENSE](LICENSE).
