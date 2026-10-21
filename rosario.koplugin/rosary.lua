--[[--
Pure domain model of the Holy Rosary: mystery set of the day, the 79-step
prayer sequence, navigation and progress serialization. Step headings depend
on the language and are built by i18n.lua.

This module has no KOReader dependencies so it can be tested with plain LuaJIT.
]]

local Rosary = {}

Rosary.SET_ORDER = { "gozosos", "luminosos", "dolorosos", "gloriosos" }

-- os.date("*t").wday convention: 1 = Sunday ... 7 = Saturday.
-- Mapping from Rosarium Virginis Mariae, 38.
local SET_BY_WEEKDAY = {
    [1] = "gloriosos",
    [2] = "gozosos",
    [3] = "dolorosos",
    [4] = "gloriosos",
    [5] = "luminosos",
    [6] = "dolorosos",
    [7] = "gozosos",
}

local VALID_SET = {}
for _, id in ipairs(Rosary.SET_ORDER) do VALID_SET[id] = true end

local DECADES = 5
local AVES_PER_DECADE = 10
local INTRO_AVES = 3

function Rosary.is_valid_set(id)
    return VALID_SET[id] == true
end

--- Day of week for a Gregorian date, 1 = Sunday ... 7 = Saturday (Sakamoto).
function Rosary.weekday(year, month, day)
    local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
    if month < 3 then year = year - 1 end
    local w = (year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
        + offsets[month] + day) % 7
    return w + 1
end

function Rosary.set_for_weekday(wday)
    local id = SET_BY_WEEKDAY[wday]
    if not id then
        error("invalid weekday: " .. tostring(wday), 2)
    end
    return id
end

--- Mystery set for a date table with year, month and day fields.
function Rosary.set_for_date(t)
    return Rosary.set_for_weekday(Rosary.weekday(t.year, t.month, t.day))
end

function Rosary.date_key(t)
    return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

-- Step kinds describe the position on the physical rosary:
--   cross        the crucifix
--   large_bead   an Our Father bead
--   small_bead   a Hail Mary bead
--   chain        prayers said on the chain between beads (Glory Be, Fatima, Salve)
--   announcement the announcement of a mystery
-- A Hail Mary step counts its bead: `ave` of `aves`.
local function build_steps()
    local steps = {}
    local function add(step)
        step.index = #steps + 1
        steps[step.index] = step
    end

    add({ section = "intro", kind = "cross", prayer = "sign_of_cross", bead = 0 })
    add({ section = "intro", kind = "cross", prayer = "creed", bead = 0 })
    add({ section = "intro", kind = "large_bead", prayer = "our_father", bead = 1 })
    for ave = 1, INTRO_AVES do
        add({
            section = "intro", kind = "small_bead", prayer = "hail_mary", bead = ave + 1,
            ave = ave, aves = INTRO_AVES,
        })
    end
    add({ section = "intro", kind = "chain", prayer = "glory_be" })

    for decade = 1, DECADES do
        local function decade_step(step)
            step.section, step.decade, step.mystery = "decade", decade, decade
            add(step)
        end
        decade_step({ kind = "announcement", prayer = "announcement" })
        decade_step({ kind = "large_bead", prayer = "our_father", bead = 0 })
        for ave = 1, AVES_PER_DECADE do
            decade_step({
                kind = "small_bead", prayer = "hail_mary", bead = ave,
                ave = ave, aves = AVES_PER_DECADE,
            })
        end
        decade_step({ kind = "chain", prayer = "glory_be" })
        decade_step({ kind = "chain", prayer = "fatima" })
    end

    add({ section = "closing", kind = "chain", prayer = "salve" })
    add({ section = "closing", kind = "cross", prayer = "sign_of_cross", bead = 0 })
    return steps
end

local STEPS = build_steps()
Rosary.STEP_COUNT = #STEPS

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

--- A fresh copy of the full step sequence.
function Rosary.steps()
    local out = {}
    for i, step in ipairs(STEPS) do out[i] = copy(step) end
    return out
end

function Rosary.step(index)
    local step = STEPS[index]
    return step and copy(step)
end

--- Index of the last Hail Mary of a decade.
local function last_ave_index(decade)
    -- intro (7 steps) + full decades before + announcement + Our Father + 10 Aves
    return 7 + (decade - 1) * 14 + 12
end

--- Number of decades whose ten Hail Marys are finished when standing on `index`.
function Rosary.completed_decades(index)
    local n = 0
    for decade = 1, DECADES do
        if index > last_ave_index(decade) then n = decade end
    end
    return n
end

function Rosary.is_decade_start(step)
    return step ~= nil and step.kind == "announcement"
end

--- True for the Glory Be that closes a decade, i.e. right after its tenth Hail Mary.
function Rosary.is_decade_completion(step)
    return step ~= nil and step.section == "decade" and step.prayer == "glory_be"
end

--- Display state of a bead slot while standing on `step`.
-- Slots match `step.bead`: in a decade 0 is the Our Father bead and 1-10 the
-- Hail Marys; in the pendant 0 is the crucifix, 1 the Our Father bead and 2-4
-- the Hail Marys.
-- @treturn string "done", "current" or "upcoming"
function Rosary.bead_state(step, slot)
    if step.kind == "announcement" then return "upcoming" end
    if step.bead == nil then return "done" end
    if slot == step.bead then return "current" end
    if step.section == "closing" or slot < step.bead then return "done" end
    return "upcoming"
end

-- Session --------------------------------------------------------------------

local Session = {}
Session.__index = Session

local function valid_index(index)
    return type(index) == "number" and index == math.floor(index)
        and index >= 1 and index <= Rosary.STEP_COUNT
end

function Rosary.new(set_id, index)
    if not Rosary.is_valid_set(set_id) then
        error("unknown mystery set: " .. tostring(set_id), 2)
    end
    if index ~= nil and not valid_index(index) then
        error("invalid step index: " .. tostring(index), 2)
    end
    return setmetatable({ set_id = set_id, index = index or 1 }, Session)
end

function Session:current()
    return Rosary.step(self.index)
end

function Session:is_first()
    return self.index == 1
end

function Session:is_last()
    return self.index == Rosary.STEP_COUNT
end

--- Advance one step. Returns false when already at the end.
function Session:next()
    if self:is_last() then return false end
    self.index = self.index + 1
    return true
end

--- Go back one step. Returns false when already at the start.
function Session:prev()
    if self:is_first() then return false end
    self.index = self.index - 1
    return true
end

function Session:reset()
    self.index = 1
end

function Session:completed_decades()
    return Rosary.completed_decades(self.index)
end

function Session:set_mystery_set(set_id)
    if not Rosary.is_valid_set(set_id) then
        error("unknown mystery set: " .. tostring(set_id), 2)
    end
    self.set_id = set_id
end

function Session:serialize()
    return { set_id = self.set_id, step = self.index }
end

--- Restore a session saved with `serialize` (plus a `date` field).
-- @param saved table or nil: { date = "YYYY-MM-DD", set_id = ..., step = ... }
-- @param today table: { date = "YYYY-MM-DD", wday = 1..7 }
-- Resumes only when the saved date is today and the data is valid; otherwise
-- starts today's mystery set from the beginning.
function Rosary.resume(saved, today)
    if type(saved) == "table" and saved.date == today.date
            and Rosary.is_valid_set(saved.set_id) and valid_index(saved.step) then
        return Rosary.new(saved.set_id, saved.step)
    end
    return Rosary.new(Rosary.set_for_weekday(today.wday))
end

return Rosary
