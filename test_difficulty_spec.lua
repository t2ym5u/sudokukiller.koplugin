-- Difficulty guarantees of Killer Sudoku's grids, through its own board.lua
-- (docs/dev/TESTING.md, "Difficulty specs"). Every level is dealt with
-- given digits until sudoku-common's logic_solver (cage techniques, nothing
-- above tier LOCKED, no trial step) finishes it within the level's budget of
-- steps past the singles (Hard and Expert were dealt with none up to 1.9.3,
-- and needed guessing). On fixed seeds: each level builds in reasonable time,
-- has one solution reached by deduction alone within its cap, the levels are
-- distinct and in order on averages (fewer givens, more steps), and a seed
-- gives the same grid without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local Mod = require("board")
local LS  = require("logic_solver")
local KillerSudokuBoard = Mod.KillerSudokuBoard

local LEVELS = { "easy", "medium", "hard", "expert" }
local SEEDS  = 8
-- Steps past the singles each deducible level may need (board.lua's
-- HARD_STEP_BUDGET). Before the cap, Easy needed about 12, like Medium.
local STEP_CAP = { easy = 3, medium = 8, hard = 16, expert = 24 }
local SIMPLE = { naked_single = true, hidden_single = true, cage_last_cell = true }

local function lcg(seed)
    local state = seed
    return function(i)
        state = (1103515245 * state + 12345) % 2147483648
        return state % i + 1
    end
end

-- Steps beyond singles a grid needs, or nil if logic cannot finish it.
local function hardSteps(b, max_tier)
    local res = LS.solve(b.user, 9, 3, 3, nil,
        { cages = b.cages, max_tier = max_tier or LS.TIER.LOCKED, trace = true })
    local hard = 0
    for _, step in ipairs(res.steps) do
        if not SIMPLE[step.technique] then hard = hard + 1 end
    end
    return res.solved and hard or nil, res
end

local function counts(b)
    local givens, deliberate = 0, 0
    for r = 1, b.n do
        for c = 1, b.n do
            if b:isGiven(r, c) then givens = givens + 1 end
        end
    end
    for _, cage in ipairs(b.cages) do
        if cage.is_given then deliberate = deliberate + 1 end
    end
    return givens, #b.cages - deliberate
end

local runs = {}
local function run(level)
    if runs[level] then return runs[level] end
    local out = {}
    for seed = 1, SEEDS do
        math.randomseed(seed)
        local b = KillerSudokuBoard:new()
        local t0 = os.clock()
        b:generate(level, lcg(seed * 7919 + 11))
        local secs = os.clock() - t0
        local givens, cages = counts(b)
        local steps, res = hardSteps(b)
        out[#out + 1] = { b = b, secs = secs, givens = givens, cages = cages,
                          total_cages = #b.cages, steps = steps, res = res }
    end
    runs[level] = out
    return out
end

local function avg(level, field)
    local sum, gs = 0, run(level)
    for _, g in ipairs(gs) do sum = sum + (g[field] or 0) end
    return sum / #gs
end

describe("Killer Sudoku difficulty", function()

    it("orders its step budgets", function()
        for i = 2, #LEVELS do
            assert.is_true(Mod._HARD_STEP_BUDGET[LEVELS[i]] > Mod._HARD_STEP_BUDGET[LEVELS[i - 1]])
            assert.are.equal(STEP_CAP[LEVELS[i]], Mod._HARD_STEP_BUDGET[LEVELS[i]])
        end
    end)

    it("builds every level in reasonable time (1.6.0 took seconds per Hard grid)", function()
        -- Generous: the worst grid measured 2026-11-09 takes ~0.8 s under
        -- busted's Lua 5.5 with the bit shim (~0.1 s under LuaJIT); 1.6.0
        -- needed ~3 s per Hard/Expert grid under LuaJIT alone.
        for _, level in ipairs(LEVELS) do
            for _, g in ipairs(run(level)) do
                assert.is_true(g.secs < 8, ("%s took %.2f s"):format(level, g.secs))
            end
        end
    end)

    for _, level in ipairs(LEVELS) do
        it(level .. " grids have one solution, reached by deduction within "
           .. STEP_CAP[level] .. " steps beyond singles", function()
            for _, g in ipairs(run(level)) do
                assert.is_not_nil(g.steps, "logic_solver stuck")
                assert.is_true(g.steps <= STEP_CAP[level], level .. " needed " .. g.steps)
                assert.is_true(g.res.max_tier <= LS.TIER.LOCKED)
                assert.are.same(g.b.solution, g.res.grid)
                local solutions, exhausted = Mod._countCageSolutions(
                    g.b.cell_cage, g.b.cages, 9, 3, 3, 2, 200000)
                assert.is_false(exhausted)
                assert.are.equal(1, solutions)
            end
        end)
    end

    it("Easy has deliberate given digits (anchors for human-solvable deduction)", function()
        for _, g in ipairs(run("easy")) do
            assert.is_true(g.givens > 0)
            for r = 1, 9 do
                for c = 1, 9 do
                    if g.b:isGiven(r, c) then
                        assert.are.equal(g.b.solution[r][c], g.b.user[r][c])
                    end
                end
            end
        end
    end)

    it("separates the levels on averages: fewer givens, more steps", function()
        local msg = {}
        for _, level in ipairs(LEVELS) do
            msg[#msg + 1] = ("%s givens %.1f steps %.1f"):format(
                level, avg(level, "givens"), avg(level, "steps"))
        end
        msg = table.concat(msg, "; ")
        for i = 2, #LEVELS do
            assert.is_true(avg(LEVELS[i], "givens") < avg(LEVELS[i - 1], "givens"), msg)
            assert.is_true(avg(LEVELS[i], "steps") > avg(LEVELS[i - 1], "steps"), msg)
        end
    end)

    it("deals the same grid for the same seed, without reading the clock", function()
        local clock, time = os.clock, os.time
        local ok, err = pcall(function()
            os.clock = function() error("generation read os.clock") end
            os.time  = function() error("generation read os.time") end
            for _, level in ipairs(LEVELS) do
                local seed = 101
                local a, b = KillerSudokuBoard:new(), KillerSudokuBoard:new()
                math.randomseed(seed)
                a:generate(level, lcg(seed))
                math.randomseed(seed)
                b:generate(level, lcg(seed))
                assert.are.same(a.solution, b.solution)
                assert.are.same(a.cages, b.cages)
                assert.are.same(a.user, b.user)
                -- The solution depends on randInt alone; the cages are drawn
                -- from math.random (Killer has no Daily Challenge).
                local c = KillerSudokuBoard:new()
                math.randomseed(seed + 5000)
                c:generate(level, lcg(seed))
                assert.are.same(a.solution, c.solution)
            end
        end)
        os.clock, os.time = clock, time
        assert.is_true(ok, err)
    end)
end)
