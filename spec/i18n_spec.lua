local I18n = require("i18n")
local PixelArt = require("pixelart")
local Rosary = require("rosary")

local root = (arg and arg[0] and arg[0]:match("^(.*)/spec/run%.lua$")) or "."
local PLUGIN_DIR = root .. "/rosario.koplugin"

-- A settings reader over a plain table, like G_reader_settings:readSetting.
local function reader(data)
    return function(key) return data[key] end
end

local function file_exists(path)
    local fh = io.open(path, "r")
    if fh then fh:close() end
    return fh ~= nil
end

local load = I18n.file_loader(PLUGIN_DIR)

-- Every key path of a nested table, as "a.b.c" -> type of the value.
local function shape(t, prefix, out)
    out = out or {}
    for k, v in pairs(t) do
        local path = (prefix and prefix .. "." or "") .. tostring(k)
        if type(v) == "table" then
            shape(v, path, out)
        else
            out[path] = type(v)
        end
    end
    return out
end

-- The format directives of a string, in order ("%s", "%d"...).
local function directives(s)
    local out = {}
    for d in s:gmatch("%%[%a%%]") do out[#out + 1] = d end
    return table.concat(out, " ")
end

describe("I18n languages", function()
    it("supports Spanish, English, Portuguese, Latin and Italian, named in their own language", function()
        assert_eq(I18n.LANGUAGES, { "es", "en", "pt", "la", "it" })
        assert_eq(I18n.NAMES, { es = "Español", en = "English", pt = "Português", la = "Latina", it = "Italiano" })
        for _, code in ipairs(I18n.LANGUAGES) do assert_true(I18n.is_supported(code), code) end
        for _, code in ipairs({ "fr", "", "ES", "es_ES", 1 }) do
            assert_false(I18n.is_supported(code), tostring(code))
        end
    end)

    it("maps a KOReader locale to a language by its prefix", function()
        local cases = {
            es = "es", pt_BR = "pt", pt_PT = "pt", it_IT = "it", en_GB = "en", en = "en", la = "la",
            ["pt-BR"] = "pt", ["es_ES.UTF-8"] = "es", PT_br = "pt",
        }
        for locale, code in pairs(cases) do
            assert_eq(I18n.from_locale(locale), code, locale)
        end
        for _, locale in ipairs({ "fr", "zh_CN", "C", "", "eng" }) do
            assert_eq(I18n.from_locale(locale), nil, locale)
        end
        assert_eq(I18n.from_locale(nil), nil)
        assert_eq(I18n.from_locale(42), nil)
    end)
end)

describe("I18n.resolve", function()
    it("prefers the plugin's own language setting", function()
        assert_eq(I18n.SETTING, "rosario_language")
        assert_eq(I18n.resolve(reader({ rosario_language = "la", language = "it_IT" })), "la")
        assert_eq(I18n.resolve(reader({ rosario_language = "pt" })), "pt")
    end)

    it("follows KOReader's UI language when the plugin setting is unset or unsupported", function()
        assert_eq(I18n.resolve(reader({ language = "it_IT" })), "it")
        assert_eq(I18n.resolve(reader({ language = "pt_BR" })), "pt")
        assert_eq(I18n.resolve(reader({ language = "es" })), "es")
        assert_eq(I18n.resolve(reader({ rosario_language = "fr", language = "en_GB" })), "en")
        assert_eq(I18n.resolve(reader({ rosario_language = "", language = "es" })), "es")
    end)

    it("falls back to English", function()
        assert_eq(I18n.DEFAULT, "en")
        assert_eq(I18n.resolve(reader({})), "en")
        assert_eq(I18n.resolve(reader({ language = "fr" })), "en")
        assert_eq(I18n.resolve(reader({ rosario_language = "de", language = "zh_CN" })), "en")
    end)
end)

describe("I18n.merge", function()
    it("fills missing keys from the fallback, key by key and at every depth", function()
        local fallback = { a = 1, b = { c = 2, d = 3 }, list = { { x = 1, y = 2 }, { x = 3, y = 4 } } }
        local merged = I18n.merge({ b = { c = 20 }, list = { [2] = { y = 40 } }, e = 5 }, fallback)
        assert_eq(merged, { a = 1, b = { c = 20, d = 3 }, list = { { x = 1, y = 2 }, { x = 3, y = 40 } }, e = 5 })
        assert_eq(fallback.b.c, 2, "the fallback is left untouched")
    end)

    it("keeps a false value from the primary table", function()
        assert_eq(I18n.merge({ verbatim = false }, { verbatim = true }), { verbatim = false })
    end)

    it("uses the fallback alone when the primary table is missing", function()
        assert_eq(I18n.merge(nil, { a = 1 }), { a = 1 })
    end)
end)

describe("I18n.file_loader", function()
    it("loads a module of the plugin folder, and nothing for a missing one", function()
        assert_eq(type(load("l10n", "es")), "table")
        assert_eq(type(load("content", "es")), "table")
        assert_eq(load("content", "xx"), nil)
    end)

    it("warns and loads nothing for a broken module", function()
        local warnings = {}
        local broken = I18n.file_loader(root .. "/spec/fixtures", function(...)
            warnings[#warnings + 1] = table.concat({ ... }, " ")
        end)
        assert_eq(broken("l10n", "syntax"), nil)
        assert_eq(broken("l10n", "number"), nil)
        assert_eq(#warnings, 2)
        assert_true(warnings[1]:find("syntax.lua", 1, true), warnings[1])
    end)
end)

describe("I18n.catalog", function()
    it("gives Spanish its own strings and content", function()
        local c = I18n.catalog("es", load)
        assert_eq(c.lang, "es")
        assert_eq(c.strings, load("l10n", "es"))
        assert_eq(c.content, load("content", "es"))
    end)

    it("falls back to the Spanish content for a language without its own module", function()
        local missing = function(kind, lang)
            if kind == "content" and lang ~= "es" then return nil end
            return load(kind, lang)
        end
        local c = I18n.catalog("it", missing)
        assert_eq(c.content, load("content", "es"))
        assert_eq(c.strings, load("l10n", "it"), "the strings are still Italian")
    end)

    it("falls back to Spanish key by key for a partial content module", function()
        local partial = {
            prayers = { hail_mary = { text = "Ave Maria, gratia plena." } },
            sets = { gozosos = { title = "Mysteria Gaudiosa", mysteries = { [2] = { fruit = "Caritas" } } } },
        }
        local c = I18n.catalog("la", function(kind, lang)
            if kind == "content" and lang == "la" then return partial end
            return load(kind, lang)
        end)
        local es = load("content", "es")
        assert_eq(c.content.prayers.hail_mary.text, "Ave Maria, gratia plena.")
        assert_eq(c.content.prayers.hail_mary.title, es.prayers.hail_mary.title)
        assert_eq(c.content.prayers.creed, es.prayers.creed)
        assert_eq(c.content.sets.gozosos.title, "Mysteria Gaudiosa")
        assert_eq(c.content.sets.gozosos.mysteries[1], es.sets.gozosos.mysteries[1])
        assert_eq(c.content.sets.gozosos.mysteries[2].fruit, "Caritas")
        assert_eq(c.content.sets.gozosos.mysteries[2].title, es.sets.gozosos.mysteries[2].title)
        assert_eq(#c.content.sets.gozosos.mysteries, 5)
        assert_eq(c.content.sets.luminosos, es.sets.luminosos)
    end)

    it("falls back to Spanish for a missing string", function()
        local c = I18n.catalog("en", function(kind, lang)
            if kind == "l10n" and lang == "en" then return { title = "Holy Rosary" } end
            return load(kind, lang)
        end)
        assert_eq(c.strings.title, "Holy Rosary")
        assert_eq(c.strings.restart, load("l10n", "es").restart)
    end)
end)

describe("UI strings", function()
    local es = load("l10n", "es")

    it("exist for every language", function()
        for _, lang in ipairs(I18n.LANGUAGES) do
            assert_true(file_exists(PLUGIN_DIR .. "/l10n/" .. lang .. ".lua"), lang)
            assert_eq(type(load("l10n", lang)), "table", lang)
        end
    end)

    it("have every key of the Spanish strings, and no other, in every language", function()
        local expected = shape(es)
        for _, lang in ipairs(I18n.LANGUAGES) do
            local strings = load("l10n", lang)
            assert_eq(shape(strings), expected, lang)
            for path, kind in pairs(shape(strings)) do
                if kind == "string" then
                    local value = strings
                    for part in path:gmatch("[^.]+") do value = value[tonumber(part) or part] end
                    assert_true(#value > 0, lang .. " " .. path .. " is not empty")
                end
            end
        end
    end)

    it("keep the format directives of the Spanish strings", function()
        for _, lang in ipairs(I18n.LANGUAGES) do
            local strings = load("l10n", lang)
            for key, value in pairs(es) do
                if type(value) == "string" then
                    assert_eq(directives(strings[key]), directives(value), lang .. " " .. key)
                end
            end
        end
    end)

    it("cover every prayer of the step sequence and the five mysteries", function()
        for _, lang in ipairs(I18n.LANGUAGES) do
            local strings = load("l10n", lang)
            for _, step in ipairs(Rosary.steps()) do
                if step.prayer ~= "announcement" then
                    assert_true(strings.prayers[step.prayer], lang .. " " .. step.prayer)
                end
            end
            assert_eq(#strings.mysteries, 5, lang)
        end
    end)
end)

describe("I18n.step_label", function()
    local es = load("l10n", "es")
    local steps = Rosary.steps()

    it("labels steps in Spanish", function()
        local function label(i) return I18n.step_label(steps[i], es) end
        assert_eq(label(1), "Señal de la Cruz")
        assert_eq(label(2), "Credo")
        assert_eq(label(3), "Padre Nuestro")
        assert_eq(label(5), "Ave María 2/3")
        assert_eq(label(7), "Gloria")
        assert_eq(label(8), "Primer misterio")
        assert_eq(label(22), "Segundo misterio")
        assert_eq(label(36), "Tercer misterio")
        assert_eq(label(50), "Cuarto misterio")
        assert_eq(label(64), "Quinto misterio")
        assert_eq(label(16), "Ave María 7/10")
        assert_eq(label(21), "Oh Jesús mío")
        assert_eq(label(78), "Salve")
    end)

    it("labels steps in every language", function()
        local expected = {
            en = { "Sign of the Cross", "Hail Mary 2/3", "First mystery", "Hail Mary 7/10" },
            pt = { "Sinal da Cruz", "Ave-Maria 2/3", "Primeiro mistério", "Ave-Maria 7/10" },
            la = { "Signum Crucis", "Ave Maria 2/3", "Mysterium primum", "Ave Maria 7/10" },
            it = { "Segno della Croce", "Ave Maria 2/3", "Primo mistero", "Ave Maria 7/10" },
        }
        for lang, labels in pairs(expected) do
            local strings = load("l10n", lang)
            local actual = {}
            for i, index in ipairs({ 1, 5, 8, 16 }) do actual[i] = I18n.step_label(steps[index], strings) end
            assert_eq(actual, labels, lang)
        end
    end)

    it("numbers the decades in the ring", function()
        assert_eq(I18n.decade_number(3, es), "3º")
        assert_eq(I18n.decade_number(3, load("l10n", "en")), "3")
    end)
end)

describe("bitmap headings", function()
    -- Every text the widget draws with the bitmap font: the title, the
    -- mystery set, the step labels, the card's ordinal headings and the
    -- decade numbers. The catalog of each language holds its own content
    -- module when there is one, so new content is covered as it arrives.
    local function headings(c)
        local texts = { c.strings.title }
        for _, set_id in ipairs(Rosary.SET_ORDER) do
            texts[#texts + 1] = c.content.sets[set_id].title
        end
        for _, step in ipairs(Rosary.steps()) do
            texts[#texts + 1] = I18n.step_label(step, c.strings)
        end
        for n = 1, 5 do
            texts[#texts + 1] = I18n.mystery_heading(n, c.strings)
            texts[#texts + 1] = I18n.decade_number(n, c.strings)
        end
        return texts
    end

    it("have a glyph for every character in every language", function()
        for _, lang in ipairs(I18n.LANGUAGES) do
            for _, text in ipairs(headings(I18n.catalog(lang, load))) do
                assert_true(#text > 0, lang .. ": empty heading")
                for _, ch in ipairs(PixelArt.chars(PixelArt.upper(text))) do
                    assert_true(PixelArt.glyph(ch), lang .. ": missing glyph " .. ch .. " in " .. text)
                end
            end
        end
    end)
end)
