local PixelArt = require("pixelart")

-- Fake framebuffer recording every pixel and every fill_rect call.
local function fake_canvas()
    local canvas = { pixels = {}, calls = 0 }
    function canvas.fill_rect(x, y, w, h, color)
        canvas.calls = canvas.calls + 1
        for yy = y, y + h - 1 do
            for xx = x, x + w - 1 do
                canvas.pixels[yy .. "," .. xx] = color
            end
        end
    end
    function canvas.at(x, y)
        return canvas.pixels[y .. "," .. x]
    end
    function canvas.count()
        local n = 0
        for _ in pairs(canvas.pixels) do n = n + 1 end
        return n
    end
    return canvas
end

local function count_set(grid, ch)
    ch = ch or "#"
    local n = 0
    for _, row in ipairs(grid) do
        for i = 1, #row do
            if row:sub(i, i) == ch then n = n + 1 end
        end
    end
    return n
end

local function is_set(grid, x, y)
    local row = grid[y]
    return row ~= nil and row:sub(x, x) == "#"
end

-- Every capital the headings of the five languages use (es, en, pt, la, it).
local REQUIRED = "ABCDEFGHIJKLMNOPQRSTUVWXYZÁÉÍÓÚÑÜÀÈÌÒÙÂÊÔÃÕÇ0123456789.,:;!?¡¿-/()º'’ "

-- Accented capital -> the capital it is built on.
local ACCENT_BASES = {
    ["Á"] = "A", ["À"] = "A", ["Â"] = "A", ["Ã"] = "A",
    ["É"] = "E", ["È"] = "E", ["Ê"] = "E",
    ["Í"] = "I", ["Ì"] = "I",
    ["Ó"] = "O", ["Ò"] = "O", ["Ô"] = "O", ["Õ"] = "O",
    ["Ú"] = "U", ["Ù"] = "U", ["Ü"] = "U",
    ["Ñ"] = "N",
}

