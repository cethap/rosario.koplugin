local Content = require("content.es")
local I18n = require("i18n")
local Rosary = require("rosary")

local root = (arg and arg[0] and arg[0]:match("^(.*)/spec/run%.lua$")) or "."
local load = I18n.file_loader(root .. "/rosario.koplugin")

-- Every language of the plugin has a content module of its own, which the
-- plugin completes from Spanish, key by key (see I18n.catalog).
local LANGUAGES = I18n.LANGUAGES

local PRAYER_IDS = { "sign_of_cross", "creed", "our_father", "hail_mary", "glory_be", "fatima", "salve" }

local function sentence_count(text)
    local n = 0
    for _ in text:gmatch("[%.!?]+%s") do n = n + 1 end
    if text:match("[%.!?]$") then n = n + 1 end
    return n
end

local function is_url(s)
    return type(s) == "string" and s:match("^https://") ~= nil
end

-- The content module of `lang`, failing the spec when it is missing.
local function module_of(lang)
    local content = load("content", lang)
    assert_eq(type(content), "table", "content/" .. lang .. ".lua")
    return content
end

-- Every string of a nested table, with its key path.
local function each_string(t, path, fn)
    for k, v in pairs(t) do
        local where = path .. "." .. tostring(k)
        if type(v) == "table" then
            each_string(v, where, fn)
        elseif type(v) == "string" then
            fn(v, where)
        end
    end
end

