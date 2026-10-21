--[[--
Full-screen rosary widget: pixel-art bead diagram, prayer text, gestures,
event-driven e-ink animations and per-day progress persistence.

Gestures: tap or swipe west = next step, swipe east = previous step,
swipe south or the X button = close, hold or the menu button = menu. On the
last step, moving forward starts a new rosary. The menu's Language entry
switches the language at once and keeps the place in the rosary.

Moving forward plays a short animation in place of a vibration, which the
Kindle lacks: a pixel ripple spreads from each bead as it fills, and a wave
of sparkles runs along the beads at each Glory Be.

Headings (title, mystery set, step label, the mystery card's ordinal heading
and the decade number) are drawn with the 5x9 bitmap font of pixelart.lua.
Prayers, scripture, meditations and hints are text boxes set in Roboto,
bundled with the plugin, at the largest size that fits.

Strings and content come from the catalog of the language I18n.resolve
picks from KOReader's reader settings (see i18n.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen

-- Sibling modules are loaded by path so their generic names cannot collide
-- with modules of other plugins in package.loaded.
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local function load_local(name)
    return dofile(plugin_dir .. "/" .. name .. ".lua")
end
local Rosary = load_local("rosary")
local PixelArt = load_local("pixelart")
local Layout = load_local("layout")
local I18n = load_local("i18n")

local INK = Blitbuffer.COLOR_BLACK
local PAPER = Blitbuffer.COLOR_WHITE
local TONE = Blitbuffer.COLOR_GRAY
local CHAIN = Blitbuffer.COLOR_DARK_GRAY

local SETTINGS_FILE = "rosario.lua"
-- Roboto Regular and its real Bold (SIL OFL 1.1, see fonts/OFL.txt). If
-- either cannot be loaded, the text falls back to KOReader's UI font.
local FONT_FILES = { regular = "fonts/Roboto-Regular.ttf", bold = "fonts/Roboto-Bold.ttf" }
local FALLBACK_FONT = "cfont"
local FRAME_DELAY = 0.08 -- seconds between bead fill frames
local RIPPLE_FRAME = 0.1 -- seconds each ring of a bead ripple stays on screen
local WAVE_FRAME = 0.1 -- seconds between the stages of a Glory Be sparkle wave
local MIN_FONT_SIZE = 10
-- KOReader font size of the end hint (about 30 px on the Kindle Basic 2024).
local END_HINT_SIZE = 17

local SPRITE_OF_KIND = { small = "small_bead", large = "large_bead", cross = "crucifix" }

local floor = math.floor

local function to_geom(r)
    return Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
end

--- Draw `text` with the bitmap font, centered in `row`, at the largest
-- integer scale up to `max_scale` whose width fits the row.
local function draw_heading(fill, text, row, max_scale)
    local scale = PixelArt.fit_scale(text, row.w, max_scale)
    local w, h = PixelArt.text_width(text, scale), PixelArt.text_height(scale)
    PixelArt.draw_text(fill, row.x + floor((row.w - w) / 2), row.y + floor((row.h - h) / 2), text, scale, INK)
end

local load_file = I18n.file_loader(plugin_dir, function(...) logger.warn(...) end)
local catalogs = {}

local RosaryWidget = InputContainer:extend{
    name = "rosario",
    covers_fullscreen = true, -- hint for UIManager:_repaint()
}

--- The strings and content of `lang`, loaded once per language.
function RosaryWidget.catalog(lang)
    catalogs[lang] = catalogs[lang] or I18n.catalog(lang, load_file)
    return catalogs[lang]
end

--- The language to show, from KOReader's reader settings (G_reader_settings).
function RosaryWidget.language(reader_settings)
    return I18n.resolve(function(key)
        return reader_settings and reader_settings:readSetting(key)
    end)
end

-- KOReader font sizes the text fitter tries, from the largest. They start
-- 15-20% above the largest sizes used before Roboto (22 for prayers, 20 for
-- the mystery card), and still go down to the old smallest size, so long
-- texts fit as before.
RosaryWidget.TEXT_SIZES = { 26, 24, 22, 20, 18, 16, 14, 12 }
RosaryWidget.CARD_SIZES = { 24, 22, 20, 18, 17, 16, 15, 14, 13, 12 }

--- Name of a bundled font file in the form Font:getFace opens. The stable
-- release (v2026.07.1, frontend/ui/font.lua:306) prepends KOReader's fonts
-- folder, "./fonts", to every name; master does the same for any name that
-- does not start with "./" or "/". A relative plugin folder is relative to
-- the KOReader folder, the working directory, so the name climbs out of the
-- fonts folder first: "../plugins/..." resolves on both. An absolute folder
-- is kept as a path, which only master opens as such.
-- @string dir the plugin folder
-- @string file the font file, relative to the plugin folder
function RosaryWidget.fontPath(dir, file)
    if dir:sub(1, 1) == "/" then return dir .. "/" .. file end
    while dir:sub(1, 2) == "./" do dir = dir:sub(3) end
    return "../" .. dir .. "/" .. file
end

function RosaryWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. SETTINGS_FILE)
    self.reader_settings = self.reader_settings or G_reader_settings
    self:loadLanguage()
    local saved = self.settings:readSetting("state")
    local now = os.date("*t")
    self.today = { date = Rosary.date_key(now), wday = now.wday }
    self.session = Rosary.resume(saved, self.today)
    self.show_text = not (type(saved) == "table" and saved.show_text == false)
    self.card_open = false
    self.anim = nil
    self.tasks = {}
    self.text_blocks = {}
    self.fit_cache = {}
    -- nil once a bundled font fails to load
    self.font_paths = {
        regular = RosaryWidget.fontPath(plugin_dir, FONT_FILES.regular),
        bold = RosaryWidget.fontPath(plugin_dir, FONT_FILES.bold),
    }
    -- Load both bundled faces before any text is laid out, so a missing file
    -- turns all of the text to the UI font, never only part of it.
    self:getFace(RosaryWidget.TEXT_SIZES[1], false)
    self:getFace(RosaryWidget.TEXT_SIZES[1], true)

    self.layout = Layout.compute(self.dimen.w, self.dimen.h)
    self.views = {
        ring = { beads = Layout.ring_beads(self.layout), chain = Layout.ring_chain(self.layout) },
        pendant = Layout.pendant(self.layout),
    }
    self.views.ring.wave = Layout.ring_wave(self.layout)
    self.views.pendant.wave = Layout.pendant_wave(self.layout)
    self.close_hit = to_geom(self.layout.close_hit)
    self.menu_hit = to_geom(self.layout.menu_hit)
    self.frames = {
        small = PixelArt.bead_frames(PixelArt.sprites.small_bead),
        large = PixelArt.bead_frames(PixelArt.sprites.large_bead),
    }
    self.ripples = {
        small = PixelArt.ripple_frames(PixelArt.sprites.small_bead),
        large = PixelArt.ripple_frames(PixelArt.sprites.large_bead),
    }
    self.halos = {}
    for kind, sprite in pairs(SPRITE_OF_KIND) do
        self.halos[kind] = PixelArt.halo(PixelArt.sprites[sprite], Layout.HALO_GAP)
    end

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextStep = { { Device.input.group.PgFwd } }
        self.key_events.PrevStep = { { Device.input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        local range = function() return self.dimen end
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = range } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = range } }
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = range } }
    end

    self:rebuildText()
    self:save()
