-- Smoke tests for the KOReader glue (main.lua, rosarywidget.lua) against
-- minimal stand-ins for the KOReader modules they use. These check control
-- flow, refresh requests and drawing bounds; on-device behaviour is verified
-- separately (T4).

local root = (arg and arg[0] and arg[0]:match("^(.*)/spec/run%.lua$")) or "."
local SCREEN_W, SCREEN_H = 1072, 1448

-- KOReader stand-ins ---------------------------------------------------------------

local function class(base)
    local c = base or {}
    c.__index = c
    function c:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, self)
    end
    function c:new(o)
        o = setmetatable(o or {}, self)
        self.__index = self
        if o._init then o:_init() end
        if o.init then o:init() end
        return o
    end
    return c
end

local Geom = class()
function Geom:contains(g)
    return g ~= nil and self.x <= g.x and self.y <= g.y
        and self.x + self.w >= g.x + (g.w or 0) and self.y + self.h >= g.y + (g.h or 0)
end

local GestureRange = class()
function GestureRange:match(ev)
    if ev.ges ~= self.ges then return false end
    local range = type(self.range) == "function" and self.range() or self.range
    return range == nil or range:contains(ev.pos)
end

local Event = {}
function Event:new(name, args, ev) return { name = name, args = args, ev = ev } end

local Widget = class()
function Widget:handleEvent(event)
    local handler = self["on" .. event.name]
    if handler then return handler(self, event.args, event.ev) end
end

local WidgetContainer = Widget:extend{}

local InputContainer = WidgetContainer:extend{}
function InputContainer:_init()
    self.key_events = self.key_events or {}
    self.ges_events = self.ges_events or {}
end
function InputContainer:onGesture(ev)
    for name, seq in pairs(self.ges_events) do
        for _, range in ipairs(seq) do
            if range:match(ev) then
                if self:handleEvent(Event:new(seq.event or name, seq.args, ev)) then return true end
            end
        end
    end
end

local UIManager = { shown = {}, dirty = {}, tasks = {}, clock = 0, closed = {} }
function UIManager:reset()
    self.shown, self.dirty, self.tasks, self.clock, self.closed = {}, {}, {}, 0, {}
