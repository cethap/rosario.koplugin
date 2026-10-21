-- Minimal test runner for the rosario plugin (no busted required).
-- Usage, from the repository root: luajit spec/run.lua

local root = (arg and arg[0] and arg[0]:match("^(.*)/spec/run%.lua$")) or "."
package.path = root .. "/rosario.koplugin/?.lua;" .. root .. "/spec/?.lua;" .. package.path

local SPECS = {
    "rosary_spec.lua",
    "content_spec.lua",
    "i18n_spec.lua",
    "pixelart_spec.lua",
    "layout_spec.lua",
    "widget_spec.lua",
}

local passed, failed = 0, 0
local failures = {}
local scope = {}

local function show(v, depth)
    depth = depth or 0
    if type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) ~= "table" then
        return tostring(v)
    elseif depth > 2 then
        return "{...}"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. show(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function prefix(msg)
    return msg and (msg .. ": ") or ""
end

function describe(name, fn)
    scope[#scope + 1] = name
    fn()
    scope[#scope] = nil
end

function it(name, fn)
    local full = table.concat(scope, " > ") .. " > " .. name
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = full .. "\n    " .. tostring(err):gsub("\n", "\n    ")
    end
end

function assert_eq(actual, expected, msg)
    if not deep_equal(actual, expected) then
        error(prefix(msg) .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
    end
end

function assert_true(value, msg)
    if not value then
        error(prefix(msg) .. "expected a truthy value, got " .. show(value), 2)
    end
end

function assert_false(value, msg)
    if value then
        error(prefix(msg) .. "expected a falsy value, got " .. show(value), 2)
    end
end

function assert_error(fn, msg)
    if pcall(fn) then
        error(prefix(msg) .. "expected an error", 2)
    end
end

for _, name in ipairs(SPECS) do
    local path = root .. "/spec/" .. name
    local ok, err = xpcall(function() dofile(path) end, debug.traceback)
    if not ok then
        failed = failed + 1
        failures[#failures + 1] = name .. " (load)\n    " .. tostring(err):gsub("\n", "\n    ")
    end
end

for _, f in ipairs(failures) do
    io.stderr:write("FAIL " .. f .. "\n")
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
