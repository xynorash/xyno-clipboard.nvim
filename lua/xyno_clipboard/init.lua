-- Clipboard for sessions whose yanks may need to reach another machine:
-- every copy is emitted as OSC 52 (inside tmux this becomes a tmux buffer,
-- rebroadcast to every attached client, local or SSH). Paste prefers the
-- local Wayland clipboard when one is available, so content copied in other
-- apps remains pasteable; without a display, paste is an OSC 52 query that
-- tmux (or the terminal) answers.
local M = {}

local state = { active = false, reason = nil, skipped = nil }

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
  if not reason then
    state.skipped = "no tmux, ssh or herdr session detected"
    return
  end

  local osc52 = require("vim.ui.clipboard.osc52")
  local has_wayland = vim.env.WAYLAND_DISPLAY ~= nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1

  local function copy(register)
    local emit = osc52.copy(register)

    return function(lines)
      if has_wayland then
        local cmd = { "wl-copy", "--sensitive", "--type", "text/plain" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
        vim.fn.system(cmd, lines)
      end

      if opts.osc52 and vim.g.xyno_clipboard_osc52 ~= false then
        emit(lines)
      end
    end
  end

  local function paste(register)
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
    name = "XynoClipboard",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }
  state.active, state.reason = true, reason
end

return M
