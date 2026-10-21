local Layout = require("layout")
local PixelArt = require("pixelart")

local SCREENS = {
    { 1072, 1448 }, -- Kindle Basic 2024
    { 600, 800 },
    { 758, 1024 },
    { 1448, 1072 }, -- landscape
}

local function inside(inner, outer)
    return inner.x >= outer.x and inner.y >= outer.y
        and inner.x + inner.w <= outer.x + outer.w
        and inner.y + inner.h <= outer.y + outer.h
end

local function overlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function each_pair(list, fn)
    for i = 1, #list do
        for j = i + 1, #list do fn(list[i], list[j], i, j) end
    end
end

local function grow(r, d)
    return { x = r.x - d, y = r.y - d, w = r.w + 2 * d, h = r.h + 2 * d }
end

-- Grid size of the ripple frames of each bead kind.
local function ripple_sizes()
    return {
        small = #PixelArt.ripple_frames(PixelArt.sprites.small_bead)[1],
        large = #PixelArt.ripple_frames(PixelArt.sprites.large_bead)[1],
    }
end

describe("Layout", function()
    it("stacks a column of blocks from the top of its area", function()
        local area = { x = 0, y = 100, w = 200, h = 400 }
        assert_eq(Layout.stack(area, { 50, 30 }, 10), { 100, 160 })
        assert_eq(Layout.stack(area, { 50, 20, 30 }, 10), { 100, 160, 190 })
        assert_eq(Layout.stack(area, {}, 10), {})
        -- A column taller than its area still starts at the top.
        assert_eq(Layout.stack(area, { 300, 150 }, 10), { 100, 410 })
    end)

    it("leaves a gap of about one heading line above the content on the Kindle", function()
        local L = Layout.compute(1072, 1448)
        assert_eq(L.content_gap, 6 * L.unit, "in layout units")
        assert_true(L.content_gap >= 24 and L.content_gap <= 32, "24-32 px, got " .. tostring(L.content_gap))
    end)

    it("uses the sprite and glyph sizes of pixelart", function()
        assert_eq({ Layout.GLYPH_W, Layout.GLYPH_H, Layout.SPACING }, { 5, 9, 1 }, "5x9 glyphs, 1 pixel apart")
        assert_eq({ Layout.GLYPH_W, Layout.GLYPH_H, Layout.SPACING },
            { PixelArt.GLYPH_W, PixelArt.GLYPH_H, PixelArt.SPACING }, "bitmap font glyphs")
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.small_bead) }, { Layout.SMALL, Layout.SMALL })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.large_bead) }, { Layout.LARGE, Layout.LARGE })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.crucifix) }, { Layout.CROSS_W, Layout.CROSS_H })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.sparkle[1]) }, { Layout.SPARKLE, Layout.SPARKLE })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.close) }, { Layout.CLOSE, Layout.CLOSE })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.menu or { "" }) }, { Layout.CLOSE, Layout.CLOSE })
        assert_eq({ PixelArt.sprite_size(PixelArt.halo(PixelArt.sprites.small_bead, Layout.HALO_GAP)) },
            { Layout.SMALL + 2 * Layout.HALO_PAD, Layout.SMALL + 2 * Layout.HALO_PAD })
    end)

    for _, size in ipairs(SCREENS) do
        local W, H = size[1], size[2]
        local L = Layout.compute(W, H)
        local screen = { x = 0, y = 0, w = W, h = H }
        local name = W .. "x" .. H

        it("stacks the regions without overlap on " .. name, function()
            assert_true(L.unit >= 2, "unit")
            assert_true(inside(L.close, screen), "close button")
            local rows = { title = "title", set = "set", label = "label", card_label = "label" }
            for row, scale in pairs(rows) do
                assert_true(L[row] ~= nil and inside(L[row], screen), row .. " row on screen")
                assert_eq(L[row].h, PixelArt.text_height(L[scale .. "_scale"]), row .. " row holds one line of glyphs")
            end
            assert_false(overlap(L.title, L.close), "title clear of the close button")
            assert_true(L.set.y >= L.title.y + L.title.h, "set below title")
            assert_true(L.set.y + L.set.h <= L.header_bottom, "header")
            assert_true(L.diagram.y >= L.header_bottom, "diagram below header")
            assert_true(inside(L.diagram, screen), "diagram on screen")
            assert_true(L.label.y >= L.diagram.y + L.diagram.h, "label below diagram")
            assert_true(L.text.y >= L.label.y + L.label.h, "text below label")
            assert_true(L.content_gap > 0, "content gap")
            assert_eq(L.card_label.y, L.header_bottom + L.content_gap, "the card heading starts a gap below the header line")
            assert_eq(L.card.y, L.card_label.y + L.card_label.h + L.content_gap, "card text starts a gap below its heading")
            assert_eq(L.text.y, L.label.y + L.label.h + L.content_gap, "text starts a gap below the label")
            assert_true(L.text.h > 0 and L.card.h > L.text.h, "text areas")
            assert_true(L.text.y + L.text.h <= L.pips_region.y, "text above pips")
            assert_true(L.card.y + L.card.h <= L.pips_region.y, "card above pips")
            assert_true(inside(L.pips_region, screen), "pips on screen")
            assert_eq(#L.pips, 5)
        end)

        it("mirrors the close button with the menu button on " .. name, function()
            assert_true(L.menu ~= nil and L.menu_hit ~= nil, "menu button")
            -- Same size, same top, mirrored across the screen's vertical axis.
            assert_eq({ L.menu.y, L.menu.w, L.menu.h }, { L.close.y, L.close.w, L.close.h }, "menu button")
            assert_eq(L.menu.x, W - L.close.x - L.close.w, "menu button mirrors the close X")
            assert_eq({ L.menu_hit.y, L.menu_hit.w, L.menu_hit.h }, { L.close_hit.y, L.close_hit.w, L.close_hit.h },
                "menu tap zone")
            assert_eq(L.menu_hit.x, W - L.close_hit.x - L.close_hit.w, "menu tap zone mirrors the close zone")
            assert_true(inside(L.menu, L.menu_hit), "menu button inside its tap zone")
            assert_true(inside(L.menu_hit, screen), "menu tap zone on screen")
            assert_false(overlap(L.menu_hit, L.close_hit), "tap zones apart")
            assert_false(overlap(L.title, L.menu), "title clear of the menu button")
            assert_false(overlap(L.set, L.menu_hit), "mystery set clear of the menu tap zone")
        end)

        it("sizes the pixel headings with the integer scales they had before T7 on " .. name, function()
            local u = L.unit
            assert_eq(L.title_scale, u, "title")
            assert_eq(L.set_scale, math.max(2, u - 2), "mystery set")
            assert_eq(L.label_scale, math.max(2, u - 1), "step label and card heading")
            assert_eq(L.ring_label_scale, 2 * L.bead_scale, "decade number")
            assert_eq(L.set.y, L.title.y + L.title.h + 2 * u, "set a little below the title")
            assert_eq(L.header_bottom, L.set.y + L.set.h + 2 * u, "header line a little below the set")
            -- The decade number ("1º" to "5º") fills its box in the middle of the ring.
            assert_eq({ L.ring_label.w, L.ring_label.h },
                { PixelArt.text_width("5º", L.ring_label_scale), PixelArt.text_height(L.ring_label_scale) })
            assert_eq(2 * L.ring_label.x + L.ring_label.w, 2 * L.ring.cx, "decade number centered across")
            assert_eq(2 * L.ring_label.y + L.ring_label.h, 2 * L.ring.cy, "decade number centered down")
            -- On the Kindle Basic 2024 the headings keep their pre-T7 sizes in pixels.
            if W == 1072 and H == 1448 then
                assert_eq({ L.title.h, L.set.h, L.label.h, L.ring_label.h }, { 45, 27, 36, 90 }, "glyph heights in px")
            end
        end)

        it("fits the decade ring inside the diagram on " .. name, function()
            local beads = Layout.ring_beads(L)
            assert_eq(#beads, 11)
            assert_eq(beads[1].slot, 0)
            assert_eq(beads[1].kind, "large")
            for i = 2, 11 do assert_eq(beads[i].kind, "small") end
            local regions = {}
            for i, bead in ipairs(beads) do
                regions[i] = Layout.bead_region(L, bead)
                assert_true(inside(regions[i], L.diagram), "bead " .. bead.slot .. " inside the diagram")
            end
            each_pair(regions, function(a, b, i, j)
                assert_false(overlap(a, b), ("beads %d and %d overlap"):format(i - 1, j - 1))
            end)
            assert_true(beads[2].x < beads[1].x and beads[2].y < beads[1].y,
                "first Hail Mary is clockwise from the bottom")
        end)

        it("keeps the chain and sparkles clear of the beads on " .. name, function()
            local beads = Layout.ring_beads(L)
            local regions = {}
            for i, bead in ipairs(beads) do regions[i] = Layout.bead_region(L, bead) end
            local dots = Layout.ring_chain(L)
            assert_true(#dots > 11, "some chain dots")
            for _, dot in ipairs(dots) do
                for _, r in ipairs(regions) do
                    assert_false(overlap(dot, r), "chain dot under a bead")
                end
                -- A text box paints its white background over what lies below.
                assert_false(overlap(dot, L.ring_label), "chain dot under the decade number")
            end
            for _, r in ipairs(regions) do
                assert_false(overlap(r, L.ring_label), "bead under the decade number")
            end
            local sparkles, region = Layout.sparkles(L)
            assert_eq(#sparkles, 4)
            assert_true(inside(region, L.diagram), "sparkle region")
            for _, s in ipairs(sparkles) do
                assert_true(inside(s, region), "sparkle inside its region")
                for _, r in ipairs(regions) do assert_false(overlap(s, r), "sparkle over a bead") end
                assert_false(overlap(s, L.ring_label), "sparkle over the decade number")
            end
        end)

        it("fits the introductory pendant inside the diagram on " .. name, function()
            local pendant = Layout.pendant(L)
            local kinds = {}
            local regions = {}
            for i, bead in ipairs(pendant.beads) do
                kinds[i] = bead.kind
                assert_eq(bead.slot, i - 1)
                regions[i] = Layout.bead_region(L, bead)
                assert_true(inside(regions[i], L.diagram), "pendant bead " .. bead.slot)
            end
            assert_eq(kinds, { "cross", "large", "small", "small", "small" })
            each_pair(regions, function(a, b, i, j)
                assert_false(overlap(a, b), ("pendant beads %d and %d overlap"):format(i - 1, j - 1))
            end)
            for _, dot in ipairs(pendant.chain) do
                assert_true(inside(dot, L.diagram), "pendant chain inside the diagram")
                for _, r in ipairs(regions) do assert_false(overlap(dot, r), "chain dot under a bead") end
            end
        end)

        it("keeps every bead ripple inside the diagram and off the other beads on " .. name, function()
            local s, sizes = L.bead_scale, ripple_sizes()
            for view, beads in pairs({ ring = Layout.ring_beads(L), pendant = Layout.pendant(L).beads }) do
                for _, bead in ipairs(beads) do
                    local n = sizes[bead.kind]
                    if n then
                        local where = view .. " bead " .. bead.slot
                        local ripple, free = Layout.ripple(L, bead, beads, n)
                        assert_eq(2 * ripple.x + n * s, 2 * bead.x + bead.w, where .. ": centered across")
                        assert_eq(2 * ripple.y + n * s, 2 * bead.y + bead.h, where .. ": centered down")
                        assert_true(inside(ripple.region, L.diagram), where .. ": region inside the diagram")
                        assert_true(inside(Layout.bead_region(L, bead), ripple.region), where .. ": region covers the bead")
                        local kept = 0
                        for row = 1, n do
                            for col = 1, n do
                                if free(col, row) then
                                    kept = kept + 1
                                    local cell = { x = ripple.x + (col - 1) * s, y = ripple.y + (row - 1) * s, w = s, h = s }
                                    assert_true(inside(cell, ripple.region), where .. ": pixel inside the region")
                                    for _, other in ipairs(beads) do
                                        if other.slot ~= bead.slot then
                                            assert_false(overlap(cell, Layout.bead_region(L, other)),
                                                where .. ": pixel over bead " .. other.slot)
                                        end
                                    end
                                end
                            end
                        end
                        assert_true(kept > n, where .. ": most of the ripple is drawn")
                    end
                end
            end
        end)

        it("places the Glory Be sparkle waves around the beads on " .. name, function()
            local size = Layout.SPARKLE * L.bead_scale
            local cases = {
                ring = { wave = Layout.ring_wave(L), beads = Layout.ring_beads(L), per_bead = 1 },
                pendant = { wave = Layout.pendant_wave(L), beads = Layout.pendant(L).beads, per_bead = 2 },
            }
            for view, case in pairs(cases) do
                local wave = case.wave
                local regions, by_slot, sites_of = {}, {}, {}
                for i, bead in ipairs(case.beads) do
                    regions[i] = Layout.bead_region(L, bead)
                    by_slot[bead.slot] = regions[i]
                end
                assert_true(inside(wave.region, L.diagram), view .. ": wave region inside the diagram")
                for _, site in ipairs(wave.sites) do
                    local where = view .. " sparkle " .. tostring(site.slot)
                    assert_eq({ site.w, site.h }, { size, size }, where)
                    assert_true(inside(site, wave.region), where .. " inside the wave region")
                    for _, r in ipairs(regions) do assert_false(overlap(site, r), where .. " over a bead") end
                    assert_true(site.stage >= 1 and site.stage <= wave.stages, where .. " stage")
                    if site.slot then
                        sites_of[site.slot] = (sites_of[site.slot] or 0) + 1
                        assert_true(overlap(site, grow(by_slot[site.slot], size)), where .. " next to its bead")
                    end
                end
                for _, bead in ipairs(case.beads) do
                    assert_eq(sites_of[bead.slot], case.per_bead, view .. ": sparkles of bead " .. bead.slot)
                end
                -- Sparkles of neighbouring stages are on screen together.
                each_pair(wave.sites, function(a, b)
                    if math.abs(a.stage - b.stage) <= 1 then
                        assert_false(overlap(a, b), view .. ": sparkles shown together overlap")
                    end
                end)
            end

            -- The ring wave rises up both sides from the Our Father bead and ends
            -- with the decade completion sparkle around the decade number.
            local ring = cases.ring.wave
            local center = {}
            for _, site in ipairs(ring.sites) do
                if site.slot then
                    assert_eq(site.stage, math.min(site.slot, 11 - site.slot) + 1, "ring sparkle " .. site.slot)
                    assert_false(overlap(site, L.ring_label), "ring sparkle over the decade number")
                else
                    assert_eq(site.stage, ring.stages, "the completion sparkle comes last")
                    center[#center + 1] = { x = site.x, y = site.y, w = site.w, h = site.h }
                end
            end
            assert_eq(ring.stages, 7)
            assert_eq(center, (Layout.sparkles(L)), "the decade completion sparkle")

            -- The pendant wave climbs from the crucifix, with one sparkle on each side.
            local pendant = cases.pendant.wave
            assert_eq(pendant.stages, 5)
            local beads = cases.pendant.beads
            local sides = {}
            for _, site in ipairs(pendant.sites) do
                assert_eq(site.stage, site.slot + 1, "pendant sparkle " .. site.slot)
                local bead = beads[site.slot + 1]
                local offset = (site.x + site.w / 2) - (bead.x + bead.w / 2)
                sides[site.slot] = (sides[site.slot] or 0) + offset
            end
            for slot = 0, 4 do
                assert_true(math.abs(sides[slot]) <= 1, "pendant sparkles of bead " .. slot .. " are mirrored")
            end
        end)
    end
end)
