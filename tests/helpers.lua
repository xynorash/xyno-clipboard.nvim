-- Assertions and temp dirs for the specs (stdlib + vim only).
local H = {}
H._dirs = {}

local function fail(msg, level)
  error(msg, (level or 1) + 1)
end

function H.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    fail(
      ("%sexpected %s\n  actual   %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function H.ok(v, msg)
  if not v then
    fail(msg or ("expected a truthy value, got " .. vim.inspect(v)), 2)
  end
  return v
end

function H.is_nil(v, msg)
  if v ~= nil then
    fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. vim.inspect(v), 2)
  end
end

--- Lua pattern match (plain = true for a literal substring).
function H.match(str, pat, plain, msg)
  if type(str) ~= "string" or not str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s does not match %q"):format(vim.inspect(str), pat), 2)
  end
end

function H.no_match(str, pat, plain, msg)
  if type(str) == "string" and str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s unexpectedly matches %q"):format(vim.inspect(str), pat), 2)
  end
end

--- A fresh empty directory, removed by cleanup().
function H.tmpdir()
  local base = vim.env.XYNO_TEST_TMP
  if not base or base == "" then
    base = vim.fs.dirname(vim.fn.tempname())
  end
  local dir = assert(vim.uv.fs_mkdtemp(base .. "/spec-XXXXXX"))
  H._dirs[#H._dirs + 1] = dir
  return dir
end

function H.cleanup()
  for _, d in ipairs(H._dirs) do
    vim.fn.delete(d, "rf")
  end
  H._dirs = {}
end

return H
