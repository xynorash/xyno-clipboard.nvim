-- xyno-clipboard: option validation, tmux routing (set-clipboard / allow-passthrough, with a fake tmux), size
-- limit, DCS passthrough framing and chunking, statusline hint, :checkhealth, and two real tmux sessions.
-- xyno-os: linux (reads /proc, uses sh stubs for tmux, and a real tmux)
local H = require("xynotest.helpers")

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local C = require("xyno_clipboard")

describe("xyno_clipboard robustness", function()
  local ENV = {
    "TMUX",
    "SSH_TTY",
    "SSH_CONNECTION",
    "HERDR_PANE_ID",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "PATH",
    "FSC",
    "FAP",
    "FFEAT",
  }
  local saved, real_osc52, real_send, real_notify, sent, msgs, emitted

  before_each(function()
    saved = { g = vim.g.clipboard, flag = vim.g.xyno_clipboard_osc52 }
    for _, k in ipairs(ENV) do
      saved[k] = vim.env[k]
    end
    real_osc52, real_send, real_notify = package.loaded["vim.ui.clipboard.osc52"], vim.api.nvim_ui_send, vim.notify
    vim.wait(30) -- notices that the previous test's setup() scheduled
    sent, msgs, emitted = {}, {}, {}
    vim.api.nvim_ui_send = function(s)
      sent[#sent + 1] = s
    end
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    -- raw OSC 52 is Neovim's: record instead of writing
    package.loaded["vim.ui.clipboard.osc52"] = {
      copy = function(reg)
        return function(lines)
          emitted[#emitted + 1] = { reg = reg, lines = lines }
        end
      end,
      paste = function()
        return function()
          return { "" }
        end
      end,
    }
    C._reset_notices()
    for _, k in ipairs({ "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID", "DISPLAY", "WAYLAND_DISPLAY" }) do
      vim.env[k] = nil
    end
  end)

  after_each(function()
    vim.api.nvim_ui_send, vim.notify = real_send, real_notify
    package.loaded["vim.ui.clipboard.osc52"] = real_osc52
    for _, k in ipairs(ENV) do
      vim.env[k] = saved[k]
    end
    vim.g.xyno_clipboard_osc52 = saved.flag
    vim.g.clipboard = saved.g
    C.setup() -- defaults again
  end)

  --- A tmux that answers from $FSC (set-clipboard), $FAP (allow-passthrough, unset = unsupported), $FFEAT.
  local function fake_tmux()
    local dir = H.tmpdir()
    write(
      dir .. "/tmux",
      [[#!/bin/sh
case "$1" in
  -V) echo "tmux 3.8" ;;
  show-options)
    case "$3" in
      set-clipboard) [ -n "$FSC" ] && echo "$FSC" || exit 1 ;;
      allow-passthrough) [ -n "$FAP" ] && echo "$FAP" || exit 1 ;;
    esac ;;
  display-message) echo "$FFEAT" ;;
esac
]]
    )
    vim.fn.system({ "chmod", "+x", dir .. "/tmux" })
    vim.env.PATH = dir .. ":" .. saved.PATH
  end

  local function in_tmux(sc, ap, feat, opts)
    fake_tmux()
    vim.env.TMUX = "/tmp/fake,1,0"
    vim.env.FSC, vim.env.FAP, vim.env.FFEAT = sc, ap, feat
    vim.g.clipboard = nil
    C.setup(opts)
    H.ok(
      vim.wait(5000, function()
        return C.tmux() ~= nil
      end, 10),
      "tmux facts arrived"
    )
  end

  it("invalid options are reported once and ignored, defaults stay", function()
    C.setup({ tmux = "sideways", max_bytes = -1, on_exceed = "explode", chunk_bytes = 3, osc52 = "yes", bogus = true })
    H.eq(1, #msgs)
    for _, frag in ipairs({ "tmux:", "max_bytes", "on_exceed", "chunk_bytes", "osc52", "unknown option bogus" }) do
      H.match(msgs[1], frag, true)
    end
    local o = C.config()
    H.eq({ "auto", 1000000, "skip", 4096, true }, { o.tmux, o.max_bytes, o.on_exceed, o.chunk_bytes, o.osc52 })
  end)

  it("tmux set-clipboard on: raw OSC 52 (Neovim's writer), no hint", function()
    in_tmux("on", nil, "")
    H.eq("raw", C.route())
    local cb = vim.g.clipboard
    cb.copy["+"]({ "hello" })
    H.eq({ { reg = "+", lines = { "hello" } } }, emitted)
    H.eq({}, sent)
    H.is_nil(C.hint())
    H.eq("", (C.statusline()))
  end)

  it("tmux set-clipboard external + allow-passthrough on: wrapped in a DCS passthrough, no raw emit", function()
    in_tmux("external", "on", "")
    H.eq("passthrough", C.route())
    vim.g.clipboard.copy["+"]({ "hello", "world" })
    H.eq({}, emitted)
    H.eq(1, #sent)
    H.eq("\27Ptmux;\27\27]52;c;" .. vim.base64.encode("hello\nworld") .. "\27\27\\\27\\", sent[1])
    vim.g.clipboard.copy["*"]({ "x" })
    H.match(sent[2], "\27\27]52;p;", true)
  end)

  it("the passthrough is chunked: every piece is its own DCS, together they are the sequence", function()
    in_tmux("external", "all", "", { chunk_bytes = 64 })
    local text = string.rep("0123456789", 100)
    vim.g.clipboard.copy["+"]({ text })
    H.ok(#sent > 10, "many chunks: " .. #sent)
    local joined = {}
    for _, piece in ipairs(sent) do
      H.eq("\27Ptmux;", piece:sub(1, 7))
      H.eq("\27\\", piece:sub(-2))
      local body = piece:sub(8, -3)
      H.ok(#body <= 64, "chunk size " .. #body)
      joined[#joined + 1] = body
    end
    local seq = table.concat(joined):gsub("\27\27", "\27")
    H.eq("\27]52;c;" .. vim.base64.encode(text) .. "\27\\", seq)
  end)

  it(
    "tmux that drops OSC 52 (external, no passthrough): hint, statusline, one notice; the copy is still emitted raw",
    function()
      in_tmux("external", nil, "")
      H.eq("dropped", C.route())
      local h = C.hint()
      H.eq("tmux-drops", h.kind)
      H.match(h.fix, "set-clipboard on", true)
      local text, hl = C.statusline()
      H.eq({ "clip: tmux drops OSC52", "XynoClipboardError" }, { text, hl })
      vim.g.clipboard.copy["+"]({ "a" })
      vim.g.clipboard.copy["+"]({ "b" })
      H.eq(2, #emitted)
      H.eq(1, #msgs, "one notice: " .. vim.inspect(msgs))
      H.match(msgs[1], "tmux ignores OSC 52", true)
      H.match(msgs[1], "set -g set-clipboard on", true)
    end
  )

  it(
    "a local Wayland session with wl-copy: tmux dropping OSC 52 is no permanent warning (wl-copy carries the yank)",
    function()
      local dir = H.tmpdir()
      for _, tool in ipairs({ "wl-copy", "wl-paste" }) do
        write(dir .. "/" .. tool, "#!/bin/sh\ncat >/dev/null\n")
        vim.fn.system({ "chmod", "+x", dir .. "/" .. tool })
      end
      vim.env.WAYLAND_DISPLAY = "wayland-test"
      in_tmux("external", nil, "") -- fake_tmux replaces PATH, so the wl-copy stubs go on afterwards
      vim.wait(50) -- let the first setup's scheduled notice (no wl-copy yet) fire, then forget it
      for i = #msgs, 1, -1 do
        msgs[i] = nil
      end
      C._reset_notices()
      vim.env.PATH = dir .. ":" .. vim.env.PATH
      C.setup()
      vim.wait(2000, function()
        return C.tmux() ~= nil
      end, 10)
      H.eq("dropped", C.route(), "tmux does drop it")
      H.is_nil(C.hint(), vim.inspect(C.hint()))
      H.eq("", (C.statusline()))
      vim.g.clipboard.copy["+"]({ "a" })
      H.eq(0, #msgs, "and no notice either: " .. vim.inspect(msgs))
      -- over SSH the OSC 52 path is the one that matters again
      vim.env.SSH_CONNECTION = "1 2 3 4"
      H.eq("tmux-drops", C.hint().kind)
      H.eq("clip: tmux drops OSC52", (C.statusline()))
    end
  )

  it(
    "tmux = raw forces the raw path even when only passthrough would work; tmux = passthrough forces the wrap",
    function()
      in_tmux("external", "on", "", { tmux = "raw" })
      H.eq("raw", C.route())
      vim.g.clipboard.copy["+"]({ "a" })
      H.eq(1, #emitted)
      in_tmux("on", nil, "", { tmux = "passthrough" })
      H.eq("passthrough", C.route())
      vim.g.clipboard.copy["+"]({ "a" })
      H.eq(1, #sent)
    end
  )

  it("a tmux that does not answer is treated as unknown: raw, no hint", function()
    in_tmux(nil, nil, "")
    H.eq("raw", C.route())
    H.is_nil(C.hint())
  end)

  it("tmux without the clipboard terminal feature: warning hint", function()
    in_tmux("on", nil, "256,mouse,RGB")
    local h = C.hint()
    H.eq("tmux-no-clipboard", h.kind)
    H.match(h.fix, "terminal-features", true)
    H.eq("clip: no tmux clipboard", (C.statusline()))
    in_tmux("on", nil, "256,clipboard,RGB")
    H.is_nil(C.hint())
  end)

  it("a yank over max_bytes is not sent as OSC 52: one notice, nothing emitted, state recorded", function()
    in_tmux("on", nil, "", { max_bytes = 100 })
    vim.g.clipboard.copy["+"]({ string.rep("x", 200) })
    vim.g.clipboard.copy["+"]({ string.rep("y", 200) })
    H.eq({}, emitted)
    H.eq(1, #msgs)
    H.match(msgs[1], "over max_bytes (100)", true)
    H.eq(268, C.last_skipped().bytes)
    vim.g.clipboard.copy["+"]({ "small" })
    H.eq(1, #emitted, "a small yank still goes")
  end)

  it("on_exceed = send and max_bytes = 0 send everything", function()
    in_tmux("on", nil, "", { max_bytes = 100, on_exceed = "send" })
    vim.g.clipboard.copy["+"]({ string.rep("x", 200) })
    H.eq(1, #emitted)
    in_tmux("on", nil, "", { max_bytes = 0 })
    vim.g.clipboard.copy["+"]({ string.rep("x", 2000000) })
    H.eq(2, #emitted)
    H.eq(0, #msgs)
  end)

  it("an oversize yank still reaches the Wayland clipboard", function()
    local dir = H.tmpdir()
    write(dir .. "/wl-copy", ("#!/bin/sh\ncat > %s/stdin\n"):format(dir))
    write(dir .. "/wl-paste", "#!/bin/sh\nexit 0\n")
    vim.fn.system({ "chmod", "+x", dir .. "/wl-copy", dir .. "/wl-paste" })
    in_tmux("on", nil, "", { max_bytes = 100 })
    vim.env.PATH = dir .. ":" .. vim.env.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    vim.g.clipboard = nil
    C.setup({ max_bytes = 100 })
    vim.g.clipboard.copy["+"]({ string.rep("z", 500) })
    H.ok(C.flush(3000))
    H.eq({}, emitted)
    H.eq(string.rep("z", 500), read(dir .. "/stdin"))
  end)

  it("statusline is empty when healthy and with hint = false; groups link to Diagnostic groups", function()
    in_tmux("external", nil, "", { hint = false })
    H.eq("", (C.statusline()))
    H.is_nil(C.statusline_hl())
    H.eq("DiagnosticError", vim.api.nvim_get_hl(0, { name = "XynoClipboardError", link = true }).link)
    H.eq("DiagnosticWarn", vim.api.nvim_get_hl(0, { name = "XynoClipboardWarn", link = true }).link)
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    H.eq("DiagnosticWarn", vim.api.nvim_get_hl(0, { name = "XynoClipboardWarn", link = true }).link)
  end)

  it("no clipboard tool: statusline names it, :XynoClipboardStatus shows the fix", function()
    vim.env.PATH = H.tmpdir()
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    vim.g.clipboard = nil
    C.setup()
    H.eq("no-tool", C.hint().kind)
    H.eq({ "clip: no tool", "XynoClipboardWarn" }, { C.statusline() })
  end)

  it(":checkhealth xyno_clipboard reports the tmux problem and its fix", function()
    in_tmux("external", nil, "")
    vim.cmd("silent checkhealth xyno_clipboard")
    local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    H.match(out, "tmux ignores OSC 52", true)
    H.match(out, "set -g set-clipboard on", true)
    H.match(out, "set-clipboard = external", true)
  end)

  it(":checkhealth xyno_clipboard is quiet about tmux when set-clipboard is on", function()
    in_tmux("on", nil, "256,clipboard")
    vim.cmd("silent checkhealth xyno_clipboard")
    local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    H.match(out, "set-clipboard is on", true)
    H.match(out, "no clipboard problem detected", true)
    H.no_match(out, "ERROR", true)
  end)
end)

-- ------------------------------------------------------------- real tmux
describe("xyno_clipboard in real tmux sessions", function()
  local sockets = {}
  local function tmux(sock, args)
    local cmd = vim.list_extend({ "tmux", "-L", sock, "-f", "/dev/null" }, args)
    return vim.system(cmd, { text = true }):wait(10000)
  end
  local function kill_all()
    for _, s in ipairs(sockets) do
      vim.system({ "tmux", "-L", s, "kill-server" }):wait(5000)
    end
    sockets = {}
  end
  after_each(kill_all)

  local function sandbox()
    if vim.fn.executable("tmux") ~= 1 or vim.fn.executable("nvim") ~= 1 then
      skip("no tmux")
    end
    local dir = H.tmpdir()
    write(dir .. "/f.txt", "tui text\n")
    write(
      dir .. "/init.lua",
      ('vim.opt.rtp:prepend(%q)\nvim.env.WAYLAND_DISPLAY = nil\nvim.env.DISPLAY = nil\nrequire("xyno_clipboard").setup()\n'):format(
        vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
      )
    )
    return dir
  end

  --- outer tmux = "the terminal" (set-clipboard on); inner tmux runs nvim with the given options.
  local function nested(dir, sc, ap)
    local pid = vim.uv.os_getpid()
    local o, i = ("xyco%d"):format(pid), ("xyci%d"):format(pid)
    sockets = { o, i }
    write(dir .. "/inner.conf", ("set -g set-clipboard %s\nset -g allow-passthrough %s\n"):format(sc, ap))
    H.eq(0, tmux(o, { "new-session", "-d", "-x", "120", "-y", "30", "-s", "o" }).code)
    tmux(o, { "set", "-g", "set-clipboard", "on" })
    tmux(o, {
      "send-keys",
      "-t",
      "o",
      ("tmux -L %s -f %s/inner.conf new-session -s i 'nvim -u %s/init.lua -i NONE -n %s/f.txt'"):format(
        i,
        dir,
        dir,
        dir
      ),
      "Enter",
    })
    H.ok(
      vim.wait(10000, function()
        return (tmux(i, { "capture-pane", "-p", "-t", "i" }).stdout or ""):find("tui text", 1, true)
      end, 100),
      "nvim is up in the inner tmux"
    )
    vim.wait(500)
    tmux(i, { "send-keys", "-t", "i", '"+yy' })
    return o, i
  end

  it(
    "set-clipboard external + allow-passthrough on: the yank reaches the terminal (outer tmux) through the passthrough",
    function()
      local dir = sandbox()
      local o, i = nested(dir, "external", "on")
      H.ok(
        vim.wait(6000, function()
          return tmux(o, { "show-buffer" }).stdout == "tui text\n"
        end, 100),
        "the outer terminal got the text"
      )
      H.eq(1, tmux(i, { "show-buffer" }).code, "no inner tmux buffer: it went around tmux")
    end
  )

  it("set-clipboard on: the yank becomes an inner tmux buffer and reaches the terminal", function()
    local dir = sandbox()
    local o, i = nested(dir, "on", "off")
    H.ok(
      vim.wait(6000, function()
        return tmux(o, { "show-buffer" }).stdout == "tui text\n"
      end, 100),
      "the outer terminal got the text"
    )
    H.eq("tui text\n", tmux(i, { "show-buffer" }).stdout)
  end)

  it("set-clipboard external, passthrough off: nothing arrives anywhere (the case the hint is for)", function()
    local dir = sandbox()
    local o, i = nested(dir, "external", "off")
    vim.wait(2500)
    H.eq(1, tmux(o, { "show-buffer" }).code, "outer terminal got nothing")
    H.eq(1, tmux(i, { "show-buffer" }).code, "inner tmux has no buffer")
  end)
end)