describe("content/es.lua", function()
    it("provides every prayer used by the step sequence", function()
        for _, step in ipairs(Rosary.steps()) do
            if step.prayer ~= "announcement" then
                local prayer = Content.prayers[step.prayer]
                assert_true(prayer, "prayer " .. step.prayer)
                assert_true(#prayer.title > 0, step.prayer .. " title")
                assert_true(#prayer.text > 20, step.prayer .. " text")
                assert_true(prayer.source:match("^https://"), step.prayer .. " source")
            end
        end
    end)

    it("has five mysteries for each set", function()
        for _, set_id in ipairs(Rosary.SET_ORDER) do
            local set = Content.sets[set_id]
            assert_true(set, set_id)
            assert_eq(set.id, set_id)
            assert_true(set.title:match("^Misterios "), set_id .. " title")
            assert_eq(#set.mysteries, 5, set_id)
        end
    end)

    it("gives every mystery a complete card", function()
        for _, set_id in ipairs(Rosary.SET_ORDER) do
            for n, m in ipairs(Content.sets[set_id].mysteries) do
                local where = set_id .. " " .. n
                assert_eq(m.number, n, where)
                assert_true(#m.title > 3, where .. " title")
                assert_true(m.reference:match("^%a+ %d+, %d+"), where .. " reference")
                assert_true(#m.fruit > 3, where .. " fruit")
                local sentences = sentence_count(m.meditation)
                assert_true(sentences >= 2 and sentences <= 3, where .. " meditation has 2-3 sentences")
                local s = m.scripture
                assert_true(#s.text > 20, where .. " scripture text")
                assert_true(#s.citation > 3, where .. " citation")
                assert_true(s.source:match("^https://"), where .. " scripture source")
                if not s.verbatim then
                    assert_true(s.text:match("^cf%. "), where .. " paraphrase must start with cf.")
                end
            end
        end
    end)
end)

describe("content modules", function()
    it("exist for every language of the plugin", function()
        for _, lang in ipairs(LANGUAGES) do
            assert_eq(type(load("content", lang)), "table", "content/" .. lang .. ".lua")
        end
    end)
end)

for _, lang in ipairs(LANGUAGES) do
    describe("content/" .. lang .. ".lua on its own", function()
        it("records the sources of its prayers, Fatima prayer and mystery titles", function()
            local sources = module_of(lang).sources
            assert_eq(type(sources), "table", lang .. " sources")
            for _, key in ipairs({ "prayers", "fatima", "mystery_titles" }) do
                assert_true(is_url(sources[key]), lang .. " source of " .. key)
            end
        end)

        it("has every prayer, with its title, text and source", function()
            local prayers = module_of(lang).prayers
            for _, id in ipairs(PRAYER_IDS) do
                local prayer = prayers[id]
                assert_true(prayer, lang .. " prayer " .. id)
                assert_true(#prayer.title > 0, lang .. " " .. id .. " title")
                assert_true(#prayer.text > 20, lang .. " " .. id .. " text")
                assert_true(is_url(prayer.source), lang .. " " .. id .. " source")
            end
        end)

        it("opens its Fatima prayer with the name of the Fatima step", function()
            local label = load("l10n", lang).prayers.fatima
            local start = module_of(lang).prayers.fatima.text:find(label, 1, true)
            -- Up to an opening mark such as "¡" (two bytes) before the name.
            assert_true(start and start <= 3, lang .. " Fatima prayer opens with " .. label)
        end)

        it("has the four sets with five complete mystery cards", function()
            local sets = module_of(lang).sets
            for _, set_id in ipairs(Rosary.SET_ORDER) do
                local set = sets[set_id]
                assert_true(set, lang .. " " .. set_id)
                assert_eq(set.id, set_id, lang)
                assert_true(#set.title > 0, lang .. " " .. set_id .. " title")
                assert_eq(#set.mysteries, 5, lang .. " " .. set_id)
                for n, m in ipairs(set.mysteries) do
                    local where = lang .. " " .. set_id .. " " .. n
                    assert_eq(m.number, n, where)
                    assert_true(#m.title > 3, where .. " title")
                    assert_true(m.reference:match("^%a+ %d+[,:] ?%d+"), where .. " reference " .. m.reference)
                    assert_true(#m.fruit > 3, where .. " fruit")
                    local sentences = sentence_count(m.meditation)
                    assert_true(sentences >= 2 and sentences <= 3, where .. " meditation has 2-3 sentences")
                end
            end
        end)

        it("quotes scripture of its own for every mystery, with the translation and source", function()
            local content = module_of(lang)
            assert_true(is_url(content.sources.scripture), lang .. " source of the scripture")
            for _, set_id in ipairs(Rosary.SET_ORDER) do
                for n, m in ipairs(content.sets[set_id].mysteries) do
                    local s, where = m.scripture, lang .. " " .. set_id .. " " .. n
                    assert_eq(type(s), "table", where .. " scripture")
                    assert_true(#s.text > 20, where .. " scripture text")
                    assert_true(#s.citation > 3, where .. " citation")
                    assert_true(#s.translation > 3, where .. " translation")
                    assert_true(is_url(s.source), where .. " scripture source")
                    assert_eq(type(s.verbatim), "boolean", where .. " verbatim")
                    if not s.verbatim then
                        assert_true(s.text:match("^cf%. "), where .. " paraphrase must start with cf.")
                    end
                end
            end
        end)

        it("has no control characters, replacement characters or stray accents", function()
            each_string(module_of(lang), lang, function(s, where)
                assert_false(s:find("\194[\128-\159]"), where .. " has a C1 control character")
                assert_false(s:find("\239\191\189", 1, true), where .. " has U+FFFD")
                assert_false(s:find("\194\180", 1, true), where .. " has a spacing acute accent")
            end)
        end)
    end)

    describe("content of " .. lang .. " completed from Spanish", function()
        it("gives every mystery a scripture fragment", function()
            local content = I18n.catalog(lang, load).content
            for _, set_id in ipairs(Rosary.SET_ORDER) do
                for n, m in ipairs(content.sets[set_id].mysteries) do
                    local where = lang .. " " .. set_id .. " " .. n
                    assert_true(#m.scripture.text > 20, where .. " scripture")
                    assert_true(is_url(m.scripture.source), where .. " scripture source")
                end
            end
        end)
    end)
end
