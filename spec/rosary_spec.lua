local Rosary = require("rosary")

describe("Rosary.weekday", function()
    it("returns os.date-style weekdays (1 = Sunday)", function()
        assert_eq(Rosary.weekday(2026, 10, 19), 2, "Monday")
        assert_eq(Rosary.weekday(2026, 10, 25), 1, "Sunday")
        assert_eq(Rosary.weekday(2024, 2, 29), 5, "leap day was a Thursday")
        assert_eq(Rosary.weekday(2000, 1, 1), 7, "Saturday")
    end)
end)

describe("Rosary.set_for_weekday", function()
    it("follows Rosarium Virginis Mariae", function()
        local expected = {
            [1] = "gloriosos", -- Sunday
            [2] = "gozosos", -- Monday
            [3] = "dolorosos", -- Tuesday
            [4] = "gloriosos", -- Wednesday
            [5] = "luminosos", -- Thursday
            [6] = "dolorosos", -- Friday
            [7] = "gozosos", -- Saturday
        }
        for wday, set_id in pairs(expected) do
            assert_eq(Rosary.set_for_weekday(wday), set_id, "weekday " .. wday)
        end
    end)

    it("rejects invalid weekdays", function()
        assert_error(function() Rosary.set_for_weekday(0) end)
        assert_error(function() Rosary.set_for_weekday(8) end)
    end)

    it("maps a date to its set", function()
        assert_eq(Rosary.set_for_date({ year = 2026, month = 10, day = 22 }), "luminosos")
    end)

    it("lists the four sets in liturgical order", function()
        assert_eq(Rosary.SET_ORDER, { "gozosos", "luminosos", "dolorosos", "gloriosos" })
        for _, id in ipairs(Rosary.SET_ORDER) do
            assert_true(Rosary.is_valid_set(id), id)
        end
        assert_false(Rosary.is_valid_set("otros"))
    end)
end)

describe("Rosary.date_key", function()
    it("formats dates as YYYY-MM-DD", function()
        assert_eq(Rosary.date_key({ year = 2026, month = 3, day = 7 }), "2026-03-07")
    end)
end)

