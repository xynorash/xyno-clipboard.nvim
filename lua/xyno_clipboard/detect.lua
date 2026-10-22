-- Decides whether this session is one whose yanks may have to reach another
-- machine. Env vars first; the /proc ancestor walk only when they say nothing.
local M = {}

local function proc_lines(pid, file)
  local ok, lines = pcall(vim.fn.readfile, "/proc/" .. pid .. "/" .. file)
  return ok and lines or {}
end

local function proc_ppid(pid)
  for _, line in ipairs(proc_lines(pid, "status")) do
    local ppid = line:match("^PPid:%s+(%d+)")
    if ppid then
      return tonumber(ppid)
    end
  end
end

local function ancestor_process_named(name)
  local pid = vim.fn.getpid()

  for _ = 1, 16 do
    local ppid = proc_ppid(pid)
    if not ppid or ppid <= 1 then
      return false
    end

    local comm = proc_lines(ppid, "comm")[1] or ""
    if comm:find(name, 1, true) then
      return true
    end

    pid = ppid
  end

  return false
end

--- Returns the reason the provider is wanted ("TMUX", "SSH_TTY",
--- "SSH_CONNECTION", "HERDR_PANE_ID", "herdr ancestor") or nil.
--- Ordered cheapest-first so the /proc walk (16 process-file reads) only
--- runs when no env var has already decided the answer.
function M.reason()
  for _, var in ipairs({ "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID" }) do
    if vim.env[var] ~= nil then
      return var
    end
  end
  if ancestor_process_named("herdr") then
    return "herdr ancestor"
  end
end

return M
