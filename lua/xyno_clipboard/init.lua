-- Clipboard for sessions whose yanks may need to reach another machine:
-- every copy is emitted as OSC 52 (inside tmux this becomes a tmux buffer,
-- rebroadcast to every attached client, local or SSH). Paste prefers the
-- local Wayland clipboard when one is available, so content copied in other
-- apps remains pasteable; without a display, paste is an OSC 52 query that
-- tmux (or the terminal) answers.
local M = {}

local state = { active = false, reason = nil, skipped = nil }
local NAME = "XynoClipboard"

local INSTALL_HINT = "install wl-clipboard (Wayland) or xclip/xsel (X11), e.g. `pacman -S wl-clipboard`"

-- one-shot notices: each message key is shown at most once per session
local notified = {}
local function notify_once(key, msg, level)
  if notified[key] then
    return
  end
  notified[key] = true
  vim.notify("xyno-clipboard: " .. msg, level or vim.log.levels.WARN)
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

local defaults = {
  commands = true, -- register :XynoClipboardStatus
  osc52 = true, -- emit OSC 52 on copy (also switchable at runtime with vim.g.xyno_clipboard_osc52 = false)
}

local function status_lines()
  if state.active then
    return { "xyno-clipboard: active (" .. state.reason .. "), vim.g.clipboard = " .. vim.g.clipboard.name }
  end
  return { "xyno-clipboard: inactive (" .. (state.skipped or "setup() has not run") .. ")" }
end

--- The current state: { active = bool, reason = string|nil, skipped = string|nil }.
function M.status()
  return vim.deepcopy(state)
end

function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})
  state = { active = false }

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
        emit(lines)
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

--- Forget which one-shot notices were shown (for tests).
function M._reset_notices()
  notified = {}
end

return M