describe("Rosary.steps", function()
    local steps = Rosary.steps()

    it("has 79 steps", function()
        assert_eq(#steps, 79)
        assert_eq(Rosary.STEP_COUNT, 79)
    end)

    it("follows the documented prayer order", function()
        local expected = { "sign_of_cross", "creed", "our_father",
            "hail_mary", "hail_mary", "hail_mary", "glory_be" }
        for _ = 1, 5 do
            expected[#expected + 1] = "announcement"
            expected[#expected + 1] = "our_father"
            for _ = 1, 10 do expected[#expected + 1] = "hail_mary" end
            expected[#expected + 1] = "glory_be"
            expected[#expected + 1] = "fatima"
        end
        expected[#expected + 1] = "salve"
        expected[#expected + 1] = "sign_of_cross"
        local actual = {}
        for i, step in ipairs(steps) do actual[i] = step.prayer end
        assert_eq(actual, expected)
    end)

    it("numbers every step", function()
        for i, step in ipairs(steps) do assert_eq(step.index, i) end
    end)

    it("describes the introductory beads", function()
        assert_eq(steps[1].kind, "cross")
        assert_eq(steps[1].section, "intro")
        assert_eq(steps[1].bead, 0)
        assert_eq(steps[2].kind, "cross")
        assert_eq(steps[3].kind, "large_bead")
        assert_eq(steps[3].bead, 1)
        for i = 4, 6 do
            assert_eq(steps[i].kind, "small_bead")
            assert_eq(steps[i].bead, i - 2)
            assert_eq(steps[i].ave, i - 3)
            assert_eq(steps[i].aves, 3, "three Hail Marys in the pendant")
        end
        assert_eq(steps[7].kind, "chain")
        assert_eq(steps[7].bead, nil)
        assert_eq(steps[7].decade, nil)
    end)

    it("describes each decade", function()
        for decade = 1, 5 do
            local base = 7 + (decade - 1) * 14
            local announcement = steps[base + 1]
            assert_eq(announcement.kind, "announcement", "decade " .. decade)
            assert_eq(announcement.decade, decade)
            assert_eq(announcement.mystery, decade)
            assert_eq(announcement.bead, nil)
            assert_eq(steps[base + 2].kind, "large_bead")
            assert_eq(steps[base + 2].bead, 0)
            for ave = 1, 10 do
                local step = steps[base + 2 + ave]
                assert_eq(step.kind, "small_bead")
                assert_eq(step.bead, ave)
                assert_eq(step.ave, ave)
                assert_eq(step.aves, 10, "ten Hail Marys in a decade")
                assert_eq(step.decade, decade)
                assert_eq(step.mystery, decade)
            end
            assert_eq(steps[base + 13].kind, "chain")
            assert_eq(steps[base + 14].kind, "chain")
            assert_eq(steps[base + 14].section, "decade")
        end
    end)

    it("closes with the Salve and the Sign of the Cross", function()
        assert_eq(steps[78].section, "closing")
        assert_eq(steps[78].kind, "chain")
        assert_eq(steps[79].kind, "cross")
        assert_eq(steps[79].section, "closing")
    end)

    it("leaves the labels to the language (see I18n.step_label)", function()
        for _, step in ipairs(steps) do assert_eq(step.label, nil, "step " .. step.index) end
    end)

    it("returns a fresh copy so callers cannot corrupt the sequence", function()
        local a = Rosary.steps()
        a[1].prayer = "changed"
        assert_eq(Rosary.steps()[1].prayer, "sign_of_cross")
    end)
end)

describe("decade helpers", function()
    local steps = Rosary.steps()

    it("counts a decade as completed once its ten Hail Marys are prayed", function()
        assert_eq(Rosary.completed_decades(1), 0)
        assert_eq(Rosary.completed_decades(19), 0, "tenth Ave of decade 1 is still current")
        assert_eq(Rosary.completed_decades(20), 1, "Gloria of decade 1")
        assert_eq(Rosary.completed_decades(22), 1)
        assert_eq(Rosary.completed_decades(76), 5)
        assert_eq(Rosary.completed_decades(79), 5)
    end)

    it("flags decade starts and completions", function()
        assert_true(Rosary.is_decade_start(steps[8]))
        assert_false(Rosary.is_decade_start(steps[9]))
        assert_true(Rosary.is_decade_completion(steps[20]), "Gloria after the tenth Ave")
        assert_false(Rosary.is_decade_completion(steps[7]), "introductory Gloria")
        assert_false(Rosary.is_decade_completion(steps[21]))
    end)
end)

describe("Rosary session", function()
    it("starts at the first step", function()
        local s = Rosary.new("gozosos")
        assert_eq(s.set_id, "gozosos")
        assert_eq(s.index, 1)
        assert_eq(s:current().prayer, "sign_of_cross")
        assert_true(s:is_first())
        assert_false(s:is_last())
    end)

    it("rejects unknown sets", function()
        assert_error(function() Rosary.new("otros") end)
    end)

    it("moves forward and back within bounds", function()
        local s = Rosary.new("dolorosos")
        assert_false(s:prev(), "cannot go before the first step")
        assert_eq(s.index, 1)
        assert_true(s:next())
        assert_eq(s:current().prayer, "creed")
        assert_true(s:prev())
        assert_eq(s.index, 1)
        for _ = 1, 78 do assert_true(s:next()) end
        assert_eq(s.index, 79)
        assert_true(s:is_last())
        assert_false(s:next(), "cannot go past the last step")
        assert_eq(s.index, 79)
    end)

    it("resets to the first step", function()
        local s = Rosary.new("gloriosos", 40)
        assert_eq(s.index, 40)
        s:reset()
        assert_eq(s.index, 1)
    end)

    it("reports progress", function()
        local s = Rosary.new("gloriosos", 22)
        assert_eq(s:completed_decades(), 1)
        assert_eq(s:current().decade, 2)
    end)

    it("changes the mystery set without losing its place", function()
        local s = Rosary.new("gozosos", 30)
        s:set_mystery_set("luminosos")
        assert_eq(s.set_id, "luminosos")
        assert_eq(s.index, 30)
        assert_error(function() s:set_mystery_set("otros") end)
    end)

    it("serializes to a plain table", function()
        local s = Rosary.new("luminosos", 12)
        assert_eq(s:serialize(), { set_id = "luminosos", step = 12 })
    end)
end)

describe("Rosary.resume", function()
    local monday = { date = "2026-10-19", wday = 2 }

    it("resumes a session saved today", function()
        local s = Rosary.resume({ date = "2026-10-19", set_id = "dolorosos", step = 33 }, monday)
        assert_eq(s.set_id, "dolorosos", "a manual override survives a reopen")
        assert_eq(s.index, 33)
    end)

    it("starts today's set when the saved date is old", function()
        local s = Rosary.resume({ date = "2026-10-18", set_id = "gloriosos", step = 33 }, monday)
        assert_eq(s.set_id, "gozosos")
        assert_eq(s.index, 1)
    end)

    it("starts fresh without saved progress", function()
        local s = Rosary.resume(nil, monday)
        assert_eq(s.set_id, "gozosos")
        assert_eq(s.index, 1)
    end)

    it("ignores corrupt saved progress", function()
        local cases = {
            { date = "2026-10-19", set_id = "gozosos", step = 0 },
            { date = "2026-10-19", set_id = "gozosos", step = 80 },
            { date = "2026-10-19", set_id = "gozosos", step = 2.5 },
            { date = "2026-10-19", set_id = "gozosos", step = "3" },
            { date = "2026-10-19", set_id = "otros", step = 3 },
        }
        for i, saved in ipairs(cases) do
            local s = Rosary.resume(saved, monday)
            assert_eq(s.set_id, "gozosos", "case " .. i)
            assert_eq(s.index, 1, "case " .. i)
        end
    end)
end)

describe("Rosary.bead_state", function()
    local steps = Rosary.steps()

    it("splits beads into done, current and upcoming", function()
        local step = steps[16] -- decade 1, seventh Hail Mary
        assert_eq(Rosary.bead_state(step, 0), "done", "Our Father bead")
        assert_eq(Rosary.bead_state(step, 6), "done")
        assert_eq(Rosary.bead_state(step, 7), "current")
        assert_eq(Rosary.bead_state(step, 8), "upcoming")
        assert_eq(Rosary.bead_state(step, 10), "upcoming")
    end)

    it("shows a fresh decade at its announcement", function()
        for slot = 0, 10 do
            assert_eq(Rosary.bead_state(steps[22], slot), "upcoming", "slot " .. slot)
        end
    end)

    it("fills every bead on chain prayers", function()
        for slot = 0, 10 do
            assert_eq(Rosary.bead_state(steps[20], slot), "done", "decade Gloria, slot " .. slot)
            assert_eq(Rosary.bead_state(steps[21], slot), "done", "Fatima prayer, slot " .. slot)
        end
        for slot = 0, 4 do
            assert_eq(Rosary.bead_state(steps[7], slot), "done", "intro Gloria, slot " .. slot)
        end
    end)

    it("marks the crucifix as current on the opening prayers", function()
        assert_eq(Rosary.bead_state(steps[2], 0), "current")
        assert_eq(Rosary.bead_state(steps[2], 1), "upcoming")
    end)

    it("keeps the pendant filled while closing", function()
        for slot = 0, 4 do
            assert_eq(Rosary.bead_state(steps[78], slot), "done", "Salve, slot " .. slot)
        end
        assert_eq(Rosary.bead_state(steps[79], 0), "current")
        for slot = 1, 4 do
            assert_eq(Rosary.bead_state(steps[79], slot), "done", "final cross, slot " .. slot)
        end
    end)
end)
