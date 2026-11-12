-- Clipboard for sessions whose yanks may need to reach another machine:
-- every copy is emitted as OSC 52 (inside tmux this becomes a tmux buffer,
-- rebroadcast to every attached client, local or SSH). Paste prefers the
-- local Wayland clipboard when one is available, so content copied in other
-- apps remains pasteable; without a display, paste is an OSC 52 query that
-- tmux (or the terminal) answers.
local M = {}

local state = { active = false, reason = nil, skipped = nil }
local ext = {} -- internals beside the public state(): fallback, has_wayland, tmux, skipped_copy
local NAME = "XynoClipboard"

local INSTALL_HINT = "install wl-clipboard (Wayland) or xclip/xsel (X11), e.g. `pacman -S wl-clipboard`"

-- one-shot notices: each message key is shown at most once per session
local notified = {}
local function notify_once(key, msg, level)
  if notified[key] then
    return
  end
  notified[key] = true
  -- one line: a multi-line message in a UI-less nvim ends in a "Press ENTER" prompt that swallows the next
  -- command (it hung xynovim's headless local-history spec until the notice was joined)
  vim.notify("xyno-clipboard: " .. msg:gsub("%s*\n%s*", " "), level or vim.log.levels.WARN)
  if #vim.api.nvim_list_uis() == 0 then
    -- no UI to show it: the line would stay on the command line and the next message would end in
    -- "Press ENTER" (it hung xynovim's headless local-history spec). It stays in :messages.
    pcall(vim.cmd, "echo ''")
  end
end

--- True when a native provider Neovim itself would pick is usable. Probed by
--- hand (not provider#clipboard#Executable) so it cannot be fooled by a
--- provider cached earlier or by our own vim.g.clipboard.
local function native_tool()
  local function exe(n)
    return vim.fn.executable(n) == 1
  end
  if exe("wl-copy") and exe("wl-paste") and vim.env.WAYLAND_DISPLAY ~= nil then
    return "wl-clipboard"
  end
  if exe("xclip") and vim.env.DISPLAY ~= nil then
    return "xclip"
  end
  if exe("xsel") and vim.env.DISPLAY ~= nil then
    return "xsel"
  end
  if exe("win32yank.exe") or exe("lemonade") or exe("doitclient") or exe("termux-clipboard-get") then
    return "other"
  end
end

-- Neovim loads the clipboard provider lazily and then caches it; when setup()
-- runs after the first clipboard use (or twice) the new vim.g.clipboard would
-- be ignored without this.
local function reload_provider()
  if vim.g.loaded_clipboard_provider ~= nil then
    vim.g.loaded_clipboard_provider = nil
    pcall(vim.cmd, "runtime autoload/provider/clipboard.vim")
  end
end

M.defaults = {
  commands = true, -- register :XynoClipboardStatus
  osc52 = true, -- emit OSC 52 on copy (also switchable at runtime with vim.g.xyno_clipboard_osc52 = false)
  -- Inside tmux: "auto" picks how the sequence travels from what tmux allows (set-clipboard on: raw
  -- OSC 52, which tmux turns into a paste buffer and forwards; else allow-passthrough on: wrapped in a
  -- tmux DCS passthrough, straight to the terminal, no tmux buffer; else raw, which tmux DROPS, and the
  -- statusline/health say so). "raw" and "passthrough" force one.
  tmux = "auto",
  -- A copy whose base64 payload is longer than this many characters is not sent as OSC 52 (many terminals
  -- and multiplexers drop an over-long sequence silently): on_exceed = "skip" says so once and leaves it
  -- to the Wayland clipboard; "send" sends it anyway. 0 = no limit.
  max_bytes = 1000000,
  on_exceed = "skip",
  -- The tmux passthrough is written in pieces of this many characters, each its own DCS wrapper (tmux
  -- forwards them in order, the terminal sees one OSC 52); raw OSC 52 is written by Neovim in one piece.
  chunk_bytes = 4096,
  -- one-line hint in the statusline component when a tool is missing (see M.statusline)
  hint = true,
}

local TMUX_MODES = { "auto", "raw", "passthrough" }

local function validate(opts)
  local clean, problems = {}, {}
  if type(opts) ~= "table" then
    return clean, opts == nil and {} or { "setup() takes a table" }
  end
  for k, v in pairs(opts) do
    local d = M.defaults[k]
    if d == nil then
      problems[#problems + 1] = "unknown option " .. tostring(k)
    elseif type(v) ~= type(d) then
      problems[#problems + 1] = ("%s: expected %s, got %s"):format(k, type(d), type(v))
    elseif (k == "max_bytes" and (v < 0 or v ~= v)) or (k == "chunk_bytes" and (v < 64 or v > 1000000)) then
      problems[#problems + 1] = k == "max_bytes" and "max_bytes: must be >= 0" or "chunk_bytes: must be between 64 and 1000000"
    elseif k == "tmux" and not vim.tbl_contains(TMUX_MODES, v) then
      problems[#problems + 1] = 'tmux: must be "auto", "raw" or "passthrough"'
    elseif k == "on_exceed" and v ~= "skip" and v ~= "send" then
      problems[#problems + 1] = 'on_exceed: must be "skip" or "send"'
    else
      clean[k] = v
    end
  end
  return clean, problems
end

local config = vim.deepcopy(M.defaults)

-- ---------------------------------------------------------------- tmux facts

--- Parse `set-clipboard`, `allow-passthrough`, version and the attached client's terminal features.
local function tmux_facts(out)
  local f = {}
  f.version = out.version
  f.set_clipboard = out.set_clipboard
  f.allow_passthrough = out.allow_passthrough
  f.features = out.features
  return f
end

local function tmux_cmd(args, timeout)
  local ok, o = pcall(function()
    return vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait(timeout or 1500)
  end)
  if ok and o and o.code == 0 then
    return vim.trim(o.stdout or "")
  end
end

--- Ask the running tmux (nvim's own server, through $TMUX). Blocking: setup() runs it in a job, :checkhealth waits.
--- @return table { version?, set_clipboard?, allow_passthrough?, features? }
function M.query_tmux()
  local out = {}
  out.version = tmux_cmd({ "-V" })
  out.set_clipboard = tmux_cmd({ "show-options", "-gv", "set-clipboard" })
  out.allow_passthrough = tmux_cmd({ "show-options", "-gv", "allow-passthrough" }) -- tmux >= 3.3
  out.features = tmux_cmd({ "display-message", "-p", "#{client_termfeatures}" }) -- empty without an attached client
  return tmux_facts(out)
end

--- How a copy travels inside tmux: "raw", "passthrough" or "dropped" (raw, but tmux ignores it).
local function tmux_route()
  if vim.env.TMUX == nil then
    return "raw"
  end
  if config.tmux == "raw" then
    return "raw"
  elseif config.tmux == "passthrough" then
    return "passthrough"
  end
  local t = ext.tmux
  if not t or t.set_clipboard == nil then
    return "raw" -- not known yet, or tmux did not answer: what nvim always did
  end
  if t.set_clipboard == "on" then
    return "raw"
  elseif t.allow_passthrough == "on" or t.allow_passthrough == "all" then
    return "passthrough"
  end
  return "dropped"
end

local function refresh_tmux()
  if vim.env.TMUX == nil or vim.fn.executable("tmux") ~= 1 then
    ext.tmux = nil
    return
  end
  local function run(args, key, acc, next_)
    local ok = pcall(vim.system, vim.list_extend({ "tmux" }, args), { text = true }, function(o)
      acc[key] = o.code == 0 and vim.trim(o.stdout or "") or nil
      next_()
    end)
    if not ok then
      next_()
    end
  end
  local acc, mine = {}, ext -- ext is replaced by setup(): a late answer belongs to the old session
  run({ "show-options", "-gv", "set-clipboard" }, "set_clipboard", acc, function()
    run({ "show-options", "-gv", "allow-passthrough" }, "allow_passthrough", acc, function()
      run({ "display-message", "-p", "#{client_termfeatures}" }, "features", acc, function()
        vim.schedule(function()
          if ext == mine then
            ext.tmux = tmux_facts(acc)
          end
        end)
      end)
    end)
  end)
end

--- Write `text` as OSC 52 through a tmux DCS passthrough, in pieces of config.chunk_bytes.
local function emit_passthrough(register, text)
  local seq = ("\27]52;%s;%s\27\\"):format(register == "+" and "c" or "p", vim.base64.encode(text))
  seq = seq:gsub("\27", "\27\27")
  local n = math.max(64, config.chunk_bytes)
  for i = 1, #seq, n do
    vim.api.nvim_ui_send("\27Ptmux;" .. seq:sub(i, i + n - 1) .. "\27\\")
  end
end

local function status_lines()
  if state.active then
    local lines = { "xyno-clipboard: active (" .. state.reason .. "), vim.g.clipboard = " .. vim.g.clipboard.name }
    local h = M.hint()
    if h then
      lines[#lines + 1] = "xyno-clipboard: " .. h.text .. " - " .. h.fix
    end
    return lines
  end
  return { "xyno-clipboard: inactive (" .. (state.skipped or "setup() has not run") .. ")" }
end

--- The current state: { active = bool, reason = string|nil, skipped = string|nil }.
function M.status()
  return vim.deepcopy(state)
end

function M.setup(opts)
  local clean, problems = validate(opts)
  if #problems > 0 then
    vim.notify("xyno-clipboard: ignored invalid options: " .. table.concat(problems, "; "), vim.log.levels.WARN)
  end
  opts = vim.tbl_deep_extend("force", M.defaults, clean)
  config = opts
  state = { active = false }
  ext = {}
  M._define_highlights()
  local group = vim.api.nvim_create_augroup("xyno_clipboard", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M._define_highlights })

  -- setup() twice must not mistake the provider it installed itself for a user's own
  local own = type(vim.g.clipboard) == "table" and vim.g.clipboard.name == NAME
  if own then
    vim.g.clipboard = nil
  end

  if opts.commands then
    vim.api.nvim_create_user_command("XynoClipboardStatus", function()
      vim.notify(table.concat(status_lines(), "\n"))
    end, { desc = "Show whether xyno-clipboard installed its provider" })
  end

  -- Linux only: the herdr detection walks /proc, and OSC 52 paste would replace
  -- the native providers (win32yank, pbcopy) with a query many terminals never answer.
  if vim.fn.has("linux") ~= 1 then
    state.skipped = "not Linux"
    return
  end

  local reason = require("xyno_clipboard.detect").reason()
  local fallback = false
  if not reason then
    -- A plain local session normally has Neovim's own providers. When none of them can
    -- work (no wl-clipboard, xclip or xsel) every yank used to vanish silently: copy via
    -- OSC 52 instead and say once what is missing.
    if vim.g.clipboard ~= nil then
      state.skipped = "vim.g.clipboard is set by the user"
      return
    end
    if native_tool() then
      state.skipped = "no tmux, ssh or herdr session detected"
      return
    end
    reason, fallback = "no clipboard tool", true
  end

  local osc52 = require("vim.ui.clipboard.osc52")
  local has_wayland = vim.env.WAYLAND_DISPLAY ~= nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1

  -- OSC 52 paste is a terminal query many terminals never answer, which freezes Neovim:
  -- with no native tool the fallback pastes what this session copied last.
  local last = { ["+"] = { { "" }, "v" }, ["*"] = { { "" }, "v" } }

  local function copy(register)
    local emit = osc52.copy(register)

    return function(lines, regtype)
      if fallback then
        last[register] = { lines, regtype or "v" }
      end
      if has_wayland then
        local cmd = { "wl-copy", "--sensitive", "--type", "text/plain" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
        local out = vim.fn.system(cmd, lines)
        if vim.v.shell_error ~= 0 then
          notify_once(
            "wl-copy",
            ("wl-copy failed (exit %d): %s\nThe yank was not copied to the Wayland clipboard."):format(
              vim.v.shell_error,
              vim.trim(out or "")
            )
          )
        end
      end

      if opts.osc52 and vim.g.xyno_clipboard_osc52 ~= false then
        local text = table.concat(lines, "\n")
        local b64 = math.ceil(#text / 3) * 4
        if config.max_bytes > 0 and b64 > config.max_bytes and config.on_exceed == "skip" then
          ext.skipped_copy = { bytes = b64, time = os.time() }
          notify_once(
            "oversize",
            ("a yank of %d base64 characters is over max_bytes (%d): not sent as OSC 52 (the Wayland clipboard, if any, got it). Raise max_bytes or set on_exceed = \"send\"."):format(
              b64,
              config.max_bytes
            )
          )
          return
        end
        local route = tmux_route()
        if route == "dropped" and os.time() - (ext.tmux_checked or 0) >= 5 then
          -- tmux.conf may have been changed since setup(): ask again (3 quick tmux calls), at most every 5 s
          ext.tmux_checked = os.time()
          ext.tmux = M.query_tmux()
          route = tmux_route()
        end
        if route == "passthrough" then
          emit_passthrough(register, text)
        else
          if route == "dropped" then
            notify_once("tmux-drops", M.hint().text .. ". Fix: " .. M.hint().fix)
          end
          emit(lines)
        end
      end
    end
  end

  local function paste(register)
    if fallback then
      return function()
        return last[register]
      end
    end
    if not has_wayland then
      return osc52.paste(register)
    end

    return function()
      local cmd = { "wl-paste", "--no-newline" }
      if register == "*" then
        cmd[#cmd + 1] = "--primary"
      end

      local lines = vim.fn.systemlist(cmd, "", 1)
      return vim.v.shell_error == 0 and lines or {}
    end
  end

  vim.g.clipboard = {
    name = NAME,
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }
  reload_provider()
  state.active, state.reason = true, reason
  ext.fallback, ext.has_wayland = fallback, has_wayland
  refresh_tmux()
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = refresh_tmux }) -- tmux.conf may have been sourced

  if fallback then
    vim.schedule(function()
      notify_once(
        "no-tool",
        "no clipboard tool found, so yanks go to the terminal via OSC 52 (copy only; pasting from other apps will not work).\nFix: "
          .. INSTALL_HINT
          .. ". :checkhealth provider shows what Neovim found."
      )
    end)
  elseif not has_wayland and vim.env.WAYLAND_DISPLAY ~= nil then
    vim.schedule(function()
      notify_once(
        "no-wl",
        "Wayland session but wl-copy/wl-paste are missing, so yanks only travel via OSC 52.\nFix: " .. INSTALL_HINT .. "."
      )
    end)
  end
end

--- The most important thing that keeps a copy from working as expected, or nil:
--- { kind, text, fix, level }. Kinds: "no-tool" (no native clipboard tool, OSC 52 copy only),
--- "no-wl" (Wayland session without wl-copy/wl-paste), "tmux-drops" (tmux ignores nvim's OSC 52),
--- "tmux-no-clipboard" (the attached terminal lacks tmux's clipboard feature).
--- @return { kind: string, text: string, fix: string, level: string }?
function M.hint()
  if not state.active then
    return nil
  end
  if ext.fallback then
    return { kind = "no-tool", level = "warn", text = "no clipboard tool: copy goes to the terminal via OSC 52 only, paste returns the last yank", fix = INSTALL_HINT }
  end
  if ext.tmux and tmux_route() == "dropped" then
    return {
      kind = "tmux-drops",
      level = "error",
      text = ("tmux ignores OSC 52 from applications (set-clipboard is %q, allow-passthrough %q)"):format(ext.tmux.set_clipboard or "?", ext.tmux.allow_passthrough or "off/unknown"),
      fix = "add `set -g set-clipboard on` (or `set -g allow-passthrough on`) to tmux.conf and reload it",
    }
  end
  if not ext.has_wayland and vim.env.WAYLAND_DISPLAY ~= nil then
    return { kind = "no-wl", level = "warn", text = "Wayland session without wl-copy/wl-paste: copies only travel via OSC 52", fix = INSTALL_HINT }
  end
  if ext.tmux and ext.tmux.features and ext.tmux.features ~= "" and not ext.tmux.features:find("clipboard", 1, true) and tmux_route() == "raw" then
    return {
      kind = "tmux-no-clipboard",
      level = "warn",
      text = "tmux does not know that your terminal has a clipboard (client features: " .. ext.tmux.features .. "), so it will not forward OSC 52",
      fix = "set -as terminal-features ',<your TERM>:clipboard' in tmux.conf",
    }
  end
end

--- Statusline text: "" when everything is fine, else a few words ("clip: no tool", "clip: tmux drops OSC52",
--- "clip: no wl-copy", "clip: no tmux clipboard"). With `hint = false` it is always "".
--- @return string text, string? highlight group
function M.statusline()
  if not config.hint then
    return "", nil
  end
  local h = M.hint()
  if not h then
    return "", nil
  end
  local words = { ["no-tool"] = "clip: no tool", ["no-wl"] = "clip: no wl-copy", ["tmux-drops"] = "clip: tmux drops OSC52", ["tmux-no-clipboard"] = "clip: no tmux clipboard" }
  return words[h.kind], h.level == "error" and "XynoClipboardError" or "XynoClipboardWarn"
end

function M.statusline_hl()
  local _, hl = M.statusline()
  return hl
end

local HL_LINKS = { XynoClipboardWarn = "DiagnosticWarn", XynoClipboardError = "DiagnosticError", XynoClipboardOk = "DiagnosticOk" }
M.highlight_groups = vim.tbl_keys(HL_LINKS)
function M._define_highlights()
  for g, l in pairs(HL_LINKS) do
    vim.api.nvim_set_hl(0, g, { link = l, default = true })
  end
end

--- The last yank that was not sent as OSC 52 because of max_bytes: { bytes, time } or nil.
function M.last_skipped()
  return ext.skipped_copy and vim.deepcopy(ext.skipped_copy) or nil
end

--- The effective options.
function M.config()
  return vim.deepcopy(config)
end

--- Facts about the running tmux as last seen by setup() / FocusGained (nil outside tmux).
function M.tmux()
  return ext.tmux and vim.deepcopy(ext.tmux) or nil
end

--- How a copy leaves nvim in this session: "raw", "passthrough" or "dropped" (see `tmux`).
function M.route()
  return tmux_route()
end

--- Forget which one-shot notices were shown (for tests).
function M._reset_notices()
  notified = {}
end

return M
