-- xyno-clipboard: the Wayland copy never blocks the editor (hung / slow / forking wl-copy), keeps yank order,
-- reports a failure once, and paste still sees the last yank; passthrough chunks never cut an ESC ESC pair;
-- the tmux "dropped" re-check is asynchronous.
-- xyno-os: linux (sh stubs for wl-copy, wl-paste, tmux)
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
local function ms()
  return vim.uv.hrtime() / 1e6
end

local C = require("xyno_clipboard")

describe("xyno_clipboard async copy", function()
  local ENV =
    { "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID", "WAYLAND_DISPLAY", "DISPLAY", "PATH", "FSC", "FAP" }
  local saved, real_osc52, real_notify, real_send, msgs, sent, pids

  before_each(function()
    saved = { g = vim.g.clipboard }
    for _, k in ipairs(ENV) do
      saved[k] = vim.env[k]
    end
    real_osc52, real_notify, real_send = package.loaded["vim.ui.clipboard.osc52"], vim.notify, vim.api.nvim_ui_send
    msgs, sent, pids = {}, {}, {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    vim.api.nvim_ui_send = function(s)
      sent[#sent + 1] = s
    end
    package.loaded["vim.ui.clipboard.osc52"] = {
      copy = function()
        return function() end
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
    C.flush(5000)
    vim.notify, vim.api.nvim_ui_send = real_notify, real_send
    package.loaded["vim.ui.clipboard.osc52"] = real_osc52
    for _, k in ipairs(ENV) do
      vim.env[k] = saved[k]
    end
    vim.g.clipboard = saved.g
    C.setup()
  end)

  --- PATH with a fake wl-copy (body = sh script) and a wl-paste that prints what wl-copy last stored.
  local function fake(body)
    local dir = H.tmpdir()
    write(dir .. "/wl-copy", "#!/bin/sh\n" .. body:gsub("%%DIR%%", dir))
    write(dir .. "/wl-paste", ("#!/bin/sh\ncat %s/clip 2>/dev/null\n"):format(dir))
    vim.fn.system({ "chmod", "+x", dir .. "/wl-copy", dir .. "/wl-paste" })
    vim.env.PATH = dir .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    vim.env.TMUX = "x"
    vim.g.clipboard = nil
    C.setup()
    return dir
  end

  it("a wl-copy that hangs does not block the yank; it is killed at the timeout and reported once", function()
    fake("cat > %DIR%/in\nexec sleep 30\n")
    local t = ms()
    vim.g.clipboard.copy["+"]({ "x" })
    vim.g.clipboard.copy["+"]({ "y" })
    local took = ms() - t
    H.ok(took < 250, ("two yanks returned in %.0f ms; they must not wait for wl-copy"):format(took))
    H.ok(C.copy_pending())
    H.ok(C.flush(9000), "queue drains after the hung wl-copy is killed")
    local n = 0
    for _, m in ipairs(msgs) do
      if m:find("wl-copy", 1, true) then
        n = n + 1
        H.match(m, "killed", true)
      end
    end
    H.eq(1, n, "one notice for two hung copies: " .. vim.inspect(msgs))
  end)

  it("a wl-copy that forks a daemon holding its pipes is done when it exits, not when the daemon does", function()
    local dir = fake("cat > %DIR%/clip\nsleep 20 &\nexit 0\n")
    local t = ms()
    vim.g.clipboard.copy["+"]({ "daemon" })
    H.ok(C.flush(3000))
    H.ok(ms() - t < 1500, "exit of the parent ends the job")
    H.eq("daemon", read(dir .. "/clip"))
    vim.fn.system({ "pkill", "-9", "-f", "sleep 20" })
  end)

  it("quick yanks reach wl-copy in order and paste after a yank sees the last one", function()
    local dir = fake('sleep 0.15\ncat > %DIR%/clip\necho "$$" >> %DIR%/order\n')
    local c = vim.g.clipboard
    for _, s in ipairs({ "one", "two", "three" }) do
      c.copy["+"]({ s })
    end
    local pasted = c.paste["+"]() -- must wait for the queue
    H.eq({ "three" }, pasted)
    H.eq(3, #vim.fn.readfile(dir .. "/order"), "every yank ran")
  end)

  it("wl-copy stdin carries the text exactly (multi-line, no extra newline)", function()
    local dir = fake("cat > %DIR%/clip\n")
    vim.g.clipboard.copy["+"]({ "a", "b", "" })
    H.ok(C.flush(3000))
    H.eq("a\nb\n", read(dir .. "/clip"))
  end)

  it("a failing wl-copy does not stop the queue behind it", function()
    local dir = fake('cat > %DIR%/clip\nif [ "$(cat %DIR%/clip)" = bad ]; then echo nope >&2; exit 4; fi\n')
    vim.g.clipboard.copy["+"]({ "bad" })
    vim.g.clipboard.copy["+"]({ "good" })
    H.ok(C.flush(3000))
    H.eq("good", read(dir .. "/clip"))
    H.eq(1, #msgs, vim.inspect(msgs))
    H.match(msgs[1], "exit 4", true)
  end)

  it("a missing wl-copy binary at run time is reported, not thrown", function()
    local dir = fake("cat >/dev/null\n")
    os.remove(dir .. "/wl-copy")
    vim.g.clipboard.copy["+"]({ "x" })
    H.ok(C.flush(3000))
    H.eq(1, #msgs, vim.inspect(msgs))
    H.match(msgs[1], "wl-copy", true)
  end)
end)

describe("xyno_clipboard passthrough framing", function()
  local saved = {}
  local real_send, sent
  before_each(function()
    for _, k in ipairs({ "TMUX", "WAYLAND_DISPLAY", "DISPLAY", "PATH" }) do
      saved[k] = vim.env[k]
    end
    saved.g = vim.g.clipboard
    real_send, sent = vim.api.nvim_ui_send, {}
    vim.api.nvim_ui_send = function(s)
      sent[#sent + 1] = s
    end
  end)
  after_each(function()
    vim.api.nvim_ui_send = real_send
    for _, k in ipairs({ "TMUX", "WAYLAND_DISPLAY", "DISPLAY", "PATH" }) do
      vim.env[k] = saved[k]
    end
    vim.g.clipboard = saved.g
    C.setup()
  end)

  it("no chunk boundary falls inside an ESC ESC pair, for any text length", function()
    vim.env.TMUX = "/tmp/fake,1,0"
    vim.env.WAYLAND_DISPLAY, vim.env.DISPLAY = nil, nil
    vim.g.clipboard = nil
    for cb = 64, 72 do
      C.setup({ tmux = "passthrough", chunk_bytes = cb })
      for len = 1, 150 do
        sent = {}
        local text = string.rep("a", len)
        vim.g.clipboard.copy["+"]({ text })
        local joined = {}
        for _, piece in ipairs(sent) do
          local body = piece:sub(8, -3)
          H.ok(#body <= cb, "piece too long")
          for run in body:gmatch("\27+") do
            H.eq(0, #run % 2, ("odd ESC run (chunk_bytes %d, text length %d): %q"):format(cb, len, body))
          end
          joined[#joined + 1] = body
        end
        H.eq("\27]52;c;" .. vim.base64.encode(text) .. "\27\\", (table.concat(joined):gsub("\27\27", "\27")))
      end
    end
  end)

  it("the tmux 'dropped' re-check does not block the yank", function()
    local dir = H.tmpdir()
    write(
      dir .. "/tmux",
      '#!/bin/sh\nsleep 0.6\ncase "$1" in show-options) [ "$3" = set-clipboard ] && echo external || exit 1 ;; esac\n'
    )
    vim.fn.system({ "chmod", "+x", dir .. "/tmux" })
    vim.env.PATH = dir .. ":" .. saved.PATH
    vim.env.TMUX = "/tmp/fake,1,0"
    vim.env.WAYLAND_DISPLAY, vim.env.DISPLAY = nil, nil
    vim.g.clipboard = nil
    C.setup()
    H.ok(
      vim.wait(15000, function()
        return C.route() == "dropped"
      end, 20),
      "tmux facts arrived: dropped"
    )
    -- force the re-check window
    C._expire_tmux_check()
    local t = ms()
    vim.g.clipboard.copy["+"]({ "x" })
    local took = ms() - t
    H.ok(took < 300, ("the yank took %.0f ms; the re-check must run in the background"):format(took))
    vim.wait(100)
  end)
end)