end

-- Language --------------------------------------------------------------------------

function RosaryWidget:loadLanguage()
    local catalog = RosaryWidget.catalog(RosaryWidget.language(self.reader_settings))
    self.lang, self.strings, self.content = catalog.lang, catalog.strings, catalog.content
end

--- Keep `code` as the plugin's language, or follow KOReader's language
-- again when `code` is nil, and repaint in that language at the same step.
function RosaryWidget:setLanguage(code)
    local settings = self.reader_settings
    if settings then
        if code then
            settings:saveSetting(I18n.SETTING, code)
        else
            settings:delSetting(I18n.SETTING)
        end
        settings:flush()
    end
    self:loadLanguage()
    self:rebuildText()
    UIManager:setDirty(self, "full")
end

-- Persistence ---------------------------------------------------------------------

function RosaryWidget:save()
    local state = self.session:serialize()
    state.date = self.today.date
    state.show_text = self.show_text
    self.settings:saveSetting("state", state)
    self.settings:flush()
end

function RosaryWidget:onFlushSettings()
    self:save()
end

-- Text ------------------------------------------------------------------------------

function RosaryWidget:freeText()
    for _, block in ipairs(self.text_blocks) do block.widget:free() end
    self.text_blocks = {}
end

--- The face for regular or `bold` text, and the `bold` flag to give the
-- text box. A bundled Roboto face is used as it is: its bold is the real
-- Bold file, so the text box must not synthesize bold on top of it. Once a
-- bundled file has failed to load (Font:getFace logs and returns nil for a
-- file it cannot open), all text uses KOReader's UI font, whose bold the
-- text box turns into the UI font's own bold file.
function RosaryWidget:getFace(size, bold)
    if self.font_paths then
        local path = bold and self.font_paths.bold or self.font_paths.regular
        local ok, face = pcall(Font.getFace, Font, path, size)
        if ok and face then return face, false end
        logger.warn("rosario: cannot load", path, "- using the UI font:", face)
        self.font_paths = nil
    end
    return Font:getFace(FALLBACK_FONT, size), bold