describe("pixel font", function()
    it("covers the required characters with 5x9 glyphs", function()
        assert_eq(PixelArt.GLYPH_W, 5)
        assert_eq(PixelArt.GLYPH_H, 9)
        for _, ch in ipairs(PixelArt.chars(REQUIRED)) do
            local g = PixelArt.glyph(ch)
            assert_true(g, "glyph for " .. ch)
            assert_eq(#g, 9, ch .. " rows")
            for r, row in ipairs(g) do
                assert_eq(#row, 5, ch .. " row " .. r .. " width")
                assert_true(row:match("^[#.]+$"), ch .. " row " .. r .. " characters")
            end
        end
    end)

    it("keeps the two top rows for accents", function()
        local a, a_acute = PixelArt.glyph("A"), PixelArt.glyph("Á")
        assert_eq(a[1], ".....")
        assert_eq(a[2], ".....")
        for r = 3, 9 do assert_eq(a_acute[r], a[r], "row " .. r) end
        assert_true(a_acute[1] ~= "....." or a_acute[2] ~= ".....", "accent is drawn")
        local n, n_tilde = PixelArt.glyph("N"), PixelArt.glyph("Ñ")
        for r = 3, 9 do assert_eq(n_tilde[r], n[r], "Ñ row " .. r) end
    end)

    it("composes every accented capital from its base letter and an accent on top", function()
        for accented, base in pairs(ACCENT_BASES) do
            local g, b = PixelArt.glyph(accented), PixelArt.glyph(base)
            for r = 3, 9 do assert_eq(g[r], b[r], accented .. " row " .. r) end
            assert_true(g[1] ~= "....." or g[2] ~= ".....", accented .. ": the accent is drawn")
        end
    end)

    it("tells the acute, grave, circumflex and tilde apart", function()
        local seen = {}
        for _, ch in ipairs({ "Á", "À", "Â", "Ã" }) do
            local g = PixelArt.glyph(ch)
            local accent = g[1] .. g[2]
            assert_eq(seen[accent], nil, ch .. " has its own accent")
            seen[accent] = ch
        end
        assert_eq(PixelArt.glyph("Ò")[1] .. PixelArt.glyph("Ò")[2], PixelArt.glyph("À")[1] .. PixelArt.glyph("À")[2])
    end)

    it("draws Ç as a C with a cedilla below it, inside the 9-row cell", function()
        local c, cc = PixelArt.glyph("C"), PixelArt.glyph("Ç")
        assert_eq(#cc, 9)
        assert_eq(cc[1], ".....", "no accent")
        assert_eq(cc[2], ".....", "no accent")
        assert_eq(cc[3], c[3], "the C starts at cap height")
        assert_true(cc[9]:find("#", 1, true), "the cedilla sits on the bottom row")
        assert_true(cc[9] ~= c[9], "the cedilla is not the bottom of the C")
        local left, right = cc[9]:find("#+")
        assert_true(left >= 2 and right <= 4, "the cedilla hangs under the middle of the C")
        assert_true(cc[8]:sub(left, left) == "#", "the cedilla touches the C")
    end)

    it("draws straight and curly apostrophes high in the cell", function()
        for _, ch in ipairs({ "'", "’" }) do
            local g = PixelArt.glyph(ch)
            assert_true(g[3]:find("#", 1, true), ch .. " starts at cap height")
            for r = 7, 9 do assert_eq(g[r], ".....", ch .. " row " .. r) end
        end
        assert_true(PixelArt.glyph("'")[3] ~= PixelArt.glyph("’")[3] or PixelArt.glyph("'")[5] ~= PixelArt.glyph("’")[5],
            "the curly apostrophe has its own shape")
    end)

    it("splits UTF-8 strings into characters", function()
        assert_eq(PixelArt.chars("¿Ñu?"), { "¿", "Ñ", "u", "?" })
        assert_eq(PixelArt.chars(""), {})
    end)

    it("uppercases Spanish text", function()
        assert_eq(PixelArt.upper("Señal de la cruz"), "SEÑAL DE LA CRUZ")
        assert_eq(PixelArt.upper("áéíóúüñ"), "ÁÉÍÓÚÜÑ")
        assert_eq(PixelArt.upper("Ave María 3/10"), "AVE MARÍA 3/10")
        assert_eq(PixelArt.upper("2º"), "2º", "the ordinal indicator stays")
    end)

    it("uppercases Portuguese, Italian and Latin text", function()
        assert_eq(PixelArt.upper("àèìòù âêô ãõ ç"), "ÀÈÌÒÙ ÂÊÔ ÃÕ Ç")
        assert_eq(PixelArt.upper("O Gesù mio"), "O GESÙ MIO")
        assert_eq(PixelArt.upper("Mistérios, coração"), "MISTÉRIOS, CORAÇÃO")
        assert_eq(PixelArt.upper("Our Lady’s l'ave"), "OUR LADY’S L'AVE", "apostrophes stay")
    end)

    it("measures text in screen pixels", function()
        assert_eq(PixelArt.text_width("", 3), 0)
        assert_eq(PixelArt.text_width("A", 3), 15)
        assert_eq(PixelArt.text_width("AB", 2), 5 * 2 + 1 * 2 + 5 * 2)
        assert_eq(PixelArt.text_width("ña", 1), PixelArt.text_width("NA", 1), "lowercase is uppercased")
        assert_eq(PixelArt.text_height(4), 36)
    end)

    it("picks the largest scale that fits a width", function()
        local scale = PixelArt.fit_scale("SANTO ROSARIO", 400, 10)
        assert_true(PixelArt.text_width("SANTO ROSARIO", scale) <= 400)
        assert_true(PixelArt.text_width("SANTO ROSARIO", scale + 1) > 400)
        assert_eq(PixelArt.fit_scale("A", 1000, 4), 4, "capped by the maximum")
        assert_eq(PixelArt.fit_scale("A VERY LONG TEXT", 1, 4), 1, "never below 1")
    end)

    it("draws glyph pixels through fill_rect at integer scale", function()
        local c = fake_canvas()
        local width = PixelArt.draw_text(c.fill_rect, 10, 20, "I", 2, "ink")
        assert_eq(width, 10)
        local g = PixelArt.glyph("I")
        for gy = 1, 9 do
            for gx = 1, 5 do
                local expected = is_set(g, gx, gy) and "ink" or nil
                for dy = 0, 1 do
                    for dx = 0, 1 do
                        local px, py = 10 + (gx - 1) * 2 + dx, 20 + (gy - 1) * 2 + dy
                        assert_eq(c.at(px, py), expected, ("pixel %d,%d"):format(px, py))
                    end
                end
            end
        end
        assert_eq(c.count(), count_set(g) * 4)
    end)

    it("merges horizontal runs into single rectangles", function()
        local c = fake_canvas()
        PixelArt.draw_text(c.fill_rect, 0, 0, "-", 3, 1)
        local runs = 0
        for _, row in ipairs(PixelArt.glyph("-")) do
            for _ in row:gmatch("#+") do runs = runs + 1 end
        end
        assert_eq(c.calls, runs)
    end)

    it("advances by glyph width plus spacing", function()
        local c = fake_canvas()
        PixelArt.draw_text(c.fill_rect, 0, 0, "II", 1, 1)
        local g = PixelArt.glyph("I")
        for gy = 1, 9 do
            for gx = 1, 5 do
                assert_eq(c.at(6 + gx - 1, gy - 1) ~= nil, is_set(g, gx, gy), "second glyph")
            end
        end
    end)

    it("draws text with an FFI color whose __eq cannot compare against nil", function()
        -- KOReader's Blitbuffer colors are cdata (see the sprite spec below).
        local ffi = require("ffi")
        local Color = ffi.metatype("struct { uint8_t a; }", {
            __eq = function(p, q) return p.a == q.a end,
        })
        local black = Color(0)
        local c = fake_canvas()
        PixelArt.draw_text(c.fill_rect, 0, 0, "I", 1, black)
        assert_eq(c.at(2, 2), black)
        assert_eq(c.count(), count_set(PixelArt.glyph("I")))
    end)
end)

describe("sprites", function()
    it("are rectangular string grids", function()
        local sprites = {
            PixelArt.sprites.small_bead, PixelArt.sprites.large_bead,
            PixelArt.sprites.crucifix, PixelArt.sprites.close, PixelArt.sprites.menu,
            PixelArt.sprites.sparkle[1], PixelArt.sprites.sparkle[2],
        }
        for i, grid in ipairs(sprites) do
            local w = #grid[1]
            for _, row in ipairs(grid) do
                assert_eq(#row, w, "sprite " .. i)
                assert_true(row:match("^[#+.]+$"), "sprite " .. i .. " characters")
            end
        end
    end)

    it("have the documented sizes", function()
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.small_bead) }, { 9, 9 })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.large_bead) }, { 13, 13 })
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.crucifix) }, { 11, 17 })
        assert_eq(#PixelArt.sprites.sparkle, 2)
        assert_eq({ PixelArt.sprite_size(PixelArt.sprites.sparkle[1]) },
            { PixelArt.sprite_size(PixelArt.sprites.sparkle[2]) })
    end)

    it("draw the menu button as three bars the size of the close X", function()
        local menu = PixelArt.sprites.menu
        assert_true(menu ~= nil, "a menu sprite")
        assert_eq({ PixelArt.sprite_size(menu) }, { PixelArt.sprite_size(PixelArt.sprites.close) })
        local bars = {}
        for y, row in ipairs(menu) do
            assert_true(row:match("^#+$") or row:match("^%.+$"), "row " .. y .. " is a whole bar or empty")
            if row:match("^#+$") then bars[#bars + 1] = y end
        end
        assert_eq(#bars, 3, "three bars")
        assert_eq({ bars[1], bars[3] }, { 1, #menu }, "the bars span the height of the close X")
        assert_eq(bars[2] - bars[1], bars[3] - bars[2], "evenly spaced")
        assert_true(bars[2] - bars[1] > 1, "bars are apart")
    end)

    it("draw with a palette and skip transparent pixels", function()
        local c = fake_canvas()
        local grid = { "#+.", ".#+" }
        PixelArt.draw_sprite(c.fill_rect, 5, 7, grid, 2, { ["#"] = "black", ["+"] = "gray" })
        assert_eq(c.at(5, 7), "black")
        assert_eq(c.at(6, 8), "black")
        assert_eq(c.at(7, 7), "gray")
        assert_eq(c.at(9, 7), nil, "transparent")
        assert_eq(c.at(7, 9), "black")
        assert_eq(c.at(9, 9), "gray")
        assert_eq(c.count(), 4 * 4)
    end)

    it("draw with FFI colors whose __eq cannot compare against nil", function()
        -- KOReader's Blitbuffer colors are cdata; LuaJIT calls their __eq even
        -- when the other operand is nil, and Blitbuffer's __eq indexes it.
        local ffi = require("ffi")
        local Color = ffi.metatype("struct { uint8_t a; }", {
            __eq = function(p, q) return p.a == q.a end,
        })
        local black = Color(0)
        local c = fake_canvas()
        PixelArt.draw_sprite(c.fill_rect, 0, 0, { "#." }, 1, { ["#"] = black })
        assert_eq(c.at(0, 0), black)
        assert_eq(c.count(), 1)
    end)
end)

describe("bead fill frames", function()
    local mask = PixelArt.sprites.small_bead

    it("outline keeps only the border of the mask", function()
        local ring = PixelArt.outline({ "###", "###", "###" })
        assert_eq(ring, { "###", "#.#", "###" })
    end)

    it("dither keeps the border and half of the interior", function()
        local d = PixelArt.dither({ "#####", "#####", "#####", "#####", "#####" })
        assert_eq(d, { "#####", "##.##", "#.#.#", "##.##", "#####" })
    end)

    it("go from outline to 50% dither to solid", function()
        local frames = PixelArt.bead_frames(mask)
        assert_eq(#frames, 3)
        assert_eq(frames[3], mask)
        local a, b, c = count_set(frames[1]), count_set(frames[2]), count_set(frames[3])
        assert_true(a < b and b < c, "each frame adds ink")
        for y, row in ipairs(frames[1]) do
            for x = 1, #row do
                if is_set(frames[1], x, y) then
                    assert_true(is_set(frames[2], x, y), "outline is part of the dither frame")
                end
            end
        end
    end)

    it("builds a halo ring around a sprite", function()
        local halo = PixelArt.halo({ "#" }, 1)
        assert_eq(halo, { ".###.", "#...#", "#...#", "#...#", ".###." })
        local w, h = PixelArt.sprite_size(PixelArt.halo(mask, 1))
        assert_eq({ w, h }, { 9 + 4, 9 + 4 })
    end)
end)

describe("bead ripple frames", function()
    local function inked_cells(grid)
        local out = {}
        for y, row in ipairs(grid) do
            for x = 1, #row do
                if row:sub(x, x) == "#" then out[#out + 1] = { x, y } end
            end
        end
        return out
    end

    -- Nearest and farthest inked cell of a square grid from its center cell.
    local function reach(grid)
        local c = (#grid + 1) / 2
        local near, far = math.huge, 0
        for _, p in ipairs(inked_cells(grid)) do
            local d = math.sqrt((p[1] - c) ^ 2 + (p[2] - c) ^ 2)
            near, far = math.min(near, d), math.max(far, d)
        end
        return near, far
    end

    -- Distance from cell x, y of a grid padded by `pad` to the nearest mask pixel.
    local function to_mask(mask, pad, x, y)
        local best = math.huge
        for _, p in ipairs(inked_cells(mask)) do
            best = math.min(best, math.sqrt((x - pad - p[1]) ^ 2 + (y - pad - p[2]) ^ 2))
        end
        return best
    end

    it("draws a ring at a distance from a mask", function()
        assert_eq(PixelArt.ring({ "#" }, 0, 1, 1), { "###", "#.#", "###" })
        assert_eq(PixelArt.ring({ "#" }, 1, 1, 2), PixelArt.halo({ "#" }, 1), "the halo is a one-pixel ring")
        local wide = PixelArt.ring({ "#" }, 1, 2, 4)
        assert_eq(#wide, 9, "padded on every side")
        assert_eq(wide[1], ".........", "padding past the ring stays empty")
        assert_eq(wide[5], ".##...##.", "two pixels wide")
    end)

    it("thins a grid with an ordered dither", function()
        local full = { "####", "####" }
        assert_eq(PixelArt.thin(full, 1), full)
        assert_eq(PixelArt.thin(full, 2), { "#.#.", ".#.#" })
        assert_eq(PixelArt.thin(full, 4), { "....", ".#.#" })
        assert_eq(PixelArt.thin({ "#..#" }, 2), { "#..." }, "empty pixels stay empty")
    end)

    it("clips a grid to the pixels a test keeps", function()
        local clipped = PixelArt.clip({ "###", "#.#" }, function(x, y) return x ~= 2 and y == 1 end)
        assert_eq(clipped, { "#.#", "..." })
    end)

    for _, kind in ipairs({ "small_bead", "large_bead" }) do
        local mask = PixelArt.sprites[kind]

        it("grows rings out from a " .. kind .. " and fades them", function()
            local frames = PixelArt.ripple_frames(mask)
            assert_eq(#frames, #PixelArt.RIPPLE)
            assert_true(#frames >= 2 and #frames <= 3, "two or three ripple frames")
            local n = #frames[1]
            local pad = (n - #mask) / 2
            assert_true(pad >= 1 and pad % 1 == 0, "the grid is centered on the bead")
            local last_near, last_far, last_share = 0, 0, math.huge
            for i, grid in ipairs(frames) do
                local where = kind .. " ring " .. i
                assert_eq({ PixelArt.sprite_size(grid) }, { n, n }, where .. " shares the grid")
                local near, far = reach(grid)
                assert_true(near > last_near and far > last_far, where .. " grows outwards")
                last_near, last_far = near, far
                for _, p in ipairs(inked_cells(grid)) do
                    assert_true(to_mask(mask, pad, p[1], p[2]) > 2.5, where .. " stays clear of the bead and its halo")
                end
                -- The ring is part of the full ring at its distance, with less
                -- of it kept on every frame.
                local spec = PixelArt.RIPPLE[i]
                local full = PixelArt.ring(mask, spec.gap, spec.width, pad)
                assert_eq(PixelArt.clip(grid, function(x, y) return full[y]:sub(x, x) == "#" end), grid, where)
                local share = #inked_cells(grid) / #inked_cells(full)
                assert_true(share < last_share, where .. " fades")
                last_share = share
                if i == 1 then assert_eq(grid, full, "the first ring is solid") end
            end
            assert_true(last_share < 1, "the last ring is dithered")
        end)
    end
end)