end
function UIManager:show(widget, refresh)
    self.shown[#self.shown + 1] = widget
    if refresh then self.dirty[#self.dirty + 1] = { widget = widget, mode = refresh } end
end
function UIManager:close(widget, refresh)
    self.closed[#self.closed + 1] = widget
    for i = #self.shown, 1, -1 do
        if self.shown[i] == widget then table.remove(self.shown, i) end
    end
    widget:handleEvent(Event:new("FlushSettings"))
    widget:handleEvent(Event:new("CloseWidget"))
    if refresh then self.dirty[#self.dirty + 1] = { mode = refresh } end
end
function UIManager:setDirty(widget, mode, region)
    self.dirty[#self.dirty + 1] = { widget = widget, mode = mode, region = region }
end
function UIManager:scheduleIn(seconds, action)
    assert(seconds >= 0, "Only positive seconds allowed")
    self.tasks[#self.tasks + 1] = { at = self.clock + seconds, action = action }
end
function UIManager:unschedule(action)
    for i = #self.tasks, 1, -1 do
        if self.tasks[i].action == action then table.remove(self.tasks, i) end
    end
end
function UIManager:runTasks()
    while #self.tasks > 0 do
        table.sort(self.tasks, function(a, b) return a.at < b.at end)
        local task = table.remove(self.tasks, 1)
        self.clock = task.at
        task.action()
    end
end
function UIManager:modes()
    local out = {}
    for i, d in ipairs(self.dirty) do out[i] = d.mode end
    return out
end

local live_text = 0
local TextBoxWidget = class()
function TextBoxWidget:init()
    live_text = live_text + 1
    local size = self.face.size
    local per_line = math.max(1, math.floor(self.width / (size * 0.55)))
    local lines = 0
    for para in (self.text .. "\n"):gmatch("(.-)\n") do
        local chars = select(2, para:gsub("[^\128-\191]", ""))
        lines = lines + math.max(1, math.ceil(chars / per_line))
    end
    -- Like KOReader: line_height_px = Math.round((1 + line_height) * face.size).
    local h = lines * math.floor((1 + (self.line_height or 0.3)) * size + 0.5)
    if self.height then h = math.min(h, self.height) end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = h }
end
function TextBoxWidget:getSize() return self.dimen end
function TextBoxWidget:paintTo(bb, x, y) bb:record(x, y, self.dimen.w, self.dimen.h, "text") end
function TextBoxWidget:free()
    if not self.freed then live_text = live_text - 1 end
    self.freed = true
end

local store = {}
local LuaSettings = class()
function LuaSettings:open(path)
    store[path] = store[path] or {}
    return setmetatable({ data = store[path] }, { __index = LuaSettings })
end
function LuaSettings:readSetting(key) return self.data[key] end
function LuaSettings:saveSetting(key, value)
    local copy = {}
    for k, v in pairs(value) do copy[k] = v end
    self.data[key] = copy
end
function LuaSettings:flush() self.flushed = true end

local ButtonDialog = Widget:extend{}

local Device = {
    screen = {
        getWidth = function() return SCREEN_W end,
        getHeight = function() return SCREEN_H end,
        -- Like the framebuffer's scaleBySize without a DPI override.
        scaleBySize = function(_, px) return math.ceil(px * math.min(SCREEN_W, SCREEN_H) / 600) end,
    },
    input = { group = { Back = "Back", PgFwd = "PgFwd", PgBack = "PgBack" } },
}
function Device:hasKeys() return false end
function Device:isTouchDevice() return true end

-- Font:getFace stand-in. It records every requested font name. Any font
-- other than KOReader's "cfont" can be made to fail the way the real one
-- does: `font_failure = "nil"` returns nil (Freetype could not open the file)
-- and `font_failure = "error"` raises; `font_failure = "bold"` returns nil
-- for the bold file only, as if it had not been copied to the device.
local face_requests, font_failure = {}, nil
local Font = {}
function Font:getFace(name, size)
    face_requests[#face_requests + 1] = name
    if name ~= "cfont" and font_failure == "nil" then return nil end
    if name ~= "cfont" and font_failure == "bold" and name:find("Bold", 1, true) then return nil end
    if name ~= "cfont" and font_failure == "error" then error("cannot open " .. name) end
    return { name = name, size = Device.screen:scaleBySize(size), orig_size = size }
end

local STUBS = {
    ["ffi/blitbuffer"] = { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY = "gray", COLOR_DARK_GRAY = "dark" },
    ["ui/widget/buttondialog"] = ButtonDialog,
    ["datastorage"] = { getSettingsDir = function() return "/fake/settings" end },
    ["device"] = Device,
    ["ui/font"] = Font,
    ["ui/geometry"] = Geom,
    ["ui/gesturerange"] = GestureRange,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    ["logger"] = { warn = function() end },
    ["luasettings"] = LuaSettings,
    ["ui/widget/textboxwidget"] = TextBoxWidget,
    ["ui/uimanager"] = UIManager,
}
for name, stub in pairs(STUBS) do package.loaded[name] = stub end

-- KOReader's global reader settings (G_reader_settings), where the plugin
-- reads KOReader's UI language ("language") and keeps its own language
-- choice ("rosario_language"). The specs run in Spanish unless they say so.
local function reader_settings(data)
    local settings = { data = data or {}, flushes = 0 }
    function settings:readSetting(key) return self.data[key] end
    function settings:saveSetting(key, value) self.data[key] = value end
    function settings:delSetting(key) self.data[key] = nil end
    function settings:flush() self.flushes = self.flushes + 1 end
    return settings
end
G_reader_settings = reader_settings({ language = "es" })

-- Fixed "today": Monday 2026-10-19.
local real_date = os.date
local today = { year = 2026, month = 10, day = 19, wday = 2, hour = 9, min = 0, sec = 0 }
os.date = function(fmt, t)
    if fmt == "*t" and t == nil then
        local copy = {}
        for k, v in pairs(today) do copy[k] = v end
        return copy
    end
    return real_date(fmt, t)
end

local RosaryWidget = dofile(root .. "/rosario.koplugin/rosarywidget.lua")
local Rosario = dofile(root .. "/rosario.koplugin/main.lua")
local Layout = require("layout")
local PixelArt = require("pixelart")
local I18n = require("i18n")
local Content = require("content.es")
local ES = require("l10n.es")

-- Helpers ---------------------------------------------------------------------------

-- A framebuffer that records the black rectangles painted on it. Any method
-- other than paintRect (an inversion, for instance) is recorded as an
-- unexpected call.
local function fake_bb()
    local bb = { rects = 0, out_of_bounds = {}, ink = {}, unexpected = {} }
    function bb:record(x, y, w, h, what)
        self.rects = self.rects + 1
        if x < 0 or y < 0 or x + w > SCREEN_W or y + h > SCREEN_H then
            self.out_of_bounds[#self.out_of_bounds + 1] = ("%s %d,%d %dx%d"):format(what, x, y, w, h)
        end
    end
    function bb:paintRect(x, y, w, h, color)
        if color == "black" then self.ink[#self.ink + 1] = { x = x, y = y, w = w, h = h } end
        self:record(x, y, w, h, "rect")
    end
    return setmetatable(bb, { __index = function(_, method)
        return function() bb.unexpected[#bb.unexpected + 1] = method end
    end })
end

local function paint(widget)
    local bb = fake_bb()
    widget:paintTo(bb, 0, 0)
    assert_eq(bb.out_of_bounds, {}, "drawing stays on screen")
    assert_eq(bb.unexpected, {}, "paints with paintRect only")
    assert_true(bb.rects > 0)
    return bb
end

local function rect_key(r)
    return r.x .. "," .. r.y .. "," .. r.w .. "," .. r.h
end

-- The black rectangles of `ink` that `other` does not paint.
local function ink_minus(ink, other)
    local seen = {}
    for _, r in ipairs(other) do seen[rect_key(r)] = true end
    local out = {}
    for _, r in ipairs(ink) do
        if not seen[rect_key(r)] then out[#out + 1] = r end
    end
    return out
end

-- The ink of the current step painted at rest, without its animation.
local function still_ink(widget)
    local anim = widget.anim
    widget.anim = nil
    local ink = paint(widget).ink
    widget.anim = anim
    return ink
end

local function run_next_task()
    table.sort(UIManager.tasks, function(a, b) return a.at < b.at end)
    local task = table.remove(UIManager.tasks, 1)
    UIManager.clock = task.at
    task.action()
end

-- Runs scheduled tasks until `done()` holds; false if they ran out first.
local function run_until(done)
    while #UIManager.tasks > 0 do
        run_next_task()
        if done() then return true end
    end
    return false
end

-- Runs the pending animation one task at a time, painting every frame, and
-- returns one entry per refresh requested since UIManager.dirty was cleared:
-- its mode and region, seconds since the first frame, the kind of animation
-- it showed, its ink and the part of it (`extra`) that the step at rest
-- does not paint.
local function play(widget)
    local frames, start = {}, UIManager.clock
    local still = still_ink(widget)
    local function capture()
        local ink = paint(widget).ink
        for i = #frames + 1, #UIManager.dirty do
            local d = UIManager.dirty[i]
            frames[i] = {
                mode = d.mode, region = d.region, at = UIManager.clock - start,
                anim = widget.anim and widget.anim.kind or "none",
                ink = ink, extra = ink_minus(ink, still),
            }
        end
    end
    capture()
    while #UIManager.tasks > 0 do
        run_next_task()
        capture()
    end
    return frames
end

local function pluck(frames, key)
    local out = {}
    for i, frame in ipairs(frames) do out[i] = frame[key] end
    return out
end

local function gesture(widget, ges, x, y, direction)
    return widget:onGesture({ ges = ges, pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, direction = direction })
end

local function tap(widget, x, y)
    return gesture(widget, "tap", x or 500, y or 900)
end

-- `failure`: how the bundled font fails to load, if it does (see Font above).
-- `settings`: KOReader's reader settings, Spanish by default.
local function fresh(saved, failure, settings)
    G_reader_settings = reader_settings(settings or { language = "es" })
    store = {}
    if saved then store["/fake/settings/rosario.lua"] = { state = saved } end
    UIManager:reset()
    live_text = 0
    face_requests, font_failure = {}, failure
    return RosaryWidget:new{}
end

-- The shown text block whose text is `text`, or nil.
local function text_block(widget, text)
    for _, block in ipairs(widget.text_blocks) do
        if block.widget.text == text then return block end
    end
end

local function texts(widget)
    local out = {}
    for i, block in ipairs(widget.text_blocks) do out[i] = block.widget.text end
    return out
end

local function bottom(block)
    return block.y + block.widget:getSize().h
end

local function overlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function inside(inner, outer)
    return inner.x >= outer.x and inner.y >= outer.y
        and inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h
end

local function grow(r, d)
    return { x = r.x - d, y = r.y - d, w = r.w + 2 * d, h = r.h + 2 * d }
end

-- The beads drawn in the diagram for `step`.
local function view_of(widget, step)
    return step.section == "decade" and widget.views.ring or widget.views.pendant
end

-- Every rectangle of ink that a frame adds or removes against the frame
-- before it must lie in the region it refreshes, so no pixel of an
-- animation stays on the e-ink screen once the last refresh is done.
local function assert_refreshed(frames, where)
    for i = 2, #frames do
        local region = frames[i].region
        if region then
            local changed = ink_minus(frames[i].ink, frames[i - 1].ink)
            for _, r in ipairs(ink_minus(frames[i - 1].ink, frames[i].ink)) do changed[#changed + 1] = r end
            for _, r in ipairs(changed) do
                assert_true(inside(r, region), ("%s: frame %d changes %s outside its refresh"):format(where, i, rect_key(r)))
            end
        end
    end
    assert_eq(frames[#frames].extra, {}, where .. ": the last frame is the step at rest")
end

-- Nearest and farthest distance from the center of `bead` to the centers
-- of the rectangles in `rects`.
local function reach(rects, bead)
    local bx, by = bead.x + bead.w / 2, bead.y + bead.h / 2
    local near, far = math.huge, 0
    for _, r in ipairs(rects) do
        local d = math.sqrt((r.x + r.w / 2 - bx) ^ 2 + (r.y + r.h / 2 - by) ^ 2)
        near, far = math.min(near, d), math.max(far, d)
    end
    return near, far
end

local function top_of(rects)
    local y = math.huge
    for _, r in ipairs(rects) do y = math.min(y, r.y) end
    return y
end

-- Checks the ripple frames of a bead step: each ring grows outwards from
-- the current bead, inside the diagram and off the other beads.
local function assert_ripple(widget, step, frames, where)
    local view = view_of(widget, step)
    local bead
    for _, b in ipairs(view.beads) do
        if b.slot == step.bead then bead = b end
    end
    local last_near, last_far = 0, 0
    for i, frame in ipairs(frames) do
        if frame.anim == "ripple" then
            local ring = frame.extra
            assert_true(#ring > 0, where .. ": ripple frame " .. i .. " draws a ring")
            local near, far = reach(ring, bead)
            assert_true(near > last_near and far > last_far, where .. ": ripple frame " .. i .. " grows")
            last_near, last_far = near, far
            for _, r in ipairs(ring) do
                assert_true(inside(r, widget.layout.diagram), where .. ": ripple inside the diagram")
                for _, other in ipairs(view.beads) do
                    if other.slot ~= bead.slot then
                        assert_false(overlap(r, Layout.bead_region(widget.layout, other)),
                            where .. ": ripple over bead " .. other.slot)
                    end
                end
            end
        end
    end
end

-- Checks the sparkle wave frames of a Glory Be: the sparkles sit next to the
-- beads in view (within two sparkle widths, as the sparkles line up at one
-- distance from beads of different sizes) or around the decade number,
-- never over a bead, and rise frame after frame.
local function assert_wave(widget, step, frames, where)
    local L, view = widget.layout, view_of(widget, step)
    local size = Layout.SPARKLE * L.bead_scale
    local near_beads = {}
    for i, bead in ipairs(view.beads) do near_beads[i] = grow(Layout.bead_region(L, bead), 2 * size) end
    local decade = step.section == "decade"
    local center = decade and (Layout.sparkles(L)) or {}
    local tops, center_lit = {}, {}
    for i, frame in ipairs(frames) do
        if frame.anim == "wave" then
            assert_true(#frame.extra > 0, where .. ": wave frame " .. i .. " shows sparkles")
            tops[#tops + 1] = top_of(frame.extra)
            for _, r in ipairs(frame.extra) do
                assert_true(inside(r, L.diagram), where .. ": sparkle inside the diagram")
                local near = false
                for j, bead in ipairs(view.beads) do
                    assert_false(overlap(r, Layout.bead_region(L, bead)), where .. ": sparkle over a bead")
                    near = near or inside(r, near_beads[j])
                end
                for j, c in ipairs(center) do
                    if inside(r, c) then near, center_lit[j] = true, true end
                end
                assert_true(near, where .. ": sparkle " .. rect_key(r) .. " is next to a bead")
            end
        end
    end
    -- The wave rises while it moves along the beads: up both sides of the
    -- ring in six frames, or up the five beads of the pendant.
    for i = 2, decade and 6 or 5 do
        assert_true(tops[i] < tops[i - 1], where .. ": wave frame " .. i .. " rises")
    end
    local lit = 0
    for _ in pairs(center_lit) do lit = lit + 1 end
    assert_eq(lit, #center, where .. ": the decade completion sparkle plays")
end

local REGULAR_FILE = "rosario.koplugin/fonts/Roboto-Regular.ttf"
local BOLD_FILE = "rosario.koplugin/fonts/Roboto-Bold.ttf"
local END_HINT = "Rosario terminado. Toca para comenzar de nuevo."

-- Steps that show each kind of screen: the first step, a decade bead and a
-- mystery announcement (card).
local SCREENS = {
    { name = "first step" },
    { name = "decade bead", saved = { date = "2026-10-19", set_id = "gozosos", step = 12 } },
    { name = "mystery card", saved = { date = "2026-10-19", set_id = "gozosos", step = 22 } },
}

local function find_button(dialog, label)
    for _, row in ipairs(dialog.buttons) do
        for _, button in ipairs(row) do
            if button.text:find(label, 1, true) then return button end
        end
    end
    error("button not found: " .. label)
end

local function top_dialog()
    return UIManager.shown[#UIManager.shown]
end

-- KOReader caches its menu order tables with `require`; these trimmed copies
-- follow koreader master and are injected fresh for every test.
local FM_ORDER, READER_ORDER = "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order"

local function fresh_orders()
    local fm = {
        ["KOMenu:menu_buttons"] = { "filemanager_settings", "setting", "tools", "search", "plus_menu", "main" },
        tools = { "read_timer", "calibre", "statistics", "----------------------------", "more_tools" },
    }
    local reader = {
        ["KOMenu:menu_buttons"] = { "navi", "typeset", "setting", "tools", "search", "filemanager", "main" },
        tools = { "read_timer", "calibre", "statistics", "progress_sync", "----------------------------", "more_tools" },
    }
    package.loaded[FM_ORDER], package.loaded[READER_ORDER] = fm, reader
    return fm, reader
end

local function clear_orders()
    package.loaded[FM_ORDER], package.loaded[READER_ORDER] = nil, nil
end

-- A File Manager or Reader menu: each one closes through a different method.
local function new_plugin(close_method, path)
    local menu = { closed = 0 }
    function menu:registerToMainMenu(plugin) self.registered = plugin end
    menu[close_method or "onCloseFileManagerMenu"] = function(self) self.closed = self.closed + 1 end
    -- The plugin loader sets `path` on the plugin module; instances inherit it.
    return Rosario:new{ ui = { menu = menu }, path = path }, menu
end

local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do
        if v == value then n = n + 1 end
    end
    return n
end

-- Collapses "dir/.." pairs the way the filesystem resolves them.
local function normalize(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

-- Where KOReader's Font:getFace looks for a font name, from its working
-- directory (the KOReader folder). The stable release v2026.07.1 always
-- prepends its fonts folder (frontend/ui/font.lua:306, with
-- frontend/fontlist.lua:11 fontdir = "./fonts"); master opens a name that
-- starts with "./" or "/" as a path and prepends the folder to any other.
local FONTS_DIR = "./fonts"
local function stable_location(name)
    return FONTS_DIR .. "/" .. name
end
local function master_location(name)
    if name:match("^%./") or name:match("^/") then return name end
    return FONTS_DIR .. "/" .. name
end

-- Specs -----------------------------------------------------------------------------

describe("main.lua", function()
    it("adds a Rosario entry to the Tools menu", function()
        local registered
        local plugin = Rosario:new{ ui = { menu = { registerToMainMenu = function(_, p) registered = p end } } }
        assert_eq(registered, plugin)
        local items = {}
        plugin:addToMainMenu(items)
        assert_eq(items.rosario.text_func(), "Rosario")
        assert_eq(items.rosario.sorting_hint, "tools")
        UIManager:reset()
        items.rosario.callback()
        assert_eq(#UIManager.shown, 1)
        assert_eq(UIManager.dirty[1].mode, "full")
        assert_true(UIManager.shown[1].session ~= nil, "a RosaryWidget is shown")
    end)

    it("still registers without the menu order modules", function()
        clear_orders()
        local plugin, menu = new_plugin()
        assert_eq(menu.registered, plugin)
    end)

    it("adds the Rosario tab right after Tools in both menus", function()
        local fm, reader = fresh_orders()
        new_plugin()
        assert_eq(fm["KOMenu:menu_buttons"],
            { "filemanager_settings", "setting", "tools", "rosario_tab", "search", "plus_menu", "main" })
        assert_eq(reader["KOMenu:menu_buttons"],
            { "navi", "typeset", "setting", "tools", "rosario_tab", "search", "filemanager", "main" })
        assert_eq(fm.rosario_tab, {})
        assert_eq(reader.rosario_tab, {})
    end)

    it("moves the Rosario entry to the top of the Tools tab", function()
        local fm, reader = fresh_orders()
        local plugin = new_plugin()
        assert_eq(fm.tools[1], "rosario")
        assert_eq(reader.tools[1], "rosario")
        local items = {}
        plugin:addToMainMenu(items)
        assert_eq(items.rosario.text_func(), "Rosario")
    end)

    it("names the Tools entry in the current language", function()
        fresh_orders()
        local items = {}
        new_plugin():addToMainMenu(items)
        local cases = {
            { { language = "en_GB" }, "Rosary" },
            { { language = "pt_BR" }, "Rosário" },
            { { language = "it_IT" }, "Rosario" },
            { { language = "fr" }, "Rosary" },
            { { language = "es", rosario_language = "la" }, "Rosarium" },
        }
        for _, case in ipairs(cases) do
            G_reader_settings = reader_settings(case[1])
            assert_eq(items.rosario.text_func(), case[2], case[2])
        end
        G_reader_settings = reader_settings({ language = "es" })
    end)

    it("names the Tools entry Rosario when no strings can be loaded", function()
        -- A plugin copied without its l10n files (or with broken ones) has a
        -- catalog without strings; the menu must still open.
        local real_dofile = dofile
        local widget = {
            catalog = function(lang) return { lang = lang } end,
            language = function() return "es" end,
        }
        dofile = function(path)
            if path:match("/rosarywidget%.lua$") then return widget end
            return real_dofile(path)
        end
        local ok, Plugin = pcall(real_dofile, root .. "/rosario.koplugin/main.lua")
        dofile = real_dofile
        assert_true(ok, tostring(Plugin))
        fresh_orders()
        local menu = { registerToMainMenu = function() end }
        local items = {}
        Plugin:new{ ui = { menu = menu } }:addToMainMenu(items)
        assert_eq(items.rosario.text_func(), "Rosario")
    end)

    it("changes the cached orders only once across plugin instances", function()
        local fm, reader = fresh_orders()
        new_plugin("onCloseFileManagerMenu")
        local fm_tab, reader_tab = fm.rosario_tab, reader.rosario_tab
        new_plugin("onTapCloseMenu")
        for _, order in ipairs({ fm, reader }) do
            assert_eq(count(order["KOMenu:menu_buttons"], "rosario_tab"), 1)
            assert_eq(count(order.tools, "rosario"), 1)
            assert_eq(order.tools[1], "rosario")
        end
        assert_eq(fm["KOMenu:menu_buttons"][4], "rosario_tab")
        assert_eq(reader["KOMenu:menu_buttons"][5], "rosario_tab")
        assert_true(fm.rosario_tab == fm_tab and reader.rosario_tab == reader_tab, "existing tab orders are kept")
    end)

    it("appends the tab when there is no Tools tab", function()
        package.loaded[FM_ORDER] = { ["KOMenu:menu_buttons"] = { "setting", "main" } }
        package.loaded[READER_ORDER] = { ["KOMenu:menu_buttons"] = { "navi" }, tools = {} }
        new_plugin()
        assert_eq(package.loaded[FM_ORDER]["KOMenu:menu_buttons"], { "setting", "main", "rosario_tab" })
        assert_eq(package.loaded[FM_ORDER].tools, nil, "no Tools order is invented")
        assert_eq(package.loaded[READER_ORDER]["KOMenu:menu_buttons"], { "navi", "rosario_tab" })
        assert_eq(package.loaded[READER_ORDER].tools, { "rosario" })
    end)

    it("reaches the plugin icon through IconWidget's icon folder", function()
        fresh_orders()
        local items = {}
        new_plugin(nil, "plugins/rosario.koplugin"):addToMainMenu(items)
        local icon = items.rosario_tab.icon
        assert_eq(icon, "../../../plugins/rosario.koplugin/rosario")
        assert_eq(normalize("resources/icons/mdlight/" .. icon .. ".svg"), "plugins/rosario.koplugin/rosario.svg")
        local svg = io.open(root .. "/rosario.koplugin/rosario.svg", "r")
        assert_true(svg ~= nil, "rosario.svg ships with the plugin")
        assert_true(svg:read("*a"):find('viewBox="0 0 48 48"', 1, true), "48x48 like the other tab icons")
        svg:close()
    end)

    it("falls back to a built-in icon for an absolute or unknown plugin path", function()
        fresh_orders()
        for _, path in ipairs({ "/mnt/us/koreader/plugins/rosario.koplugin", false }) do
            local items = {}
            new_plugin(nil, path or nil):addToMainMenu(items)
            assert_eq(items.rosario_tab.icon, "star.full", tostring(path))
        end
    end)

    it("opens the Rosary straight from the tab in both menus", function()
        fresh_orders()
        for _, close_method in ipairs({ "onCloseFileManagerMenu", "onTapCloseMenu" }) do
            local items = {}
            local plugin, menu = new_plugin(close_method, "plugins/rosario.koplugin")
            plugin:addToMainMenu(items)
            local tab = items.rosario_tab
            assert_eq(tab.remember, false, "the tab is never remembered as the open tab")
            assert_eq(tab.text, nil, "top-level tabs show only an icon")
            UIManager:reset()
            tab.callback()
            assert_eq(menu.closed, 1, close_method)
            assert_eq(#UIManager.shown, 1)
            assert_true(UIManager.shown[1].session ~= nil, "a RosaryWidget is shown")
        end
    end)
end)

describe("RosaryWidget", function()
    it("starts today's set and paints within the screen", function()
        local w = fresh()
        assert_eq(w.session.set_id, "gozosos")
        assert_eq(w.session.index, 1)
        paint(w)
    end)

    it("walks the whole rosary with event-driven refreshes, ripples and sparkle waves", function()
        local w = fresh()
        local bead_steps, glory_steps = 0, 0
        for _ = 1, 78 do
            UIManager.dirty = {}
            assert_true(tap(w))
            local step = w.session:current()
            local frames = play(w)
            local modes, anims = pluck(frames, "mode"), pluck(frames, "anim")
            local where = "step " .. step.index
            for i = 2, #frames do
                -- Frames in one tick would merge into a single refresh on the device.
                assert_true(frames[i].at > frames[i - 1].at, where .. ": one refresh per frame")
            end
            assert_eq(count(modes, "full"), step.kind == "announcement" and 1 or 0, where .. ": full refreshes")
            assert_refreshed(frames, where)
            if step.kind == "announcement" then
                assert_eq(modes, { "full" }, where)
            elseif step.kind == "small_bead" or step.kind == "large_bead" then
                bead_steps = bead_steps + 1
                -- Bead fill (outline, dither, solid), a ripple of three rings,
                -- then a clean refresh that restores the bead and its halo.
                assert_eq(modes, { "ui", "fast", "fast", "fast", "fast", "fast", "ui" }, where)
                assert_eq(anims, { "bead", "bead", "bead", "ripple", "ripple", "ripple", "none" }, where)
                assert_eq(frames[1].region, nil, where .. ": the new step is painted whole")
                local box = frames[#frames].region
                assert_true(box ~= nil and inside(box, w.layout.diagram), where .. ": the ripple box is in the diagram")
                for i = 2, 3 do
                    local region = frames[i].region
                    assert_true(region ~= nil and inside(region, box) and region.w < box.w,
                        where .. ": fill frames refresh the bead")
                end
                for i = 4, 6 do
                    assert_eq(frames[i].region, box, where .. ": ripple frames refresh the ripple box")
                end
                assert_ripple(w, step, frames, where)
                assert_true(frames[#frames].at <= 0.6, where .. ": the bead animation stays short")
            elseif step.prayer == "glory_be" then
                glory_steps = glory_steps + 1
                -- A wave of sparkles: up the ring and around the decade number,
                -- or up the pendant, then a clean refresh of the sparkles' box.
                local fast = step.section == "decade" and 7 or 5
                local expected_modes, expected_anims = { "ui" }, { "wave" }
                for i = 1, fast do
                    expected_modes[i + 1], expected_anims[i + 1] = "fast", "wave"
                end
                expected_modes[fast + 2], expected_anims[fast + 2] = "ui", "none"
                assert_eq(modes, expected_modes, where)
                assert_eq(anims, expected_anims, where)
                assert_eq(frames[1].region, nil, where .. ": the new step is painted whole")
                local box = frames[#frames].region
                assert_true(box ~= nil and inside(box, w.layout.diagram), where .. ": the wave box is in the diagram")
                for i = 2, #frames do
                    assert_eq(frames[i].region, box, where .. ": wave frame " .. i .. " refreshes the wave box")
                end
                assert_wave(w, step, frames, where)
                assert_true(frames[#frames].at <= 1, where .. ": the sparkle wave stays short")
            else
                assert_eq(modes, { "ui" }, where)
            end
        end
        assert_eq(bead_steps, 59, "every Our Father and Hail Mary bead ripples")
        assert_eq(glory_steps, 6, "the introductory Glory Be and the five decades sparkle")
        assert_eq(w.session.index, 79)
        UIManager.dirty = {}
        tap(w)
        assert_eq(w.session.index, 1, "a tap on the last step starts a new rosary")
        assert_eq(UIManager:modes(), { "full" }, "the new rosary is painted with a full refresh")
    end)

    it("animates only when a tap moves forward", function()
        -- Swiping back onto a Glory Be or a bead does not animate.
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 21 })
        for _, index in ipairs({ 20, 19 }) do
            UIManager.dirty = {}
            gesture(w, "swipe", 500, 900, "east")
            assert_eq(w.session.index, index)
            local frames = play(w)
            assert_eq(pluck(frames, "mode"), { "ui" }, "back to step " .. index)
            assert_eq(pluck(frames, "anim"), { "none" }, "back to step " .. index)
        end
        w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 8 })
        gesture(w, "swipe", 500, 900, "east")
        assert_eq(w.session.index, 7)
        assert_eq(#UIManager.tasks, 0, "back onto the introductory Glory Be")

        -- Reopening on a Glory Be, the hold menu, a set change and a restart do not animate.
        w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 20 })
        assert_eq(#UIManager.tasks, 0, "reopening")
        assert_eq(w.anim, nil, "reopening")
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Cambiar misterios").callback()
        find_button(top_dialog(), "Misterios Gloriosos").callback()
        assert_eq(#UIManager.tasks, 0, "set change")
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Reiniciar").callback()
        assert_eq(#UIManager.tasks, 0, "restart")
        assert_eq(w.anim, nil, "restart")

        -- A tap that closes the reopened mystery card does not animate either.
        w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 12 })
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Ver misterio").callback()
        UIManager.dirty = {}
        tap(w)
        assert_eq(w.session.index, 12)
        assert_eq(pluck(play(w), "anim"), { "none" }, "closing the card")
    end)

    -- Saved steps just before a bead (step 11, a Hail Mary of the first
    -- decade), the introductory Glory Be (step 7) and a decade's Glory Be
    -- (step 20), with the animation that a tap onto them plays.
    local MID_ANIMATIONS = {
        { name = "mid-ripple", step = 10, kind = "ripple" },
        { name = "mid-wave (introductory)", step = 6, kind = "wave" },
        { name = "mid-wave (decade)", step = 19, kind = "wave" },
    }

    -- Taps onto the step after `case.step` and runs its animation until it is
    -- halfway through its kind of frames.
    local function start_mid_animation(case)
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = case.step })
        UIManager:show(w)
        tap(w)
        local seen = 0
        assert_true(run_until(function()
            if w.anim and w.anim.kind == case.kind then seen = seen + 1 end
            return seen == 2
        end), case.name .. " is reached")
        assert_true(#UIManager.tasks > 0, case.name .. ": more frames are pending")
        assert_true(#ink_minus(paint(w).ink, still_ink(w)) > 0, case.name .. ": something is drawn")
        return w
    end

    -- The widget shows its step at rest and has nothing left to play.
    local function assert_clean(w, where)
        assert_eq(w.anim, nil, where)
        assert_eq(#UIManager.tasks, 0, where .. ": no frame is left")
        assert_eq(ink_minus(paint(w).ink, still_ink(w)), {}, where .. ": no ripple or sparkle is drawn")
    end

    it("cancels a ripple or a sparkle wave on the next tap without leaving pixels", function()
        for _, case in ipairs(MID_ANIMATIONS) do
            local w = start_mid_animation(case)
            local from = w.session.index
            UIManager.dirty = {}
            tap(w)
            assert_eq(w.session.index, from + 1, case.name .. ": the tap is not dropped")
            -- The next step is painted whole, which clears what was drawn.
            assert_eq(UIManager.dirty[1].region, nil, case.name)
            local frames = play(w)
            assert_eq(count(pluck(frames, "mode"), "full"), w.session:current().kind == "announcement" and 1 or 0,
                case.name .. ": no full refresh is added")
            assert_clean(w, case.name)
        end
    end)

    it("cancels a ripple on the next tap and ripples the new bead", function()
        local w = start_mid_animation(MID_ANIMATIONS[1])
        UIManager.dirty = {}
        tap(w)
        assert_eq(w.session.index, 12)
        assert_eq(pluck(play(w), "anim"), { "bead", "bead", "bead", "ripple", "ripple", "ripple", "none" })
        assert_clean(w, "after the new ripple")
    end)

    it("cancels a ripple or a sparkle wave on swipe back and on the hold menu", function()
        for _, case in ipairs(MID_ANIMATIONS) do
            for _, action in ipairs({ "swipe", "hold" }) do
                local where = case.name .. ", " .. action
                local w = start_mid_animation(case)
                UIManager.dirty = {}
                if action == "swipe" then
                    gesture(w, "swipe", 500, 900, "east")
                    assert_eq(w.session.index, case.step, where)
                else
                    gesture(w, "hold", 500, 900)
                end
                assert_eq(UIManager:modes(), { "ui" }, where .. ": one repaint")
                assert_eq(UIManager.dirty[1].region, nil, where .. ": of the whole widget")
                assert_clean(w, where)
            end
        end
    end)

    it("unschedules every ripple and sparkle frame when closed mid-animation", function()
        for _, case in ipairs(MID_ANIMATIONS) do
            for _, how in ipairs({ "swipe south", "external close" }) do
                local where = case.name .. ", " .. how
                local w = start_mid_animation(case)
                if how == "swipe south" then
                    gesture(w, "swipe", 500, 900, "south")
                else
                    UIManager:close(w)
                end
                assert_eq(UIManager.closed[1], w, where)
                assert_eq(#UIManager.tasks, 0, where)
                assert_eq(w.anim, nil, where)
            end
        end
    end)

    it("goes back with swipe east and forward with swipe west", function()
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 10 })
        gesture(w, "swipe", 500, 900, "east")
        assert_eq(w.session.index, 9)
        gesture(w, "swipe", 500, 900, "west")
        UIManager:runTasks()
        assert_eq(w.session.index, 10)
    end)

    it("resumes today's progress and restarts on another day", function()
        local w = fresh({ date = "2026-10-19", set_id = "dolorosos", step = 33, show_text = false })
        assert_eq(w.session.set_id, "dolorosos")
        assert_eq(w.session.index, 33)
        assert_false(w.show_text)
        w = fresh({ date = "2026-10-18", set_id = "dolorosos", step = 33 })
        assert_eq(w.session.set_id, "gozosos")
        assert_eq(w.session.index, 1)
    end)

    it("saves progress after every step", function()
        local w = fresh()
        tap(w)
        UIManager:runTasks()
        local saved = store["/fake/settings/rosario.lua"].state
        assert_eq(saved, { date = "2026-10-19", set_id = "gozosos", step = 2, show_text = true })
        assert_true(w.settings.flushed)
    end)

    it("cancels a running animation on the next tap", function()
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 9 })
        tap(w)
        assert_true(#UIManager.tasks > 0, "animation scheduled")
        tap(w)
        assert_eq(w.session.index, 11)
        -- Each frame schedules the next one, so one task is pending at a time.
        assert_eq(#UIManager.tasks, 1, "only the new animation is pending")
        UIManager:runTasks()
        assert_eq(w.anim, nil)
        assert_eq(ink_minus(paint(w).ink, still_ink(w)), {}, "the bead is at rest")
    end)

    it("offers the hold menu", function()
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 30 })
        gesture(w, "hold", 500, 900)
        local dialog = top_dialog()
        local labels = {}
        for i, row in ipairs(dialog.buttons) do labels[i] = row[1].text end
        assert_eq(labels, { "Reiniciar", "Cambiar misterios", "Ver misterio", "Ocultar texto", "Idioma", "Salir" })

        UIManager.dirty = {}
        find_button(dialog, "Reiniciar").callback()
        assert_eq(w.session.index, 1)
        assert_eq(UIManager:modes()[#UIManager.dirty], "full")
    end)

    it("reopens the mystery card and closes it with a tap", function()
        local w = fresh({ date = "2026-10-19", set_id = "luminosos", step = 40 })
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Ver misterio").callback()
        assert_true(w.card_open)
        paint(w)
        tap(w)
        assert_false(w.card_open)
        assert_eq(w.session.index, 40, "closing the card does not advance")
    end)

    it("toggles the prayer text", function()
        local w = fresh()
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Ocultar texto").callback()
        assert_false(w.show_text)
        assert_false(store["/fake/settings/rosario.lua"].state.show_text)
        paint(w)
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Mostrar texto").callback()
        assert_true(w.show_text)
    end)

    it("changes the mystery set", function()
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 12 })
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Cambiar misterios").callback()
        local chooser = top_dialog()
        assert_eq(#chooser.buttons, 4)
        assert_true(find_button(chooser, "Misterios Gozosos").text:find("(hoy)", 1, true), "today's set is marked")
        find_button(chooser, "Misterios Gloriosos").callback()
        assert_eq(w.session.set_id, "gloriosos")
        assert_eq(w.session.index, 12)
        assert_eq(store["/fake/settings/rosario.lua"].state.set_id, "gloriosos")
    end)

    it("closes with swipe south, the X button and the menu", function()
        local w = fresh()
        UIManager:show(w)
        gesture(w, "swipe", 500, 900, "south")
        assert_eq(UIManager.closed[1], w)
        assert_eq(live_text, 0, "text widgets are freed on close")

        w = fresh()
        local close = w.layout.close
        tap(w, close.x + 2, close.y + 2)
        assert_eq(UIManager.closed[1], w)
        assert_eq(w.session.index, 1, "tapping X does not advance")

        w = fresh()
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Salir").callback()
        assert_eq(UIManager.closed[#UIManager.closed], w)
    end)

    it("says the rosary is finished at the bottom of the text on the last step", function()
        local L = Layout.compute(SCREEN_W, SCREEN_H)
        for _, show_text in ipairs({ true, false }) do
            local where = show_text and "with text" or "without text"
            local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 79, show_text = show_text })
            local hint = text_block(w, END_HINT)
            assert_true(hint, where .. ": no hint in " .. table.concat(texts(w), " | "))
            assert_eq(hint.widget.face.name:sub(-#REGULAR_FILE), REGULAR_FILE, where .. ": the hint is body text")
            assert_eq(hint.x, L.text.x, where)
            assert_eq(bottom(hint), L.text.y + L.text.h, where .. ": the hint sits at the bottom of the text area")
            for _, block in ipairs(w.text_blocks) do
                if block ~= hint and block.y >= L.text.y then
                    assert_true(bottom(block) < hint.y, where .. ": " .. block.widget.text .. " stays above the hint")
                end
            end
            paint(w)
        end
        for _, step in ipairs({ 1, 78 }) do
            local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = step })
            assert_eq(text_block(w, END_HINT), nil, "no hint on step " .. step)
        end
    end)

    it("starts a new rosary with a tap on the last step", function()
        -- Today is Monday (gozosos); a set chosen by hand is kept, like the
        -- menu's Reiniciar does.
        for _, set_id in ipairs({ "gozosos", "dolorosos" }) do
            local w = fresh({ date = "2026-10-19", set_id = set_id, step = 79 })
            UIManager:show(w)
            UIManager.dirty = {}
            assert_true(tap(w))
            assert_eq(w.session.index, 1, set_id)
            assert_eq(w.session.set_id, set_id, set_id .. ": the same set as Reiniciar")
            assert_eq(store["/fake/settings/rosario.lua"].state.step, 1, set_id .. ": saved")
            assert_eq(UIManager:modes(), { "full" }, set_id .. ": one full refresh")
            assert_eq(#UIManager.tasks, 0, set_id .. ": no animation")
            assert_eq(text_block(w, END_HINT), nil, set_id .. ": the hint is gone")
            assert_eq(#UIManager.closed, 0, set_id .. ": the widget stays open")
        end
        -- Swiping forward restarts too; a tap that closes the reopened card does not.
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 79 })
        gesture(w, "swipe", 500, 900, "west")
        assert_eq(w.session.index, 1, "swipe west")
        w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 79 })
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Ver misterio").callback()
        tap(w)
        assert_false(w.card_open)
        assert_eq(w.session.index, 79, "closing the card first")
    end)

    it("draws a menu button in the header, mirroring the close X", function()
        local w = fresh()
        local L = w.layout
        local bars = {}
        for _, r in ipairs(paint(w).ink) do
            if inside(r, L.menu) then bars[#bars + 1] = r end
        end
        assert_eq(#bars, 3, "three bars in the menu button")
        for _, r in ipairs(bars) do
            assert_eq({ r.x, r.w, r.h }, { L.menu.x, L.menu.w, L.close_scale }, "a bar across the button")
        end
    end)

    it("opens the menu from the menu button without advancing", function()
        local labels = { "Reiniciar", "Cambiar misterios", "Ver misterio", "Ocultar texto", "Idioma", "Salir" }
        local function shown_labels(dialog)
            local out = {}
            for i, row in ipairs(dialog.buttons) do out[i] = row[1].text end
            return out
        end
        for _, step in ipairs({ 1, 30, 79 }) do
            local where = "step " .. step
            local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = step })
            UIManager:show(w)
            local hit = w.layout.menu_hit
            for _, pos in ipairs({ { hit.x + 1, hit.y + 1 }, { hit.x + hit.w - 1, hit.y + hit.h - 1 } }) do
                local before = #UIManager.shown
                assert_true(tap(w, pos[1], pos[2]), where)
                assert_eq(w.session.index, step, where .. ": a tap on the menu button does not advance")
                assert_eq(#UIManager.shown, before + 1, where .. ": a dialog is shown")
                assert_eq(shown_labels(top_dialog()), labels, where)
                assert_eq(#UIManager.tasks, 0, where .. ": nothing animates")
                assert_eq(#UIManager.closed, 0, where .. ": the widget stays open")
            end
            -- A long press anywhere still opens the same menu.
            gesture(w, "hold", 500, 900)
            assert_eq(shown_labels(top_dialog()), labels, where .. ": hold")
            assert_eq(w.session.index, step, where .. ": hold")
        end
        -- Just outside the tap zone, a tap advances.
        local w = fresh()
        local hit = w.layout.menu_hit
        tap(w, hit.x + hit.w + 1, hit.y + hit.h + 1)
        assert_eq(w.session.index, 2, "a tap outside the menu button advances")
    end)

    it("cancels a ripple or a sparkle wave when the menu button opens the menu", function()
        for _, case in ipairs(MID_ANIMATIONS) do
            local w = start_mid_animation(case)
            local from = w.session.index
            local hit = w.layout.menu_hit
            UIManager.dirty = {}
            tap(w, hit.x + 2, hit.y + 2)
            assert_eq(w.session.index, from, case.name)
            assert_eq(UIManager:modes(), { "ui" }, case.name .. ": one repaint")
            assert_eq(UIManager.dirty[1].region, nil, case.name .. ": of the whole widget")
            assert_clean(w, case.name)
        end
    end)

    it("shows every mystery card of every set within the screen", function()
        for _, set_id in ipairs({ "gozosos", "luminosos", "dolorosos", "gloriosos" }) do
            for decade = 1, 5 do
                local w = fresh({ date = "2026-10-19", set_id = set_id, step = 8 + (decade - 1) * 14 })
                assert_eq(w.session:current().kind, "announcement")
                paint(w)
            end
        end
    end)
end)

-- The black rectangles of `ink` that lie inside `row`, as sorted keys.
local function ink_in(ink, row)
    local out = {}
    for _, r in ipairs(ink) do
        if inside(r, row) then out[#out + 1] = rect_key(r) end
    end
    table.sort(out)
    return out
end

-- The rectangles, as sorted keys, that the bitmap font paints for `text`
-- centered in `row` at the largest scale up to `max_scale` that fits, and
-- that scale.
local function glyph_ink(text, row, max_scale)
    local scale = PixelArt.fit_scale(text, row.w, max_scale)
    local x = row.x + math.floor((row.w - PixelArt.text_width(text, scale)) / 2)
    local y = row.y + math.floor((row.h - PixelArt.text_height(scale)) / 2)
    local out = {}
    PixelArt.draw_text(function(rx, ry, rw, rh)
        out[#out + 1] = rect_key({ x = rx, y = ry, w = rw, h = rh })
    end, x, y, text, scale, "black")
    table.sort(out)
    return out, scale
end

-- The headings of a screen: { text, row, scale } for the title, the
-- mystery set, the step label or the card's ordinal heading, and the
-- decade number in the middle of the ring.
local function headings(w)
    local L, step = w.layout, w.session:current()
    local list = {
        { "Santo Rosario", L.title, L.title_scale },
        { Content.sets[w.session.set_id].title, L.set, L.set_scale },
    }
    if w:isCardShown() then
        local _, n = w:currentMystery()
        list[#list + 1] = { I18n.mystery_heading(n, ES), L.card_label, L.label_scale }
    else
        list[#list + 1] = { I18n.step_label(step, ES), L.label, L.label_scale }
        if step.section == "decade" then
            list[#list + 1] = { step.decade .. "º", L.ring_label, L.ring_label_scale }
        end
    end
    return list
end

-- The texts shown in bold on each screen of SCREENS.
local function bold_texts(screen)
    local m1, m2 = Content.sets.gozosos.mysteries[1], Content.sets.gozosos.mysteries[2]
    local out = {}
    if screen.name == "decade bead" then
        out[m1.title .. " (" .. m1.reference .. ")"] = true
    elseif screen.name == "mystery card" then
        out[m2.title] = true
        out["Fruto del misterio: " .. m2.fruit] = true
    end
    return out
end

local function ends_with(s, suffix)
    return s:sub(-#suffix) == suffix
end

describe("RosaryWidget typography", function()
    it("sets the body text in the bundled Roboto, with its real bold for bold blocks", function()
        for _, screen in ipairs(SCREENS) do
            local w = fresh(screen.saved)
            paint(w)
            assert_true(#w.text_blocks > 0, screen.name)
            local bold, shown = bold_texts(screen), 0
            for _, block in ipairs(w.text_blocks) do
                local tb = block.widget
                local where = screen.name .. ": " .. tb.text
                if bold[tb.text] then
                    shown = shown + 1
                    assert_true(ends_with(tb.face.name, BOLD_FILE), where .. " is set in Roboto Bold, got " .. tb.face.name)
                else
                    assert_true(ends_with(tb.face.name, REGULAR_FILE), where .. " is set in Roboto Regular, got " .. tb.face.name)
                end
                assert_false(tb.bold, where .. ": no synthesized bold on top of the font")
            end
            local expected = 0
            for _ in pairs(bold) do expected = expected + 1 end
            assert_eq(shown, expected, screen.name .. ": bold blocks")
            for _, name in ipairs(face_requests) do
                assert_true(ends_with(name, REGULAR_FILE) or ends_with(name, BOLD_FILE),
                    screen.name .. " requests only the bundled Roboto, got " .. name)
            end
        end
        -- The reopened card's hint is regular body text too.
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 12 })
        gesture(w, "hold", 500, 900)
        find_button(top_dialog(), "Ver misterio").callback()
        local hint = text_block(w, "Toca la pantalla para volver.")
        assert_true(hint, "card hint in " .. table.concat(texts(w), " | "))
        assert_true(ends_with(hint.widget.face.name, REGULAR_FILE), "the card hint is set in Roboto Regular")
    end)

    it("ships Roboto Regular and Bold with their license, and no longer Pixelify Sans", function()
        -- The names resolve, from the spec runner's working directory, to the
        -- fonts that ship with the plugin.
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 22 })
        local names = {}
        for _, block in ipairs(w.text_blocks) do names[block.widget.face.name] = true end
        local found = 0
        for name in pairs(names) do
            found = found + 1
            local where = master_location(name)
            local path = where:sub(1, 1) == "/" and where or normalize(where)
            local font = io.open(path, "rb")
            assert_true(font ~= nil, "the font ships with the plugin: " .. path)
            assert_eq(font:read(4), "\0\1\0\0", path .. " is a TrueType font")
            font:close()
        end
        assert_eq(found, 2, "the card uses both Roboto files")
        local license = io.open(root .. "/rosario.koplugin/fonts/OFL.txt", "r")
        assert_true(license ~= nil, "the OFL license ships next to the fonts")
        local text = license:read("*a")
        license:close()
        assert_true(text:find("SIL OPEN FONT LICENSE", 1, true), "OFL text")
        assert_true(text:find("The Roboto Project Authors", 1, true), "Roboto's copyright notice")
        assert_false(text:find("Pixelify", 1, true), "no Pixelify Sans notice left")
        assert_eq(io.open(root .. "/rosario.koplugin/fonts/PixelifySans.ttf", "rb"), nil, "Pixelify Sans is removed")
    end)

    it("turns a relative plugin folder into font names that stable and master both resolve", function()
        -- The plugin path is relative to the KOReader folder on the Kindle.
        -- The device log showed v2026.07.1 failing on
        -- "./fonts/./plugins/rosario.koplugin/fonts/PixelifySans.ttf".
        for _, file in ipairs({ "fonts/Roboto-Regular.ttf", "fonts/Roboto-Bold.ttf" }) do
            local font = "plugins/rosario.koplugin/" .. file
            for _, dir in ipairs({ "plugins/rosario.koplugin", "./plugins/rosario.koplugin", "././plugins/rosario.koplugin" }) do
                local name = RosaryWidget.fontPath(dir, file)
                assert_eq(name, "../plugins/rosario.koplugin/" .. file, dir)
                assert_eq(stable_location(name), "./fonts/../plugins/rosario.koplugin/" .. file, dir .. " on stable")
                assert_eq(normalize(stable_location(name)), font, dir .. " on stable")
                assert_eq(normalize(master_location(name)), font, dir .. " on master")
            end
        end
    end)

    it("keeps an absolute plugin folder as a path", function()
        assert_eq(RosaryWidget.fontPath("/mnt/us/koreader/plugins/rosario.koplugin", "fonts/Roboto-Bold.ttf"),
            "/mnt/us/koreader/plugins/rosario.koplugin/fonts/Roboto-Bold.ttf")
    end)

    it("draws the headings with the bitmap pixel font, not as text boxes", function()
        for _, screen in ipairs(SCREENS) do
            local w = fresh(screen.saved)
            local ink = paint(w).ink
            local list = headings(w)
            assert_eq(#list, ({ ["first step"] = 3, ["decade bead"] = 4, ["mystery card"] = 3 })[screen.name], screen.name)
            for _, h in ipairs(list) do
                local text, row, max_scale = h[1], h[2], h[3]
                local where = screen.name .. ": " .. text
                local expected, scale = glyph_ink(text, row, max_scale)
                assert_true(#expected > 0, where .. " has glyphs")
                assert_eq(scale, max_scale, where .. " keeps its full size on the Kindle")
                assert_eq(ink_in(ink, row), expected, where .. " is drawn in its row with the bitmap font")
                for _, block in ipairs(w.text_blocks) do
                    assert_true(block.widget.text ~= text and block.widget.text ~= PixelArt.upper(text),
                        where .. " is not a text box")
                end
            end
        end
    end)

    it("keeps the pixel headings with KOReader's UI font as the body fallback", function()
        for _, failure in ipairs({ "nil", "error" }) do
            local w = fresh(SCREENS[2].saved, failure)
            local ink = paint(w).ink
            for _, h in ipairs(headings(w)) do
                assert_eq(ink_in(ink, h[2]), (glyph_ink(h[1], h[2], h[3])), failure .. ": " .. h[1])
            end
        end
    end)

    it("falls back to KOReader's UI font for all text when a bundled font cannot load", function()
        for _, failure in ipairs({ "nil", "error", "bold" }) do
            for _, screen in ipairs(SCREENS) do
                local where = failure .. ", " .. screen.name
                local w = fresh(screen.saved, failure)
                local bold = bold_texts(screen)
                paint(w)
                assert_true(#w.text_blocks > 0, where)
                for _, block in ipairs(w.text_blocks) do
                    local tb = block.widget
                    assert_eq(tb.face.name, "cfont", where .. ": " .. tb.text)
                    -- KOReader turns bold on the UI font into its real bold font.
                    assert_eq(tb.bold and true or false, bold[tb.text] == true, where .. ": bold of " .. tb.text)
                end
                tap(w)
                UIManager:runTasks()
                paint(w)
                for _, block in ipairs(w.text_blocks) do
                    assert_eq(block.widget.face.name, "cfont", where .. ", next step: " .. block.widget.text)
                end
                local tries = {}
                for _, name in ipairs(face_requests) do
                    if name ~= "cfont" then tries[name] = (tries[name] or 0) + 1 end
                end
                local expected = failure == "bold" and { regular = 1, bold = 1 } or { regular = 1 }
                local count_of = { regular = 0, bold = 0 }
                for name, n in pairs(tries) do
                    count_of[ends_with(name, BOLD_FILE) and "bold" or "regular"] = n
                end
                assert_eq(count_of, { regular = expected.regular, bold = expected.bold or 0 },
                    where .. ": each bundled file is tried at most once")
            end
        end
    end)

    it("searches body font sizes about 15-20% larger than before", function()
        local before = { text = { 22, 20, 18, 16, 14, 12 }, card = { 20, 18, 16, 15, 14, 13, 12 } }
        local now = { text = RosaryWidget.TEXT_SIZES, card = RosaryWidget.CARD_SIZES }
        for name, old in pairs(before) do
            local sizes = now[name]
            assert_true(type(sizes) == "table" and #sizes >= #old, name .. " sizes")
            for i = 2, #sizes do
                assert_true(sizes[i] < sizes[i - 1] and sizes[i - 1] - sizes[i] <= 2,
                    name .. ": from the largest to the smallest in small steps")
            end
            local ratio = sizes[1] / old[1]
            assert_true(ratio >= 1.15 and ratio <= 1.2,
                ("%s: the largest size %d is %.0f%% above %d"):format(name, sizes[1], 100 * (ratio - 1), old[1]))
            assert_true(sizes[#sizes] <= old[#old], name .. ": long texts can still shrink as far as before")
        end
        -- Short prayers get the largest size.
        local w = fresh()
        local prayer = text_block(w, Content.prayers.sign_of_cross.text)
        assert_true(prayer, "blocks in " .. table.concat(texts(w), " | "))
        assert_eq(prayer.widget.face.orig_size, RosaryWidget.TEXT_SIZES[1], "the Sign of the Cross")
    end)

    it("still fits every prayer and every mystery card in its area", function()
        for _, set_id in ipairs({ "gozosos", "luminosos", "dolorosos", "gloriosos" }) do
            for step = 1, 79 do
                local w = fresh({ date = "2026-10-19", set_id = set_id, step = step })
                local area = w:isCardShown() and w.layout.card or w.layout.text
                local where = set_id .. " step " .. step
                for _, block in ipairs(w.text_blocks) do
                    assert_true(block.y >= area.y and bottom(block) <= area.y + area.h, where .. ": inside its area")
                    assert_eq(block.widget.height, nil, where .. ": " .. block.widget.text:sub(1, 30) .. " is not clipped")
                end
            end
        end
    end)

    it("starts the mystery card a small gap below its pixel heading", function()
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 22 })
        local L, m = w.layout, Content.sets.gozosos.mysteries[2]
        local title, last = text_block(w, m.title), text_block(w, m.meditation)
        assert_true(title and last, "card blocks in " .. table.concat(texts(w), " | "))
        assert_eq(L.card_label.y - L.header_bottom, L.content_gap, "a small gap above the card heading")
        assert_eq(title.y, L.card.y, "the card text starts at the top of its area")
        assert_eq(title.y - (L.card_label.y + L.card_label.h), L.content_gap, "a small gap below the card heading")
        assert_true(#ink_in(paint(w).ink, L.card_label) > 0, "the card heading is drawn")
        local below = L.card.y + L.card.h - bottom(last)
        assert_true(below > L.content_gap, ("not centered: %d px left below the card"):format(below))
    end)

    it("starts the prayer text a small gap below the step label", function()
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 12 })
        local L, m = w.layout, Content.sets.gozosos.mysteries[1]
        local label_bottom = L.label.y + L.label.h
        local line = text_block(w, m.title .. " (" .. m.reference .. ")")
        local prayer = text_block(w, Content.prayers.hail_mary.text)
        assert_true(line and prayer, "blocks in " .. table.concat(texts(w), " | "))
        assert_eq(line.y - label_bottom, L.content_gap, "the mystery line starts a small gap below the label")
        assert_eq(prayer.y, bottom(line) + 2 * L.unit, "the prayer follows the mystery line")

        w = fresh()
        prayer = text_block(w, Content.prayers.sign_of_cross.text)
        assert_true(prayer, "blocks in " .. table.concat(texts(w), " | "))
        assert_eq(prayer.y - label_bottom, L.content_gap, "the prayer starts a small gap below the label")
        local below = L.text.y + L.text.h - bottom(prayer)
        assert_true(below > L.content_gap, ("not centered: %d px left below the prayer"):format(below))
    end)
end)

-- The labels of the menu that a long press opens on `w`.
local function menu_labels(w)
    gesture(w, "hold", 500, 900)
    local out = {}
    for i, row in ipairs(top_dialog().buttons) do out[i] = row[1].text end
    return out
end

local load_catalog = I18n.file_loader(root .. "/rosario.koplugin")

describe("RosaryWidget languages", function()
    it("speaks KOReader's language when the plugin has no language of its own", function()
        local strings = require("l10n.pt")
        local content = I18n.catalog("pt", load_catalog).content
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 79 }, nil, { language = "pt_BR" })
        assert_true(text_block(w, strings.end_hint), "end hint in " .. table.concat(texts(w), " | "))
        assert_true(text_block(w, content.prayers.sign_of_cross.text), "the prayer comes from the Portuguese catalog")
        local L = w.layout
        local ink = paint(w).ink
        assert_eq(ink_in(ink, L.title), (glyph_ink("Santo Rosário", L.title, L.title_scale)), "the title")
        assert_eq(ink_in(ink, L.label), (glyph_ink("Sinal da Cruz", L.label, L.label_scale)), "the step label")
        assert_eq(menu_labels(w)[1], "Recomeçar")
    end)

    it("prefers the plugin's language setting over KOReader's", function()
        local w = fresh(nil, nil, { language = "pt_BR", rosario_language = "it" })
        assert_eq(menu_labels(w)[1], "Ricomincia")
    end)

    it("falls back to English for a language it does not have", function()
        local w = fresh(nil, nil, { language = "fr" })
        assert_eq(menu_labels(w), { "Restart", "Change mysteries", "View mystery", "Hide text", "Language", "Exit" })
        local chooser
        find_button(top_dialog(), "Change mysteries").callback()
        chooser = top_dialog()
        assert_eq(chooser.title, "Change mysteries")
        assert_true(find_button(chooser, "Joyful Mysteries").text:find("(today)", 1, true), "today's set in English")
    end)

    it("shows the mystery card and the decade number in the current language", function()
        local en = I18n.catalog("en", load_catalog)
        local m = en.content.sets.gozosos.mysteries[2]
        local w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 22 }, nil, { language = "en_US" })
        assert_true(text_block(w, "Fruit of the mystery: " .. m.fruit), "fruit in " .. table.concat(texts(w), " | "))
        assert_true(text_block(w, "“" .. m.scripture.text .. "”"), "English quotation marks")
        local L = w.layout
        assert_eq(ink_in(paint(w).ink, L.card_label), (glyph_ink("Second mystery", L.card_label, L.label_scale)))
        w = fresh({ date = "2026-10-19", set_id = "gozosos", step = 30 }, nil, { language = "en_US" })
        assert_eq(ink_in(paint(w).ink, L.ring_label), (glyph_ink("2", L.ring_label, L.ring_label_scale)))
    end)

    it("offers every language by its own name, and KOReader's language", function()
        local w = fresh()
        menu_labels(w)
        find_button(top_dialog(), "Idioma").callback()
        local chooser = top_dialog()
        assert_eq(chooser.title, "Idioma")
        local labels = {}
        for i, row in ipairs(chooser.buttons) do labels[i] = row[1].text end
        assert_eq(labels, { "• Automático (como KOReader)", "Español", "English", "Português", "Latina", "Italiano" },
            "the current choice is marked")

        w = fresh(nil, nil, { language = "es", rosario_language = "la" })
        menu_labels(w)
        find_button(top_dialog(), "Lingua").callback()
        labels = {}
        for i, row in ipairs(top_dialog().buttons) do labels[i] = row[1].text end
        assert_eq(labels, { "Sicut in KOReader", "Español", "English", "Português", "• Latina", "Italiano" })
    end)

    it("switches the language at once, keeps the place and remembers the choice", function()
        local w = fresh({ date = "2026-10-19", set_id = "dolorosos", step = 30 })
        UIManager:show(w)
        menu_labels(w)
        find_button(top_dialog(), "Idioma").callback()
        UIManager.dirty = {}
        find_button(top_dialog(), "English").callback()
        assert_eq(G_reader_settings.data.rosario_language, "en", "the choice is saved")
        assert_true(G_reader_settings.flushes > 0, "and flushed")
        assert_eq(G_reader_settings.data.language, "es", "KOReader's own language is untouched")
        assert_eq({ w.session.set_id, w.session.index }, { "dolorosos", 30 }, "the same place in the rosary")
        assert_eq(UIManager:modes()[#UIManager.dirty], "full", "repainted at once")
        for _, closed in ipairs(UIManager.closed) do assert_true(closed ~= w, "the rosary stays open") end
        local L = w.layout
        local en = I18n.catalog("en", load_catalog)
        assert_eq(ink_in(paint(w).ink, L.label), (glyph_ink("Hail Mary 7/10", L.label, L.label_scale)))
        assert_true(text_block(w, en.content.prayers.hail_mary.text), "the prayer of the English catalog")
        assert_eq(menu_labels(w)[1], "Restart")

        -- A rosary opened later, as after a restart, speaks the same language.
        local again = RosaryWidget:new{}
        assert_eq(again.lang, "en")
        assert_eq(again.session.index, 30)
    end)

    it("follows KOReader's language again with the automatic choice", function()
        local w = fresh(nil, nil, { language = "it_IT", rosario_language = "en" })
        menu_labels(w)
        find_button(top_dialog(), "Language").callback()
        find_button(top_dialog(), "Automatic").callback()
        assert_eq(G_reader_settings.data.rosario_language, nil, "the choice is removed")
        assert_true(G_reader_settings.flushes > 0, "and flushed")
        assert_eq(w.lang, "it")
        assert_eq(menu_labels(w)[1], "Ricomincia")
    end)
end)

os.date = real_date
for name in pairs(STUBS) do package.loaded[name] = nil end
clear_orders()
