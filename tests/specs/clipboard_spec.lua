-- xyno-os: linux (reads /proc, uses sh stubs for wl-copy, wl-paste)
-- Specs for the provider: detection, Wayland and OSC 52 paths, the ancestor walk.
local H = require("xynotest.helpers")

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

describe("xyno_clipboard", function()
  local ENV = { "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID", "WAYLAND_DISPLAY", "DISPLAY", "PATH", "XYNO_FAKE_RC" }
  local saved
  local real_osc52

  -- fake ancestor chain: { [pid] = { ppid = n, comm = "x" } }
  local function with_fake_proc(chain, fn)
    local real_readfile, real_getpid = vim.fn.readfile, vim.fn.getpid
    local reads = {}
    rawset(vim.fn, "getpid", function()
      return 1000
    end)
    rawset(vim.fn, "readfile", function(path, ...)
      local pid, file = tostring(path):match("^/proc/(%d+)/(%a+)$")
      if not pid then
        return real_readfile(path, ...)
      end
      reads[#reads + 1] = path
      local e = chain[tonumber(pid)]
      if not e then
        error("E484: Can't open file " .. path)
      end
      if file == "status" then
        if e.unreadable then
          error("E484: Can't open file " .. path)
        end
        return { "Name:\t" .. e.comm, "PPid:\t" .. e.ppid }
      end
      return { e.comm }
    end)
    local ok, err = pcall(fn, reads)
    rawset(vim.fn, "readfile", nil)
    rawset(vim.fn, "getpid", nil)
    if not ok then
      error(err, 0)
    end
  end

  --- Make a native provider (a fake xclip on an X11 display) available, as on a normal desktop.
  local function with_native_tool()
    local dir = H.tmpdir()
    write(dir .. "/xclip", "#!/bin/sh\ncat >/dev/null\n")
    vim.fn.system({ "chmod", "+x", dir .. "/xclip" })
    vim.env.PATH = dir .. ":" .. saved.PATH
    vim.env.DISPLAY = ":0"
  end

  --- Run setup() with the given env and return vim.g.clipboard. Without a session
  --- variable in env a native tool is assumed unless opts.no_native is set.
  local function setup(env, opts)
    for _, k in ipairs({ "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID" }) do
      vim.env[k] = nil
    end
    for k, v in pairs(env or {}) do
      vim.env[k] = v
    end
    local no_native = opts and opts.no_native
    opts = opts and vim.tbl_extend("force", opts, { no_native = vim.NIL }) or nil
    if opts then
      opts.no_native = nil
    end
    if next(env or {}) == nil and not no_native then
      with_native_tool()
    end
    vim.g.clipboard = nil
    require("xyno_clipboard").setup(opts)
    return vim.g.clipboard
  end

  local plain_chain = { [1000] = { ppid = 500, comm = "nvim" }, [500] = { ppid = 400, comm = "bash" }, [400] = { ppid = 1, comm = "init" } }

  before_each(function()
    saved = { g = vim.g.clipboard, flag = vim.g.xyno_clipboard_osc52 }
    for _, k in ipairs(ENV) do
      saved[k] = vim.env[k]
    end
    real_osc52 = package.loaded["vim.ui.clipboard.osc52"]
  end)

  after_each(function()
    rawset(vim.fn, "readfile", nil)
    rawset(vim.fn, "getpid", nil)
    for _, k in ipairs(ENV) do
      vim.env[k] = saved[k]
    end
    package.loaded["vim.ui.clipboard.osc52"] = real_osc52
    vim.g.xyno_clipboard_osc52 = saved.flag
    vim.g.clipboard = saved.g
  end)

  --- A recording replacement for vim.ui.clipboard.osc52.
  local function fake_osc52()
    local rec = { emitted = {}, paste = {} }
    package.loaded["vim.ui.clipboard.osc52"] = {
      copy = function(reg)
        return function(lines)
          rec.emitted[#rec.emitted + 1] = { reg = reg, lines = lines }
        end
      end,
      paste = function(reg)
        local f = function()
          return { "osc52 " .. reg }
        end
        rec.paste[reg] = f
        return f
      end,
    }
    return rec
  end

  --- A directory with fake wl-copy / wl-paste recording their calls.
  local function fake_wl()
    local dir = H.tmpdir()
    write(
      dir .. "/wl-copy",
      ("#!/bin/sh\nprintf '%%s\\n' \"$@\" > %s/copy.args\ncat > %s/copy.stdin\n"):format(dir, dir)
    )
    write(
      dir .. "/wl-paste",
      ("#!/bin/sh\nprintf '%%s\\n' \"$@\" > %s/paste.args\nprintf 'one\\ntwo'\nexit ${XYNO_FAKE_RC:-0}\n"):format(dir)
    )
    vim.fn.system({ "chmod", "+x", dir .. "/wl-copy", dir .. "/wl-paste" })
    return dir
  end

  it("a plain local session with no native tool gets an OSC 52 copy fallback and one hint", function()
    local rec = fake_osc52()
    local msgs = {}
    local real_notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    require("xyno_clipboard")._reset_notices()
    vim.env.PATH = H.tmpdir()
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    vim.env.DISPLAY = nil
    with_fake_proc(plain_chain, function()
      local c = setup({}, { no_native = true })
      H.ok(c, "no fallback provider although nothing can reach the clipboard")
      H.eq({ active = true, reason = "no clipboard tool" }, require("xyno_clipboard").status())
      c.copy["+"]({ "kept" }, "v")
      H.eq({ { reg = "+", lines = { "kept" } } }, rec.emitted)
      H.eq({ { "kept" }, "v" }, c.paste["+"](), "paste returns the last copy instead of querying the terminal")
      vim.wait(200, function()
        return #msgs > 0
      end)
      vim.notify = real_notify
      H.eq(1, #msgs)
      H.match(msgs[1], "wl-clipboard", true)
    end)
  end)

  it("never replaces a user's own vim.g.clipboard in a plain session", function()
    vim.env.PATH = H.tmpdir()
    vim.env.DISPLAY = nil
    with_fake_proc(plain_chain, function()
      vim.g.clipboard = nil
      for _, k in ipairs({ "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID" }) do
        vim.env[k] = nil
      end
      local mine = { name = "mine", copy = { ["+"] = function() end }, paste = { ["+"] = function() end } }
      vim.g.clipboard = mine
      require("xyno_clipboard").setup()
      H.eq("mine", vim.g.clipboard.name)
    end)
  end)

  it("a failing wl-copy is reported once and OSC 52 is still emitted", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    write(wl .. "/wl-copy", "#!/bin/sh\ncat >/dev/null\necho boom >&2\nexit 3\n")
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local msgs = {}
    local real_notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    require("xyno_clipboard")._reset_notices()
    local c = setup({ TMUX = "x" })
    c.copy["+"]({ "a" })
    c.copy["+"]({ "b" })
    vim.notify = real_notify
    H.eq(2, #rec.emitted)
    H.eq(1, #msgs, "one notice, not one per yank")
    H.match(msgs[1], "wl-copy failed (exit 3)", true)
    H.match(msgs[1], "boom", true)
  end)

  it("setup() is idempotent: twice in a row keeps the provider, a plain re-run drops our own", function()
    fake_osc52()
    local C = require("xyno_clipboard")
    setup({ TMUX = "x" })
    local first = vim.g.clipboard
    C.setup()
    H.eq("XynoClipboard", vim.g.clipboard.name)
    H.eq({ active = true, reason = "TMUX" }, C.status())
    H.ok(first ~= nil)
    -- the session ended (variable gone) and a native tool exists: our provider must not linger as if it were the user's
    vim.env.TMUX = nil
    with_native_tool()
    with_fake_proc(plain_chain, function()
      C.setup()
    end)
    H.is_nil(vim.g.clipboard)
    H.eq(false, C.status().active)
  end)

  it("does nothing outside tmux/ssh/herdr when no ancestor is herdr", function()
    with_fake_proc(plain_chain, function()
      H.is_nil(setup({}))
    end)
  end)

  it("detects an ancestor process whose comm contains 'herdr'", function()
    local chain = {
      [1000] = { ppid = 500, comm = "nvim" },
      [500] = { ppid = 400, comm = "herdr-server" },
      [400] = { ppid = 1, comm = "init" },
    }
    with_fake_proc(chain, function()
      local c = setup({})
      H.ok(c, "no clipboard provider although an ancestor is herdr")
      H.eq("XynoClipboard", c.name)
    end)
  end)

  it("installs the provider for each of TMUX, SSH_CONNECTION, SSH_TTY and HERDR_PANE_ID", function()
    for _, var in ipairs({ "TMUX", "SSH_CONNECTION", "SSH_TTY", "HERDR_PANE_ID" }) do
      with_fake_proc(plain_chain, function(reads)
        local c = setup({ [var] = "x" })
        H.ok(c, var .. ": no clipboard provider")
        H.eq("XynoClipboard", c.name, var)
        H.eq(0, c.cache_enabled, var)
        for _, reg in ipairs({ "+", "*" }) do
          H.eq("function", type(c.copy[reg]), var .. " copy " .. reg)
          H.eq("function", type(c.paste[reg]), var .. " paste " .. reg)
        end
        H.eq(0, #reads, var .. ": the /proc walk must be skipped when an env var decides")
      end)
    end
  end)

  it("without a Wayland display or wl-copy/wl-paste: OSC52 copy only, paste is osc52.paste", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    -- (a) no WAYLAND_DISPLAY although the tools exist
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = nil
    local c = setup({ TMUX = "x" })
    c.copy["+"]({ "hi", "there" })
    H.eq({ { reg = "+", lines = { "hi", "there" } } }, rec.emitted)
    H.eq(0, vim.fn.filereadable(wl .. "/copy.args"), "wl-copy must not run without WAYLAND_DISPLAY")
    H.ok(rawequal(rec.paste["+"], c.paste["+"]), "paste + is not osc52.paste")
    H.ok(rawequal(rec.paste["*"], c.paste["*"]), "paste * is not osc52.paste")
    -- (b) WAYLAND_DISPLAY but no wl-copy/wl-paste on PATH
    rec.emitted = {}
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    vim.env.PATH = H.tmpdir()
    c = setup({ TMUX = "x" })
    c.copy["*"]({ "x" })
    H.eq({ { reg = "*", lines = { "x" } } }, rec.emitted)
    H.ok(rawequal(rec.paste["*"], c.paste["*"]), "paste * is not osc52.paste without wl-paste")
  end)

  it("with Wayland: copy runs wl-copy --sensitive --type text/plain (--primary for *) and emits OSC52", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local c = setup({ TMUX = "x" })
    c.copy["+"]({ "a", "b" })
    H.eq({ "--sensitive", "--type", "text/plain" }, vim.fn.readfile(wl .. "/copy.args"))
    H.eq({ "a", "b" }, vim.fn.readfile(wl .. "/copy.stdin"))
    c.copy["*"]({ "c" })
    H.eq({ "--sensitive", "--type", "text/plain", "--primary" }, vim.fn.readfile(wl .. "/copy.args"))
    H.eq(2, #rec.emitted)
    H.eq("*", rec.emitted[2].reg)
  end)

  it("with Wayland: paste runs wl-paste --no-newline (--primary for *), {} on a non-zero exit", function()
    fake_osc52()
    local wl = fake_wl()
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local c = setup({ TMUX = "x" })
    H.eq({ "one", "two" }, c.paste["+"]())
    H.eq({ "--no-newline" }, vim.fn.readfile(wl .. "/paste.args"))
    H.eq({ "one", "two" }, c.paste["*"]())
    H.eq({ "--no-newline", "--primary" }, vim.fn.readfile(wl .. "/paste.args"))
    vim.env.XYNO_FAKE_RC = "1"
    H.eq({}, c.paste["+"]())
    H.eq({}, c.paste["*"]())
  end)

  it("vim.g.xyno_clipboard_osc52 = false suppresses the OSC52 emit", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local c = setup({ TMUX = "x" })
    vim.g.xyno_clipboard_osc52 = false
    c.copy["+"]({ "quiet" })
    H.eq({}, rec.emitted)
    H.eq({ "quiet" }, vim.fn.readfile(wl .. "/copy.stdin"), "the local copy still happens")
    vim.g.xyno_clipboard_osc52 = nil
    c.copy["+"]({ "loud" })
    H.eq(1, #rec.emitted, "unsetting the variable emits again")
  end)

  it("the ancestor walk stops at ppid <= 1, is bounded to 16 steps and survives unreadable /proc entries", function()
    -- stops at ppid <= 1: a herdr 'above' init is never looked at
    local chain = {
      [1000] = { ppid = 500, comm = "nvim" },
      [500] = { ppid = 1, comm = "bash" },
      [1] = { ppid = 0, comm = "herdr" },
    }
    with_fake_proc(chain, function(reads)
      H.is_nil(setup({}))
      for _, r in ipairs(reads) do
        H.no_match(r, "/proc/1/", true)
      end
    end)
    -- unreadable status of the first parent: no error, no provider
    with_fake_proc({ [1000] = { ppid = 500, comm = "nvim", unreadable = true } }, function()
      H.is_nil(setup({}))
    end)
    -- a missing /proc entry deeper in the chain
    with_fake_proc({ [1000] = { ppid = 500, comm = "nvim" }, [500] = { ppid = 400, comm = "x" } }, function()
      H.is_nil(setup({}))
    end)
    -- a cycle that never reaches init: at most 16 status reads, herdr at step 17 is not seen
    local cyc = { [1000] = { ppid = 2000, comm = "nvim" } }
    for i = 0, 20 do
      cyc[2000 + i] = { ppid = 2000 + i + 1, comm = i == 17 and "herdr" or "sh" }
    end
    with_fake_proc(cyc, function(reads)
      H.is_nil(setup({}))
      local status = 0
      for _, r in ipairs(reads) do
        if r:match("/status$") then
          status = status + 1
        end
      end
      H.ok(status <= 16, "status reads: " .. status)
    end)
  end)
end)

describe("xyno_clipboard opts, status and command", function()
  local saved_g, saved_tmux
  before_each(function()
    saved_g, saved_tmux = vim.g.clipboard, vim.env.TMUX
    pcall(vim.api.nvim_del_user_command, "XynoClipboardStatus")
  end)
  after_each(function()
    vim.g.clipboard = saved_g
    vim.env.TMUX = saved_tmux
    pcall(vim.api.nvim_del_user_command, "XynoClipboardStatus")
  end)

  it("opts.osc52 = false never emits OSC 52", function()
    local real = package.loaded["vim.ui.clipboard.osc52"]
    local emitted = 0
    package.loaded["vim.ui.clipboard.osc52"] = {
      copy = function()
        return function()
          emitted = emitted + 1
        end
      end,
      paste = function()
        return function() end
      end,
    }
    vim.env.TMUX = "x"
    vim.g.clipboard = nil
    require("xyno_clipboard").setup({ osc52 = false })
    vim.g.clipboard.copy["+"]({ "x" })
    package.loaded["vim.ui.clipboard.osc52"] = real
    H.eq(0, emitted)
  end)

  it("registers :XynoClipboardStatus by default, not with commands = false", function()
    vim.env.TMUX = "x"
    require("xyno_clipboard").setup({ commands = false })
    H.eq(0, vim.fn.exists(":XynoClipboardStatus"))
    require("xyno_clipboard").setup()
    H.eq(2, vim.fn.exists(":XynoClipboardStatus"))
  end)

  it("status() reports the reason when active and the cause when inactive", function()
    local C = require("xyno_clipboard")
    for _, k in ipairs({ "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID" }) do
      vim.env[k] = nil
    end
    vim.env.TMUX = "x"
    C.setup()
    H.eq({ active = true, reason = "TMUX" }, C.status())
    local msg
    local real = vim.notify
    vim.notify = function(m)
      msg = m
    end
    vim.cmd("XynoClipboardStatus")
    vim.notify = real
    H.match(msg, "active (TMUX)", true)
    H.match(msg, "XynoClipboard", true)
  end)
end)

