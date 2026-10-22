-- Runs every tests/specs/*_spec.lua in this nvim:
--   nvim -l tests/run.lua [spec files...]
-- Prints one line per test and a final "passed=N failed=N skipped=N" line;
-- exits non-zero on any failure. A spec may carry a header line
--   -- xyno-os: linux (why)
-- and is skipped whole on other platforms.
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
package.preload["xynotest.helpers"] = function()
  return dofile(root .. "/tests/helpers.lua")
end

local harness = dofile(root .. "/tests/harness.lua")

local function platform()
  return vim.fn.has("win32") == 1 and "windows" or vim.fn.has("mac") == 1 and "macos" or "linux"
end

local function os_skip_reason(path)
  local n = 0
  for line in io.lines(path) do
    n = n + 1
    local list = line:match("^%-%- xyno%-os: *([%a,]+)")
    if list then
      for name in list:gmatch("[^,]+") do
        if name == platform() then
          return nil
        end
      end
      return ("needs %s, this is %s"):format(list:gsub(",", " or "), platform())
    end
    if n >= 15 then
      break
    end
  end
end

local specs = #arg > 0 and arg or vim.fn.glob(root .. "/tests/specs/*_spec.lua", true, true)
local total = { passed = 0, failed = 0, skipped = 0 }
for _, spec in ipairs(specs) do
  local why = os_skip_reason(spec)
  if why then
    print(("SKIP %s (%s)"):format(vim.fs.basename(spec), why))
    total.skipped = total.skipped + 1
  else
    harness.install()
    local ok, err = xpcall(dofile, debug.traceback, spec)
    if not ok then
      print("FAIL loading " .. spec .. "\n" .. tostring(err))
      total.failed = total.failed + 1
    else
      local n = harness.run(print)
      for k, v in pairs(n) do
        total[k] = total[k] + v
      end
    end
  end
end
require("xynotest.helpers").cleanup()
print(("passed=%d failed=%d skipped=%d"):format(total.passed, total.failed, total.skipped))
os.exit(total.failed > 0 and 1 or 0)
