--[[--
Languages of the rosario plugin: which language to show, and its strings and
content.

The language is the plugin's own setting (`rosario_language` in KOReader's
reader settings) when it names a supported language; otherwise KOReader's UI
language ("pt_BR" is Portuguese, "it_IT" Italian); otherwise English.

Each language has its UI strings in `l10n/<lang>.lua` and its prayers and
mystery cards in `content/<lang>.lua`, both under the plugin folder. Spanish
is complete, so whatever a language lacks, a whole module or a single key,
is taken from Spanish.

This module has no KOReader dependencies: settings and files are read
through injected functions, so it can be tested with plain LuaJIT.
]]

local I18n = {}

--- Supported languages, in the order the language menu lists them.
I18n.LANGUAGES = { "es", "en", "pt", "la", "it" }

--- The name of each language in that language.
I18n.NAMES = { es = "Español", en = "English", pt = "Português", la = "Latina", it = "Italiano" }

--- Reader setting holding the language chosen in the plugin's menu.
I18n.SETTING = "rosario_language"

--- Reader setting holding KOReader's UI language.
I18n.UI_LANGUAGE = "language"

--- Language used when neither setting names a supported one.
I18n.DEFAULT = "en"

--- The complete language that fills in what another language lacks.
I18n.FALLBACK = "es"

local SUPPORTED = {}
for _, code in ipairs(I18n.LANGUAGES) do SUPPORTED[code] = true end

function I18n.is_supported(code)
    return SUPPORTED[code] == true
end

--- The supported language of a locale such as "pt_BR", "it-IT" or
-- "es_ES.UTF-8", from its prefix; nil when it is not supported.
function I18n.from_locale(locale)
    if type(locale) ~= "string" then return nil end
    local code = locale:match("^(%a+)")
    code = code and code:lower()
    return I18n.is_supported(code) and code or nil
end

--- The language to show.
-- @tparam function read_setting returns the value of a reader setting key,
-- like `G_reader_settings:readSetting`
-- @treturn string a code of I18n.LANGUAGES
function I18n.resolve(read_setting)
    local chosen = read_setting(I18n.SETTING)
    if I18n.is_supported(chosen) then return chosen end
    return I18n.from_locale(read_setting(I18n.UI_LANGUAGE)) or I18n.DEFAULT
end

--- `primary` with every key it lacks taken from `fallback`, at every depth.
-- A value of `primary` wins, `false` included. Neither table is modified;
-- the result may share untouched subtables with them.
function I18n.merge(primary, fallback)
    if primary == nil then return fallback end
    if type(primary) ~= "table" or type(fallback) ~= "table" then return primary end
    local out = {}
    for k, v in pairs(fallback) do out[k] = I18n.merge(primary[k], v) end
    for k, v in pairs(primary) do
        if out[k] == nil then out[k] = v end
    end
    return out
end

--- A loader of the modules under `dir`: `load(kind, lang)` runs
-- `<dir>/<kind>/<lang>.lua` and returns its table, or nil when the file is
-- missing. A file that fails to run or returns no table is reported to
-- `warn` (when given) and loads nothing.
function I18n.file_loader(dir, warn)
    return function(kind, lang)
        local path = dir .. "/" .. kind .. "/" .. lang .. ".lua"
        local fh = io.open(path, "r")
        if not fh then return nil end
        fh:close()
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" then return data end
        if warn then warn("rosario: cannot load", path, tostring(data)) end
        return nil
    end
end

--- The strings and content of `lang`, completed from Spanish.
-- @tparam function load a loader such as the one I18n.file_loader returns
-- @treturn table { lang = lang, strings = ..., content = ... }
function I18n.catalog(lang, load)
    local function complete(kind)
        local fallback = load(kind, I18n.FALLBACK)
        if lang == I18n.FALLBACK then return fallback end
        return I18n.merge(load(kind, lang), fallback)
    end
    return { lang = lang, strings = complete("l10n"), content = complete("content") }
end

--- The heading of the mystery card of decade `n`, e.g. "Primer misterio".
function I18n.mystery_heading(n, strings)
    return strings.mysteries[n] or ""
end

--- The decade number drawn in the middle of the ring, e.g. "3º".
function I18n.decade_number(n, strings)
    return string.format(strings.decade_number, n)
end

--- The heading of a step of Rosary.steps: the prayer, with the count of a
-- Hail Mary ("Ave María 2/3"), or the mystery of an announcement.
function I18n.step_label(step, strings)
    if step.kind == "announcement" then
        return I18n.mystery_heading(step.mystery, strings)
    end
    local name = strings.prayers[step.prayer] or ""
    if step.ave and step.aves then
        return string.format("%s %d/%d", name, step.ave, step.aves)
    end
    return name
end

return I18n
