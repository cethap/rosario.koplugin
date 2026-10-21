--[[--
Pixel-art primitives for the rosario plugin: a 5x9 bitmap font for the
headings, with the accented capitals of Spanish, Portuguese, Italian and
Latin, sprite grids, and bead animation frames (fill and ripple).

Everything draws through an injected `fill_rect(x, y, w, h, color)` callback,
so this module stays pure Lua and can be tested against a fake buffer. In
KOReader the callback wraps `BlitBuffer:paintRect`.

Grids are arrays of equal-length strings: "#" is ink, "+" is a secondary
tone, "." is transparent.
]]

local PixelArt = {}

PixelArt.GLYPH_W = 5
PixelArt.GLYPH_H = 9
PixelArt.SPACING = 1 -- blank columns between glyphs

-- Glyphs: two accent rows on top of a 5x7 capital.
local NO_ACCENT = { ".....", "....." }
local ACUTE = { "...#.", "..#.." }
local GRAVE = { ".#...", "..#.." }
local CIRCUMFLEX = { "..#..", ".#.#." }
local TILDE = { ".##.#", "#..#." }
local DIAERESIS = { ".....", ".#.#." }

local BASE = {
    A = { ".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" },
    B = { "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####." },
    C = { ".###.", "#...#", "#....", "#....", "#....", "#...#", ".###." },
    D = { "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####." },
    E = { "#####", "#....", "#....", "####.", "#....", "#....", "#####" },
    F = { "#####", "#....", "#....", "####.", "#....", "#....", "#...." },
    G = { ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####" },
    H = { "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" },
    I = { ".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###." },
    J = { "..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.." },
    K = { "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" },
    L = { "#....", "#....", "#....", "#....", "#....", "#....", "#####" },
    M = { "#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#" },
    N = { "#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#" },
    O = { ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." },
    P = { "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." },
    Q = { ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#" },
    R = { "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" },
    S = { ".####", "#....", "#....", ".###.", "....#", "....#", "####." },
    T = { "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." },
    U = { "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." },
    V = { "#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.." },
    W = { "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#." },
    X = { "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#" },
    Y = { "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.." },
    Z = { "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####" },
    ["0"] = { ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###." },
    ["1"] = { "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###." },
    ["2"] = { ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####" },
    ["3"] = { "#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###." },
    ["4"] = { "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#." },
    ["5"] = { "#####", "#....", "####.", "....#", "....#", "#...#", ".###." },
    ["6"] = { "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###." },
    ["7"] = { "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..." },
    ["8"] = { ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###." },
    ["9"] = { ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.." },
    ["."] = { ".....", ".....", ".....", ".....", ".....", ".##..", ".##.." },
    [","] = { ".....", ".....", ".....", ".....", ".##..", "..#..", ".#..." },
    [":"] = { ".....", ".##..", ".##..", ".....", ".##..", ".##..", "....." },
    [";"] = { ".....", ".##..", ".##..", ".....", ".##..", "..#..", ".#..." },
    ["!"] = { "..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.." },
    ["?"] = { ".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.." },
    ["¡"] = { "..#..", ".....", "..#..", "..#..", "..#..", "..#..", "..#.." },
    ["¿"] = { "..#..", ".....", "..#..", ".#...", "#....", "#...#", ".###." },
    ["-"] = { ".....", ".....", ".....", ".###.", ".....", ".....", "....." },
    ["/"] = { ".....", "....#", "...#.", "..#..", ".#...", "#....", "....." },
    ["("] = { "...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#." },
    [")"] = { ".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..." },
    ["'"] = { "..#..", "..#..", "..#..", ".....", ".....", ".....", "....." },
    -- The curly apostrophe is the comma raised to cap height.
    ["’"] = { ".##..", "..#..", ".#...", ".....", ".....", ".....", "....." },
    ["º"] = { ".###.", ".#.#.", ".###.", ".....", ".###.", ".....", "....." },
    -- A cedilla has no room below the baseline: the C is one row shorter
    -- and the cedilla takes the bottom row, under the middle of the C.
    ["Ç"] = { ".###.", "#...#", "#....", "#....", "#...#", ".###.", "..##." },
    [" "] = { ".....", ".....", ".....", ".....", ".....", ".....", "....." },
}

local ACCENTED = {
    ["Á"] = { "A", ACUTE },
    ["É"] = { "E", ACUTE },
    ["Í"] = { "I", ACUTE },
    ["Ó"] = { "O", ACUTE },
    ["Ú"] = { "U", ACUTE },
    ["À"] = { "A", GRAVE },
    ["È"] = { "E", GRAVE },
    ["Ì"] = { "I", GRAVE },
    ["Ò"] = { "O", GRAVE },
    ["Ù"] = { "U", GRAVE },
    ["Â"] = { "A", CIRCUMFLEX },
    ["Ê"] = { "E", CIRCUMFLEX },
    ["Ô"] = { "O", CIRCUMFLEX },
    ["Ã"] = { "A", TILDE },
    ["Õ"] = { "O", TILDE },
    ["Ñ"] = { "N", TILDE },
    ["Ü"] = { "U", DIAERESIS },
}

local function compose(accent, base)
    local rows = { accent[1], accent[2] }
    for i = 1, #base do rows[#rows + 1] = base[i] end
    return rows
end

local GLYPHS = {}
for ch, base in pairs(BASE) do GLYPHS[ch] = compose(NO_ACCENT, base) end
for ch, spec in pairs(ACCENTED) do GLYPHS[ch] = compose(spec[2], BASE[spec[1]]) end

--- Glyph rows for one (uppercase) character, or nil when unsupported.
function PixelArt.glyph(ch)
    return GLYPHS[ch]
end

--- Split a UTF-8 string into an array of characters.
function PixelArt.chars(s)
    local out = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = ch
    end
    return out
end

local UPPER = {
    ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú",
    ["à"] = "À", ["è"] = "È", ["ì"] = "Ì", ["ò"] = "Ò", ["ù"] = "Ù",
    ["â"] = "Â", ["ê"] = "Ê", ["ô"] = "Ô",
    ["ã"] = "Ã", ["õ"] = "Õ", ["ñ"] = "Ñ",
    ["ü"] = "Ü", ["ç"] = "Ç",
}

--- Uppercase ASCII letters and the accented lowercase letters the font has.
function PixelArt.upper(s)
    local out = {}
    for _, ch in ipairs(PixelArt.chars(s)) do
        out[#out + 1] = UPPER[ch] or (#ch == 1 and ch:upper()) or ch
    end
    return table.concat(out)
end

function PixelArt.text_width(s, scale)
    local n = #PixelArt.chars(s)
    if n == 0 then return 0 end
    return (n * PixelArt.GLYPH_W + (n - 1) * PixelArt.SPACING) * scale
end

function PixelArt.text_height(scale)
    return PixelArt.GLYPH_H * scale
end

--- Largest integer scale in [1, max_scale] whose text width fits max_width.
function PixelArt.fit_scale(s, max_width, max_scale)
    for scale = max_scale, 1, -1 do
        if PixelArt.text_width(s, scale) <= max_width then return scale end
    end
    return 1
end

--- Draw text (uppercased) with its top-left corner at x, y. Returns the width.
-- Unsupported characters advance like a space. `color` is handed to
-- fill_rect untouched and never compared: a Blitbuffer color is cdata, whose
-- __eq fails against nil (see draw_sprite).
function PixelArt.draw_text(fill_rect, x, y, s, scale, color)
    local chars = PixelArt.chars(PixelArt.upper(s))
    local advance = (PixelArt.GLYPH_W + PixelArt.SPACING) * scale
    for i, ch in ipairs(chars) do
        local glyph = GLYPHS[ch]
        if glyph then
            local gx = x + (i - 1) * advance
            for r, row in ipairs(glyph) do
                local start = 1
                while true do
                    local s1, e1 = row:find("#+", start)
                    if not s1 then break end
                    fill_rect(gx + (s1 - 1) * scale, y + (r - 1) * scale,
                        (e1 - s1 + 1) * scale, scale, color)
                    start = e1 + 1
                end
            end
        end
    end
    return PixelArt.text_width(s, scale)
end

-- Sprites ----------------------------------------------------------------------

PixelArt.sprites = {
    small_bead = {
        "...###...",
        ".#######.",
        ".#######.",
        "#########",
        "#########",
        "#########",
        ".#######.",
        ".#######.",
        "...###...",
    },
    large_bead = {
        "....#####....",
        "..#########..",
        ".###########.",
        ".###########.",
        "#############",
        "#############",
        "#############",
        "#############",
        "#############",
        ".###########.",
        ".###########.",
        "..#########..",
        "....#####....",
    },
    crucifix = {
        "....###....",
        "....#+#....",
        "....#+#....",
        "#####+#####",
        "#+++++++++#",
        "#####+#####",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....#+#....",
        "....###....",
    },
    sparkle = {
        {
            "...#...",
            "...#...",
            "..#.#..",
            "##...##",
            "..#.#..",
            "...#...",
            "...#...",
        },
        {
            "#.....#",
            ".#...#.",
            ".......",
            "...#...",
            ".......",
            ".#...#.",
            "#.....#",
        },
    },
    close = {
        "##...##",
        "###.###",
        ".#####.",
        "..###..",
        ".#####.",
        "###.###",
        "##...##",
    },
    -- Three bars, the size of the close X.
    menu = {
        "#######",
        ".......",
        ".......",
        "#######",
        ".......",
        ".......",
        "#######",
    },
}

function PixelArt.sprite_size(grid)
    return #grid[1], #grid
end

--- Draw a grid with its top-left corner at x, y. `palette` maps grid
-- characters to colors; characters without a color are transparent.
-- Consecutive pixels of the same color are merged into one rectangle.
function PixelArt.draw_sprite(fill_rect, x, y, grid, scale, palette)
    for r, row in ipairs(grid) do
        local i, n = 1, #row
        while i <= n do
            local ch = row:sub(i, i)
            local j = i
            while j < n and row:sub(j + 1, j + 1) == ch do j = j + 1 end
            local color = palette[ch]
            -- Truthiness, not `~= nil`: comparing a cdata color with nil would
            -- run Blitbuffer's __eq, which indexes the nil operand.
            if color then
                fill_rect(x + (i - 1) * scale, y + (r - 1) * scale, (j - i + 1) * scale, scale, color)
            end
            i = j + 1
        end
    end
end

-- Bead frames --------------------------------------------------------------------

local function inked(grid, x, y)
    local row = grid[y]
    return row ~= nil and x >= 1 and x <= #row and row:sub(x, x) ~= "."
end

local function map_grid(grid, fn)
    local out = {}
    for y, row in ipairs(grid) do
        local cells = {}
        for x = 1, #row do
            cells[x] = fn(x, y) and "#" or "."
        end
        out[y] = table.concat(cells)
    end
    return out
end

local function is_border(grid, x, y)
    return not (inked(grid, x - 1, y) and inked(grid, x + 1, y)
        and inked(grid, x, y - 1) and inked(grid, x, y + 1))
end

--- Border pixels of a mask (pixels with an empty 4-neighbour).
function PixelArt.outline(mask)
    return map_grid(mask, function(x, y)
        return inked(mask, x, y) and is_border(mask, x, y)
    end)
end

--- Border plus a 50% checkerboard of the interior.
function PixelArt.dither(mask)
    return map_grid(mask, function(x, y)
        if not inked(mask, x, y) then return false end
        return is_border(mask, x, y) or (x + y) % 2 == 0
    end)
end

--- The three fill frames of a bead: outline, 50% dither, solid.
function PixelArt.bead_frames(mask)
    local solid = {}
    for i, row in ipairs(mask) do solid[i] = row end
    return { PixelArt.outline(mask), PixelArt.dither(mask), solid }
end

--- A ring `width` pixels wide around a mask, separated from it by `gap`
-- empty pixels: the pixels whose distance to the nearest mask pixel is more
-- than gap + 0.5 and at most gap + width + 0.5. The result is larger than
-- the mask by `pad` pixels on every side.
function PixelArt.ring(mask, gap, width, pad)
    local w, h = PixelArt.sprite_size(mask)
    local inked_points = {}
    for y = 1, h do
        for x = 1, w do
            if inked(mask, x, y) then inked_points[#inked_points + 1] = { x + pad, y + pad } end
        end
    end
    local inner, outer = (gap + 0.5) ^ 2, (gap + width + 0.5) ^ 2
    local out = {}
    for y = 1, h + 2 * pad do
        local cells = {}
        for x = 1, w + 2 * pad do
            local best = math.huge
            for _, p in ipairs(inked_points) do
                local dx, dy = x - p[1], y - p[2]
                local d2 = dx * dx + dy * dy
                if d2 < best then best = d2 end
            end
            cells[x] = (best > inner and best <= outer) and "#" or "."
        end
        out[y] = table.concat(cells)
    end
    return out
end

--- A one-pixel ring around a mask, separated from it by `gap` empty pixels.
-- The result is larger than the mask by gap + 1 pixels on every side.
function PixelArt.halo(mask, gap)
    return PixelArt.ring(mask, gap, 1, gap + 1)
end

--- Keep one inked pixel out of `n` (1, 2 or 4) in an ordered dither
-- pattern: a checkerboard for 2, every other pixel of every other row for 4.
function PixelArt.thin(grid, n)
    return map_grid(grid, function(x, y)
        if not inked(grid, x, y) then return false end
        if n == 2 then return (x + y) % 2 == 0 end
        if n == 4 then return x % 2 == 0 and y % 2 == 0 end
        return true
    end)
end

--- Keep the inked pixels of a grid for which `keep(x, y)` holds.
function PixelArt.clip(grid, keep)
    return map_grid(grid, function(x, y)
        return inked(grid, x, y) and keep(x, y)
    end)
end

-- Bead ripple ----------------------------------------------------------------

-- The rings of the ripple that spreads from a bead, from the first one out:
-- each starts `gap` pixels past the bead, is `width` pixels wide and keeps
-- one pixel in `keep`. The first ring sits just past the halo slot (one
-- pixel past the bead) and is solid; the wider ones further out are
-- dithered more and more, so the ripple fades as it grows.
PixelArt.RIPPLE = {
    { gap = 2, width = 1, keep = 1 },
    { gap = 5, width = 2, keep = 2 },
    { gap = 8, width = 2, keep = 4 },
}

--- The ripple frames of a bead: one ring per entry of PixelArt.RIPPLE, all
-- on one square grid centered on the mask, so every frame is drawn at the
-- same place. The grid is larger than the mask by the reach of the last
-- ring on every side.
function PixelArt.ripple_frames(mask)
    local last = PixelArt.RIPPLE[#PixelArt.RIPPLE]
    local pad = last.gap + last.width
    local frames = {}
    for i, ring in ipairs(PixelArt.RIPPLE) do
        frames[i] = PixelArt.thin(PixelArt.ring(mask, ring.gap, ring.width, pad), ring.keep)
    end
    return frames
end

return PixelArt