end

--- A text box for `block` at font size `size` plus `block.delta`. With a
-- `height`, the text is clipped.
function RosaryWidget:makeText(block, size, width, height)
    local face, bold = self:getFace(math.max(MIN_FONT_SIZE, size + (block.delta or 0)), block.bold)
    return TextBoxWidget:new{
        text = block.text,
        face = face,
        bold = bold,
        alignment = block.align or "center",
        width = width,
        height = height,
        height_overflow_show_ellipsis = height ~= nil,
    }
end

local function free_all(widgets)
    for _, w in ipairs(widgets) do w:free() end
end

--- Stack text blocks from the top of `area`, using the largest font size
-- that fits. `sizes` is sorted from largest to smallest; a binary search
-- keeps the number of text renderings low, and the chosen size is cached
-- per content so repeated prayers (53 Hail Marys) render only once each.
function RosaryWidget:layoutBlocks(area, blocks, sizes)
    local gap = 2 * self.layout.unit
    local function build(size)
        local widgets, total = {}, 0
        for j, block in ipairs(blocks) do
            widgets[j] = self:makeText(block, size, area.w)
            total = total + widgets[j]:getSize().h
        end
        return widgets, total + gap * math.max(0, #widgets - 1)
    end

    local keys = {}
    for i, block in ipairs(blocks) do keys[i] = block.text end
    -- The same prayer can be laid out in areas of different heights (the
    -- last step makes room for the end hint).
    local key = area.y .. "\0" .. area.h .. "\0" .. table.concat(keys, "\0")
    local candidates = self.fit_cache[key] and { self.fit_cache[key] } or sizes

    local best_size, best
    local lo, hi = 1, #candidates
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        local widgets, total = build(candidates[mid])
        if total <= area.h then
            if best then free_all(best) end
            best_size, best = candidates[mid], widgets
            hi = mid - 1
        else
            free_all(widgets)
            lo = mid + 1
        end
    end
    if not best then
        -- Nothing fits: use the smallest size and clip the last block so it
        -- never overflows into the pips.
        local total
        best_size = candidates[#candidates]
        best, total = build(best_size)
        local n = #best
        if n > 0 then
            local used = total - best[n]:getSize().h
            best[n]:free()
            best[n] = self:makeText(blocks[n], best_size, area.w, math.max(1, area.h - used))
        end
    end
    self.fit_cache[key] = best_size

    local heights = {}
    for i, w in ipairs(best) do heights[i] = w:getSize().h end
    for i, y in ipairs(Layout.stack(area, heights, gap)) do
        self.text_blocks[#self.text_blocks + 1] = { widget = best[i], x = area.x, y = y }
    end
end

--- Add `text` at font size `size` at the bottom of `area`, and return the
-- part of `area` left above it.
function RosaryWidget:addFooter(text, size, area)
    local widget = self:makeText({ text = text }, size, area.w)
    local h = widget:getSize().h
    self.text_blocks[#self.text_blocks + 1] = { widget = widget, x = area.x, y = area.y + area.h - h }
    local gap = 2 * self.layout.unit
    return { x = area.x, y = area.y, w = area.w, h = math.max(0, area.h - h - gap) }
end

function RosaryWidget:currentMystery()
    local step = self.session:current()
    local n = step.mystery or (step.section == "closing" and 5 or 1)
    return self.content.sets[self.session.set_id].mysteries[n], n
end

function RosaryWidget:isCardShown()
    return self.card_open or self.session:current().kind == "announcement"
end

--- The text blocks of the mystery card; its ordinal heading is painted.
function RosaryWidget:cardBlocks(m)
    local s, t = m.scripture, self.strings
    local blocks = {
        { text = m.title, bold = true, delta = 2 },
        { text = m.reference, delta = -2 },
        { text = t.quote:format(s.text), align = "left" },
        { text = "(" .. s.citation .. ", " .. s.translation .. ")", delta = -4, align = "right" },
        { text = t.fruit:format(m.fruit), bold = true },
        { text = m.meditation, align = "left" },
    }
    if self.card_open then
        blocks[#blocks + 1] = { text = t.card_hint, delta = -4 }
    end
    return blocks
end

function RosaryWidget:rebuildText()
    self:freeText()
    local L = self.layout
    local step = self.session:current()
    if self:isCardShown() then
        self:layoutBlocks(L.card, self:cardBlocks(self:currentMystery()), RosaryWidget.CARD_SIZES)
        return
    end
    local blocks = {}
    if step.mystery then
        -- Keep the mystery in sight while praying its decade.
        local m = self.content.sets[self.session.set_id].mysteries[step.mystery]
        blocks[#blocks + 1] = { text = m.title .. " (" .. m.reference .. ")", bold = true, delta = -4 }
    end
    if self.show_text then
        blocks[#blocks + 1] = { text = self.content.prayers[step.prayer].text }
    end
    local area = L.text
    if self.session:is_last() then
        -- A tap here starts a new rosary (see goNext).
        area = self:addFooter(self.strings.end_hint, END_HINT_SIZE, area)
    end
    self:layoutBlocks(area, blocks, RosaryWidget.TEXT_SIZES)
end

-- Painting --------------------------------------------------------------------------

--- The title, the mystery set, the menu and close buttons and the dotted
-- line under the header.
function RosaryWidget:paintHeader(fill)
    local L = self.layout
    draw_heading(fill, self.strings.title, L.title, L.title_scale)
    draw_heading(fill, self.content.sets[self.session.set_id].title, L.set, L.set_scale)
    PixelArt.draw_sprite(fill, L.menu.x, L.menu.y, PixelArt.sprites.menu, L.close_scale, { ["#"] = INK })
    PixelArt.draw_sprite(fill, L.close.x, L.close.y, PixelArt.sprites.close, L.close_scale, { ["#"] = INK })
    for x = L.margin, L.W - L.margin - L.unit, 2 * L.unit do
        fill(x, L.header_bottom - L.unit, L.unit, L.unit, CHAIN)
    end
end

function RosaryWidget:paintBead(fill, bead, state, frame)
    local s = self.layout.bead_scale
    if bead.kind == "cross" then
        PixelArt.draw_sprite(fill, bead.x, bead.y, PixelArt.sprites.crucifix, s, { ["#"] = INK, ["+"] = TONE })
    else
        local frames = self.frames[bead.kind]
        local grid = frame and frames[frame] or (state == "upcoming" and frames[1] or frames[3])
        -- Clear the bead area first so outline frames stay hollow.
        PixelArt.draw_sprite(fill, bead.x, bead.y, frames[3], s, { ["#"] = PAPER })
        PixelArt.draw_sprite(fill, bead.x, bead.y, grid, s, { ["#"] = INK })
    end
    if state == "current" and not frame then
        local pad = Layout.HALO_PAD * s
        PixelArt.draw_sprite(fill, bead.x - pad, bead.y - pad, self.halos[bead.kind], s, { ["#"] = INK })
    end
end

--- The beads shown in the diagram for `step`: the decade ring or the
-- introductory pendant (also shown for the closing prayers).
function RosaryWidget:viewOf(step)
    return step.section == "decade" and self.views.ring or self.views.pendant
end

function RosaryWidget:paintDiagram(fill, step)
    local s = self.layout.bead_scale
    local view = self:viewOf(step)
    local anim = self.anim
    for _, dot in ipairs(view.chain) do
        fill(dot.x, dot.y, dot.w, dot.h, CHAIN)
    end
    -- The current bead shows its fill frame, and stays solid with no halo
    -- while its ripple spreads.
    local bead_frame
    if anim and anim.kind == "bead" then
        bead_frame = anim.frame
    elseif anim and anim.kind == "ripple" then
        bead_frame = 3
    end
    for _, bead in ipairs(view.beads) do
        local state = Rosary.bead_state(step, bead.slot)
        self:paintBead(fill, bead, state, state == "current" and bead_frame or nil)
    end
    if step.section == "decade" then
        local L = self.layout
        draw_heading(fill, I18n.decade_number(step.decade, self.strings), L.ring_label, L.ring_label_scale)
    end
    if anim and anim.kind == "ripple" then
        PixelArt.draw_sprite(fill, anim.x, anim.y, anim.grid, s, { ["#"] = INK })
    elseif anim and anim.kind == "wave" then
        -- Each sparkle opens at its stage and twinkles out at the next one.
        local sparkle = PixelArt.sprites.sparkle
        for _, site in ipairs(view.wave.sites) do
            local grid
            if site.stage == anim.stage then
                grid = sparkle[1]
            elseif site.stage == anim.stage - 1 then
                grid = sparkle[2]
            end
            if grid then PixelArt.draw_sprite(fill, site.x, site.y, grid, s, { ["#"] = INK }) end
        end
    end
end

function RosaryWidget:paintPips(fill, step)
    local L = self.layout
    local done = self.session:completed_decades()
    local frames = self.frames.small
    for i, pip in ipairs(L.pips) do
        local grid = frames[1]
        if i <= done then
            grid = frames[3]
        elseif step.decade == i then
            grid = frames[2]
        end
        PixelArt.draw_sprite(fill, pip.x, pip.y, grid, L.pip_scale, { ["#"] = INK })
    end
end

function RosaryWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local function fill(rx, ry, w, h, color)
        bb:paintRect(x + rx, y + ry, w, h, color)
    end
    local L = self.layout
    local step = self.session:current()
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, PAPER)
    self:paintHeader(fill)
    if self:isCardShown() then
        local _, n = self:currentMystery()
        draw_heading(fill, I18n.mystery_heading(n, self.strings), L.card_label, L.label_scale)
    else
        self:paintDiagram(fill, step)
        draw_heading(fill, I18n.step_label(step, self.strings), L.label, L.label_scale)
    end
    -- Text boxes paint their white background too: the layout keeps them
    -- clear of the sprites and the headings.
    for _, block in ipairs(self.text_blocks) do
        block.widget:paintTo(bb, x + block.x, y + block.y)
    end
    self:paintPips(fill, step)
end

-- Animation -------------------------------------------------------------------------

function RosaryWidget:schedule(delay, fn)
    local task
    task = function()
        for i, t in ipairs(self.tasks) do
            if t == task then
                table.remove(self.tasks, i)
                break
            end
        end
        fn()
    end
    self.tasks[#self.tasks + 1] = task
    UIManager:scheduleIn(delay, task)
end

--- Stop the running animation and drop its pending frames. Whoever cancels
-- repaints the whole widget next (the next step, or the step at rest under
-- the hold menu), which wipes any ripple or sparkle left on the screen.
-- @treturn bool whether an animation was running
function RosaryWidget:cancelAnimation()
    for _, task in ipairs(self.tasks) do UIManager:unschedule(task) end
    self.tasks = {}
    local running = self.anim ~= nil
    self.anim = nil
    return running
end

--- Play an animation: a list of frames { delay, anim, mode, region }.
-- Each frame shows `anim` and refreshes `region` (nil for the whole widget)
-- with `mode`. The first frame is shown now; the last one should clear
-- `anim`.
-- Each frame schedules the next one `delay` seconds after it runs, rather
-- than all of them up front: KOReader runs every due task before it repaints,
-- so late frames would merge into one refresh and a frame could be lost.
function RosaryWidget:play(frames)
    local function show(i)
        local f = frames[i]
        self.anim = f.anim
        UIManager:setDirty(self, f.mode, f.region)
        local next_frame = frames[i + 1]
        if next_frame then
            self:schedule(next_frame.delay, function() show(i + 1) end)
        end
    end
    show(1)
end

function RosaryWidget:currentBead(step)
    for _, bead in ipairs(self:viewOf(step).beads) do
        if bead.slot == step.bead then return bead end
    end
end

--- Fill the current bead in three frames (outline, 50% dither, solid), then
-- send a ripple out from it: rings that grow and fade, clipped to the
-- diagram and kept off the other beads. Fill frames refresh the bead region
-- and ripple frames the ripple's box, both with "fast"; a last "ui" refresh
-- of that box wipes the ripple and shows the current-bead halo.
function RosaryWidget:animateBead(bead, beads)
    local rings = self.ripples[bead.kind]
    local ripple, free = Layout.ripple(self.layout, bead, beads, #rings[1])
    local region = to_geom(Layout.bead_region(self.layout, bead))
    local box = to_geom(ripple.region)
    local frames = { { anim = { kind = "bead", frame = 1 }, mode = "ui" } }
    for frame = 2, 3 do
        frames[frame] = { delay = FRAME_DELAY, anim = { kind = "bead", frame = frame },
            mode = "fast", region = region }
    end
    for i, ring in ipairs(rings) do
        frames[#frames + 1] = {
            delay = i == 1 and FRAME_DELAY or RIPPLE_FRAME,
            anim = { kind = "ripple", x = ripple.x, y = ripple.y, grid = PixelArt.clip(ring, free) },
            mode = "fast", region = box,
        }
    end
    frames[#frames + 1] = { delay = RIPPLE_FRAME, mode = "ui", region = box }
    self:play(frames)
end

--- At a Glory Be, play the sparkle wave of the beads in view (see
-- Layout.ring_wave and Layout.pendant_wave): one stage per frame, each
-- sparkle shown in its two frames one stage apart. The first frame repaints
-- the new step with "ui"; the others refresh the wave's box with "fast", and
-- a last "ui" refresh of that box wipes the sparkles.
function RosaryWidget:animateGloryBe(step)
    local wave = self:viewOf(step).wave
    local box = to_geom(wave.region)
    local frames = { { anim = { kind = "wave", stage = 1 }, mode = "ui" } }
    -- One stage past the last one lets its sparkles twinkle out.
    for stage = 2, wave.stages + 1 do
        frames[stage] = { delay = WAVE_FRAME, anim = { kind = "wave", stage = stage }, mode = "fast", region = box }
    end
    frames[#frames + 1] = { delay = WAVE_FRAME, mode = "ui", region = box }
    self:play(frames)
end

-- Navigation ------------------------------------------------------------------------

function RosaryWidget:afterMove(forward)
    self:save()
    self:rebuildText()
    local step = self.session:current()
    if forward and Rosary.is_decade_start(step) then
        -- A full refresh at the start of each decade clears accumulated ghosting.
        UIManager:setDirty(self, "full")
        return
    end
    -- Animations play only when moving forward.
    local bead = forward and step.bead ~= nil and step.kind ~= "cross" and self:currentBead(step)
    if bead then
        self:animateBead(bead, self:viewOf(step).beads)
    elseif forward and step.prayer == "glory_be" then
        self:animateGloryBe(step)
    else
        UIManager:setDirty(self, "ui")
    end
end

function RosaryWidget:goNext()
    self:cancelAnimation()
    if self.card_open then
        self:closeCard()
        return true
    end
    if self.session:next() then
        self:afterMove(true)
    else
        -- The rosary is finished, as its end hint says: start a new one.
        self:restart()
    end
    return true
end

function RosaryWidget:goPrev()
    self:cancelAnimation()
    self.card_open = false
    if self.session:prev() then
        self:afterMove(false)
    else
        self:rebuildText()
        UIManager:setDirty(self, "ui")
    end
    return true
end

function RosaryWidget:onNextStep()
    return self:goNext()
end

function RosaryWidget:onPrevStep()
    return self:goPrev()
end

function RosaryWidget:onTap(_, ges)
    if ges and ges.pos and self.close_hit:contains(ges.pos) then
        return self:onClose()
    end
    if ges and ges.pos and self.menu_hit:contains(ges.pos) then
        return self:showMenu()
    end
    return self:goNext()
end

function RosaryWidget:onSwipe(_, ges)
    local direction = ges and ges.direction
    if direction == "west" then
        return self:goNext()
    elseif direction == "east" then
        return self:goPrev()
    elseif direction == "south" then
        return self:onClose()
    elseif direction == "north" then
        return true
    end
    -- Diagonal swipe: full refresh, and let it propagate (e.g. screenshots).
    UIManager:setDirty(nil, "full")
    return false
end

-- Menu ------------------------------------------------------------------------------

function RosaryWidget:openCard()
    if self:isCardShown() then return end
    self.card_open = true
    self:rebuildText()
    UIManager:setDirty(self, "ui")
end

function RosaryWidget:closeCard()
    self.card_open = false
    self:rebuildText()
    UIManager:setDirty(self, "ui")
end

function RosaryWidget:restart()
    self.session:reset()
    self.card_open = false
    self:save()
    self:rebuildText()
    UIManager:setDirty(self, "full")
end

function RosaryWidget:toggleText()
    self.show_text = not self.show_text
    self:save()
    self:rebuildText()
    UIManager:setDirty(self, "ui")
end

function RosaryWidget:chooseSet(set_id)
    self.session:set_mystery_set(set_id)
    self:save()
    self:rebuildText()
    UIManager:setDirty(self, "full")
end

function RosaryWidget:showSetChooser()
    local today_set = Rosary.set_for_weekday(self.today.wday)
    local dialog
    local buttons = {}
    for _, set_id in ipairs(Rosary.SET_ORDER) do
        local text = self.content.sets[set_id].title
        if set_id == today_set then text = self.strings.today:format(text) end
        if set_id == self.session.set_id then text = "• " .. text end
        buttons[#buttons + 1] = { {
            text = text,
            callback = function()
                UIManager:close(dialog)
                self:chooseSet(set_id)
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title = self.strings.change_mysteries,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Choose the language: KOReader's own (the automatic choice) or one of
-- I18n.LANGUAGES, each named in its own language. The choice in effect is
-- marked.
function RosaryWidget:showLanguageChooser()
    local chosen = self.reader_settings and self.reader_settings:readSetting(I18n.SETTING)
    if not I18n.is_supported(chosen) then chosen = nil end
    local dialog
    local function button(text, code)
        if code == chosen then text = "• " .. text end
        return { {
            text = text,
            callback = function()
                UIManager:close(dialog)
                self:setLanguage(code)
            end,
        } }
    end
    local buttons = { button(self.strings.automatic, nil) }
    for _, code in ipairs(I18n.LANGUAGES) do
        buttons[#buttons + 1] = button(I18n.NAMES[code], code)
    end
    dialog = ButtonDialog:new{
        title = self.strings.language,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- The menu, opened by a long press or by the menu button. A running
-- animation stops and the step is repainted at rest under the dialog.
function RosaryWidget:showMenu()
    if self:cancelAnimation() then
        UIManager:setDirty(self, "ui")
    end
    local dialog
    local function item(text, action)
        return { {
            text = text,
            callback = function()
                UIManager:close(dialog)
                action()
            end,
        } }
    end
    local t = self.strings
    dialog = ButtonDialog:new{
        title = t.name,
        title_align = "center",
        buttons = {
            item(t.restart, function() self:restart() end),
            item(t.change_mysteries, function() self:showSetChooser() end),
            item(t.view_mystery, function() self:openCard() end),
            item(self.show_text and t.hide_text or t.show_text, function() self:toggleText() end),
            item(t.language, function() self:showLanguageChooser() end),
            item(t.exit, function() self:onClose() end),
        },
    }
    UIManager:show(dialog)
    return true
end

function RosaryWidget:onHold()
    return self:showMenu()
end

-- Lifecycle -------------------------------------------------------------------------

function RosaryWidget:onClose()
    self:cancelAnimation()
    self:save()
    UIManager:close(self, "flashui")
    return true
end

function RosaryWidget:onCloseWidget()
    self:cancelAnimation()
    self:freeText()
end

return RosaryWidget
