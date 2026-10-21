--[[--
Screen geometry of the rosary widget: header, bead diagram, label, text
areas and decade pips, plus the bead positions of the decade ring and the
introductory pendant, and how a column of text blocks sits in its area.

Pure Lua (no KOReader dependencies) so the layout can be checked with LuaJIT
for several screen sizes. Rectangles are plain { x, y, w, h } tables in
screen pixels; sizes of sprites are in art pixels and are scaled by
`bead_scale`. Headings use the 5x9 bitmap font of pixelart.lua at the
integer scales `*_scale`; each heading row is one line of glyphs high.
]]

local Layout = {}

-- Sprite sizes in art pixels (checked against pixelart.lua by the specs).
Layout.SMALL = 9
Layout.LARGE = 13
Layout.CROSS_W = 11
Layout.CROSS_H = 17
Layout.SPARKLE = 7
Layout.CLOSE = 7 -- the close X, and the menu button of the same size
Layout.HALO_GAP = 1
Layout.HALO_PAD = Layout.HALO_GAP + 1 -- the halo ring sits one pixel past the gap

-- Glyphs of the bitmap font, in art pixels, and the blank columns between them.
Layout.GLYPH_W = 5
Layout.GLYPH_H = 9
Layout.SPACING = 1

-- Gap in units above the mystery card's heading, and above the text under
-- the step label or that heading, so nothing sticks to the header line or
-- to a heading: about one small heading line (30 px on the Kindle Basic 2024).
local CONTENT_GAP = 6
local RING_SLOTS = 11
-- Minimum ring radius, in bead scale units, that keeps neighbouring bead
-- regions (bead plus halo) from overlapping on an 11-slot ring.
local MIN_RING_RADIUS = 33

local floor = math.floor

local function rect(x, y, w, h)
    return { x = x, y = y, w = w, h = h }
end

local function overlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function inside(inner, outer)
    return inner.x >= outer.x and inner.y >= outer.y
        and inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h
end

local function intersect(a, b)
    local x, y = math.max(a.x, b.x), math.max(a.y, b.y)
    local x2, y2 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
    return rect(x, y, math.max(0, x2 - x), math.max(0, y2 - y))
end

-- The smallest rectangle that contains every rectangle of a non-empty list.
local function bounds(list)
    local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
    for _, r in ipairs(list) do
        x1, y1 = math.min(x1, r.x), math.min(y1, r.y)
        x2, y2 = math.max(x2, r.x + r.w), math.max(y2, r.y + r.h)
    end
    return rect(x1, y1, x2 - x1, y2 - y1)
end

-- Width in pixels of `n` glyphs of the bitmap font at `scale`.
local function text_w(n, scale)
    return (n * Layout.GLYPH_W + (n - 1) * Layout.SPACING) * scale
end

-- Distance from the ring center to each sparkle center, along both axes.
local function sparkle_offset(s, r)
    return math.max(13 * s, floor(0.38 * r))
end

