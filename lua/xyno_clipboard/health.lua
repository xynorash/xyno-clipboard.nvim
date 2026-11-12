-- :checkhealth xyno_clipboard
local M = {}

function M.check()
  local h = vim.health
  local c = require("xyno_clipboard")
  h.start("xyno-clipboard")

  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.12 or newer is required")
  end
  if vim.fn.has("linux") ~= 1 then
    h.info("not Linux: the provider is never installed here (by design)")
    return
  end

  local st = c.status()
  if st.active then
    h.ok("provider active (" .. st.reason .. ")")
  else
    h.info("provider not installed: " .. (st.skipped or "setup() has not run"))
  end

  local function exe(n)
    return vim.fn.executable(n) == 1
  end
  local tools = {}
  for _, n in ipairs({ "wl-copy", "wl-paste", "xclip", "xsel" }) do
    tools[#tools + 1] = n .. "=" .. (exe(n) and "yes" or "no")
  end
  h.info(
    "tools: "
      .. table.concat(tools, " ")
      .. "; WAYLAND_DISPLAY="
      .. tostring(vim.env.WAYLAND_DISPLAY)
      .. " DISPLAY="
      .. tostring(vim.env.DISPLAY)
  )
  if vim.env.WAYLAND_DISPLAY and not (exe("wl-copy") and exe("wl-paste")) then
    h.warn(
      "Wayland session without wl-copy/wl-paste",
      { "install wl-clipboard (pacman -S wl-clipboard / apt install wl-clipboard)" }
    )
  elseif
    not vim.env.WAYLAND_DISPLAY
    and not vim.env.DISPLAY
    and not (exe("win32yank.exe") or exe("lemonade") or exe("doitclient") or exe("termux-clipboard-get"))
  then
    h.info(
      "no display and no native clipboard tool: copies can only go to the terminal (OSC 52), pasting returns your last yank"
    )
  end

  local o = c.config()
  h.info(
    ("tmux = %s, max_bytes = %d, on_exceed = %s, chunk_bytes = %d, osc52 = %s%s"):format(
      o.tmux,
      o.max_bytes,
      o.on_exceed,
      o.chunk_bytes,
      tostring(o.osc52),
      vim.g.xyno_clipboard_osc52 == false and " (vim.g.xyno_clipboard_osc52 = false: off now)" or ""
    )
  )

  if vim.env.TMUX == nil then
    if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
      h.info(
        "SSH session without tmux: OSC 52 goes straight to your terminal, which must allow it (kitty: clipboard_control, WezTerm/Ghostty/iTerm2: allow clipboard write; Neovim cannot detect this)"
      )
    end
  else
    if not exe("tmux") then
      h.warn("$TMUX is set but no tmux binary is on $PATH: cannot check tmux's clipboard settings")
    else
      local t = c.query_tmux()
      h.info(
        ("%s; set-clipboard = %s; allow-passthrough = %s; client terminal features = %s"):format(
          t.version or "tmux ?",
          t.set_clipboard or "?",
          t.allow_passthrough or "(unsupported or unset)",
          (t.features and t.features ~= "") and t.features or "(no attached client)"
        )
      )
      local route = c.route()
      if t.set_clipboard == "on" then
        h.ok("set-clipboard is on: tmux turns nvim's OSC 52 into a paste buffer and forwards it to the terminal")
      elseif t.allow_passthrough == "on" or t.allow_passthrough == "all" then
        h.ok(
          "allow-passthrough is on: copies are wrapped in a tmux DCS passthrough and reach the terminal directly (no tmux paste buffer)"
        )
      elseif t.set_clipboard == nil then
        h.warn("tmux did not answer `show-options -gv set-clipboard`: its settings could not be checked")
      elseif route == "raw" then
        h.warn('tmux = "raw" is forced but set-clipboard is ' .. t.set_clipboard .. ": tmux drops the sequence")
      else
        h.error(
          ("tmux ignores OSC 52 sent by applications (set-clipboard = %s, allow-passthrough = %s): yanks never reach any clipboard"):format(
            t.set_clipboard,
            t.allow_passthrough or "off"
          ),
          {
            "set -g set-clipboard on        (tmux.conf; tmux creates a paste buffer and forwards)",
            "or set -g allow-passthrough on  (tmux >= 3.3; sequences go straight to the terminal)",
            "See https://github.com/tmux/tmux/wiki/Clipboard",
          }
        )
      end
      if t.features and t.features ~= "" then
        if t.features:find("clipboard", 1, true) then
          h.ok("the attached terminal has tmux's `clipboard` feature (Ms): tmux forwards to it")
        else
          h.warn(
            "the attached terminal lacks tmux's `clipboard` feature, so tmux will not forward OSC 52 to it",
            { "set -as terminal-features ',<your TERM>:clipboard'" }
          )
        end
      end
    end
  end

  local hint = c.hint()
  if hint then
    h.warn(hint.text, { hint.fix })
  elseif st.active then
    h.ok("no clipboard problem detected")
  end
  local skipped = c.last_skipped()
  if skipped then
    h.warn(
      ("a yank of %d base64 characters was not sent as OSC 52 (max_bytes = %d)"):format(skipped.bytes, o.max_bytes),
      { 'raise max_bytes, or on_exceed = "send"' }
    )
  end
  for _, g in ipairs(c.highlight_groups) do
    if next(vim.api.nvim_get_hl(0, { name = g, link = true })) == nil then
      h.warn("highlight group " .. g .. " is not defined")
    end
  end
end

return M
