# Changelog

## Unreleased

- tmux awareness: `set-clipboard`, `allow-passthrough` and the client's terminal features are read from tmux (setup, FocusGained, and again on a copy while the route is "drop"). `tmux = "auto"` sends raw OSC 52 when `set-clipboard on`, a DCS passthrough when only `allow-passthrough` is on, and warns when neither is (tmux then drops nvim's OSC 52: checked with tmux 3.8, a real TUI nvim and nested tmux servers, 2026-11-12).
- `max_bytes` / `on_exceed` for over-long copies, `chunk_bytes` for the passthrough; option validation (one warning, defaults kept).
- `statusline()`, `statusline_hl()`, `hint()`, `route()`, `tmux()`, `query_tmux()`, `last_skipped()`, `config()`; highlight groups `XynoClipboardWarn/Error/Ok` (links to Diagnostic groups).
- `:checkhealth xyno_clipboard`; `:XynoClipboardStatus` also prints the hint and its fix.
- One-shot notices are single-line and, without a UI, the command line is cleared after them: a leftover multi-line notice made the next message end in a hit-enter prompt, which hung xynovim's headless `local-history` spec on a machine without clipboard tools.
- Tests: 33 (was 15), three with real tmux servers.