function Layout.compute(W, H)
    local u = math.max(2, floor(math.min(W, H) / 200))
    local m = 4 * u
    local L = { W = W, H = H, unit = u, margin = m }

    -- Header: title, mystery set, a close button in the top-right corner and,
    -- mirroring it in the top-left corner, a menu button of the same size.
    local close = Layout.CLOSE * u
    L.close_scale = u
    L.close = rect(W - m - close, m, close, close)
    L.close_hit = rect(W - close - 2 * m, 0, close + 2 * m, close + 2 * m)
    L.menu = rect(m, m, close, close)
    L.menu_hit = rect(0, 0, close + 2 * m, close + 2 * m)
    -- Each heading row holds one line of glyphs, centered across the row.
    local glyph_h = Layout.GLYPH_H
    L.title_scale = u
    local side = m + close + 2 * u -- keeps the centered title clear of both buttons
    L.title = rect(side, m, W - 2 * side, glyph_h * L.title_scale)
    L.set_scale = math.max(2, u - 2)
    L.set = rect(m, L.title.y + L.title.h + 2 * u, W - 2 * m, glyph_h * L.set_scale)
    L.header_bottom = L.set.y + L.set.h + 2 * u

    -- Bottom: five decade pips.
    L.pip_scale = math.max(2, u - 2)
    local pw = Layout.SMALL * L.pip_scale
    local pips_w = 9 * pw
    local px = floor((W - pips_w) / 2)
    L.pips_region = rect(px, H - m - pw, pips_w, pw)
    L.pips = {}
    for i = 1, 5 do
        L.pips[i] = { x = px + (i - 1) * 2 * pw, y = L.pips_region.y }
    end

    -- Middle: bead diagram, step label, prayer text. The text starts a small
    -- gap below the label.
    L.content_gap = CONTENT_GAP * u
    L.diagram = rect(0, L.header_bottom + u, W, floor(H * 0.36))
    L.label_scale = math.max(2, u - 1)
    L.label = rect(m, L.diagram.y + L.diagram.h + u, W - 2 * m, glyph_h * L.label_scale)
    L.text = rect(m, L.label.y + L.label.h + L.content_gap, W - 2 * m, 0)
    L.text.h = L.pips_region.y - 3 * u - L.text.y
    -- The mystery card replaces the diagram and the step label: its ordinal
    -- heading starts a small gap below the header line, at the size of the
    -- step label, and its text the same gap below that heading.
    L.card_label = rect(m, L.header_bottom + L.content_gap, W - 2 * m, glyph_h * L.label_scale)
    L.card = rect(m, L.card_label.y + L.card_label.h + L.content_gap, W - 2 * m, 0)
    L.card.h = L.pips_region.y - 3 * u - L.card.y

    -- Decade ring: shrink the bead scale until 11 beads fit around the ring.
    local cx, cy = floor(W / 2), L.diagram.y + floor(L.diagram.h / 2)
    local avail = math.min(floor(L.diagram.h / 2), floor(W / 2) - m)
    local edge = Layout.LARGE / 2 + Layout.HALO_PAD
    local s = u
    while s > 1 and avail - edge * s < MIN_RING_RADIUS * s do s = s - 1 end
    L.bead_scale = s
    L.ring = { cx = cx, cy = cy, r = floor(avail - edge * s) }
    -- Decade number ("1º" to "5º") in the middle of the ring, at twice the
    -- bead scale.
    L.ring_label_scale = 2 * s
    local lw, lh = text_w(2, L.ring_label_scale), glyph_h * L.ring_label_scale
    L.ring_label = rect(cx - floor(lw / 2), cy - floor(lh / 2), lw, lh)
    return L
end

--- Bead plus its halo: the area to refresh when a bead changes.
function Layout.bead_region(L, bead)
    local pad = Layout.HALO_PAD * L.bead_scale
    return rect(bead.x - pad, bead.y - pad, bead.w + 2 * pad, bead.h + 2 * pad)
end

--- The 11 beads of a decade, clockwise from the Our Father bead at the bottom.
function Layout.ring_beads(L)
    local s, ring = L.bead_scale, L.ring
    local beads = {}
    for slot = 0, RING_SLOTS - 1 do
        local kind = slot == 0 and "large" or "small"
        local size = (slot == 0 and Layout.LARGE or Layout.SMALL) * s
        local a = math.pi / 2 + slot * 2 * math.pi / RING_SLOTS
        local bx = floor(ring.cx + ring.r * math.cos(a) + 0.5)
        local by = floor(ring.cy + ring.r * math.sin(a) + 0.5)
        beads[#beads + 1] = {
            slot = slot, kind = kind,
            x = bx - floor(size / 2), y = by - floor(size / 2), w = size, h = size,
        }
    end
    return beads
end

--- Dots of the chain along the ring, leaving the bead regions clear.
function Layout.ring_chain(L)
    local s, ring = L.bead_scale, L.ring
    local regions = {}
    for i, bead in ipairs(Layout.ring_beads(L)) do regions[i] = Layout.bead_region(L, bead) end
    local n = floor(2 * math.pi * ring.r / (3 * s))
    local dots = {}
    for i = 0, n - 1 do
        local a = math.pi / 2 + i * 2 * math.pi / n
        local dot = rect(floor(ring.cx + ring.r * math.cos(a) - s / 2 + 0.5),
            floor(ring.cy + ring.r * math.sin(a) - s / 2 + 0.5), s, s)
        local free = true
        for _, r in ipairs(regions) do
            if overlap(dot, r) then free = false break end
        end
        if free then dots[#dots + 1] = dot end
    end
    return dots
end

--- Four sparkle positions inside the ring and the region that contains them.
function Layout.sparkles(L)
    local s, ring = L.bead_scale, L.ring
    local size = Layout.SPARKLE * s
    local k = sparkle_offset(s, ring.r)
    local list = {}
    for _, d in ipairs({ { 1, -1 }, { -1, -1 }, { -1, 1 }, { 1, 1 } }) do
        list[#list + 1] = rect(ring.cx + d[1] * k - floor(size / 2), ring.cy + d[2] * k - floor(size / 2), size, size)
    end
    return list, bounds(list)
end

--- A ripple of `n` x `n` art pixels centered on `bead`, one of `beads`.
-- Returns its top-left corner and its `region` (the part of the diagram it
-- covers, which is the area to refresh), plus a test of whether the art
-- pixel at column `col` and row `row` may be inked: only pixels that lie
-- inside the diagram and clear of the other beads and their halos are.
function Layout.ripple(L, bead, beads, n)
    local s = L.bead_scale
    local size = n * s
    local x, y = bead.x + floor((bead.w - size) / 2), bead.y + floor((bead.h - size) / 2)
    local others = {}
    for _, other in ipairs(beads) do
        if other.slot ~= bead.slot then others[#others + 1] = Layout.bead_region(L, other) end
    end
    local function free(col, row)
        local cell = rect(x + (col - 1) * s, y + (row - 1) * s, s, s)
        if not inside(cell, L.diagram) then return false end
        for _, r in ipairs(others) do
            if overlap(cell, r) then return false end
        end
        return true
    end
    return { x = x, y = y, region = intersect(rect(x, y, size, size), L.diagram) }, free
end

-- The sparkle wave of a Glory Be: sparkle sites next to `beads`, one along
-- each unit vector that `directions(bead)` returns, all at the same
-- distance from the center of their bead (the smallest that clears every
-- bead and its halo). Each site lights up at stage `stage_of(bead)`. Sites
-- that would leave the diagram or cover `avoid` are left out.
local function wave_sites(L, beads, directions, stage_of, avoid)
    local s = L.bead_scale
    local size = Layout.SPARKLE * s
    local regions = {}
    for i, bead in ipairs(beads) do regions[i] = Layout.bead_region(L, bead) end
    local function site_at(bead, dir, d)
        local cx, cy = bead.x + bead.w / 2 + dir[1] * d, bead.y + bead.h / 2 + dir[2] * d
        return rect(floor(cx - size / 2 + 0.5), floor(cy - size / 2 + 0.5), size, size)
    end
    local function clear(r)
        for _, region in ipairs(regions) do
            if overlap(r, region) then return false end
        end
        return true
    end

    local d, far = 0, math.max(L.W, L.H)
    for _, bead in ipairs(beads) do
        for _, dir in ipairs(directions(bead)) do
            while d < far and not clear(site_at(bead, dir, d)) do d = d + s end
        end
    end
    local sites = {}
    for _, bead in ipairs(beads) do
        for _, dir in ipairs(directions(bead)) do
            local r = site_at(bead, dir, d)
            if clear(r) and inside(r, L.diagram) and not (avoid and overlap(r, avoid)) then
                r.slot, r.stage = bead.slot, stage_of(bead)
                sites[#sites + 1] = r
            end
        end
    end
    return sites
end

-- The sites, the number of stages and the region of a sparkle wave.
local function wave(sites)
    local stages = 0
    for _, site in ipairs(sites) do stages = math.max(stages, site.stage) end
    return { sites = sites, stages = stages, region = bounds(sites) }
end

--- The Glory Be sparkle wave of a decade. A sparkle inside the ring next to
-- each bead lights up in turn, rising up both sides from the Our Father bead
-- at the bottom to the top of the ring; the four sparkles around the decade
-- number (the decade completion sparkle) light up last. Returns `sites`
-- (sparkle rectangles with the bead `slot` they belong to and the `stage`
-- at which they light up), the number of `stages` and the `region` that
-- contains every site.
function Layout.ring_wave(L)
    local ring = L.ring
    local sites = wave_sites(L, Layout.ring_beads(L), function(bead)
        local dx, dy = ring.cx - (bead.x + bead.w / 2), ring.cy - (bead.y + bead.h / 2)
        local len = math.sqrt(dx * dx + dy * dy)
        return { { dx / len, dy / len } }
    end, function(bead)
        return math.min(bead.slot, RING_SLOTS - bead.slot) + 1
    end, L.ring_label)
    local last = wave(sites).stages + 1
    for _, r in ipairs((Layout.sparkles(L))) do
        r.stage = last
        sites[#sites + 1] = r
    end
    return wave(sites)
end

--- The Glory Be sparkle wave of the introductory pendant: a sparkle on each
-- side of every bead lights up in turn, climbing from the crucifix to the
-- top Hail Mary bead. Returns the same fields as Layout.ring_wave.
function Layout.pendant_wave(L)
    return wave(wave_sites(L, Layout.pendant(L).beads, function()
        return { { -1, 0 }, { 1, 0 } }
    end, function(bead)
        return bead.slot + 1
    end))
end

--- Top y of each block of a column stacked from the top of `area`, the
-- blocks `gap` apart.
function Layout.stack(area, heights, gap)
    local ys, y = {}, area.y
    for i, h in ipairs(heights) do
        ys[i] = y
        y = y + h + gap
    end
    return ys
end

--- The introductory pendant: crucifix at the bottom, then the Our Father bead
-- and three Hail Mary beads going up, joined by a dotted chain that forks
-- towards the (not shown) decade loop.
function Layout.pendant(L)
    local s, d = L.bead_scale, L.diagram
    local pad = Layout.HALO_PAD * s
    local gap = 6 * s -- leaves a clear band between neighbouring halos for the chain
    local cx = floor(L.W / 2)
    local function centered(slot, kind, w, h, y)
        return { slot = slot, kind = kind, x = cx - floor(w / 2), y = y, w = w, h = h }
    end

    local beads = {}
    local cw, ch = Layout.CROSS_W * s, Layout.CROSS_H * s
    local y = d.y + d.h - pad - ch
    beads[1] = centered(0, "cross", cw, ch, y)
    local lg = Layout.LARGE * s
    y = y - gap - lg
    beads[2] = centered(1, "large", lg, lg, y)
    local sm = Layout.SMALL * s
    for slot = 2, 4 do
        y = y - gap - sm
        beads[#beads + 1] = centered(slot, "small", sm, sm, y)
    end

    local chain = {}
    local function dot(x, yy)
        chain[#chain + 1] = rect(x - floor(s / 2), yy - floor(s / 2), s, s)
    end
    for i = 1, #beads - 1 do
        local lower, upper = beads[i], beads[i + 1]
        dot(cx, floor((upper.y + upper.h + lower.y) / 2))
    end
    local top = beads[#beads].y - pad
    local stem = d.y + floor((top - d.y) / 2)
    for yy = top - 2 * s, stem, -3 * s do dot(cx, yy) end
    for t = 3 * s, stem - d.y - 2 * s, 3 * s do
        dot(cx - t, stem - t)
        dot(cx + t, stem - t)
    end
    return { beads = beads, chain = chain }
end

return Layout
