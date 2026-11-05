local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("KillerSudokuBoard", function()
    local Mod

    setup(function()
        Mod = require("board")
    end)

    local KillerSudokuBoard = nil
    before_each(function()
        KillerSudokuBoard = Mod.KillerSudokuBoard
    end)

    describe("construction", function()
        it("creates a 9×9 board", function()
            local b = KillerSudokuBoard:new()
            assert.are.equal(9, b.n)
            assert.are.equal(3, b.box_rows)
            assert.are.equal(3, b.box_cols)
        end)

        it("starts with empty user grid", function()
            local b = KillerSudokuBoard:new()
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(0, b.user[r][c])
                end
            end
        end)
    end)

    describe("isGiven", function()
        it("Easy has deliberate given digits (anchors for human-solvable deduction)", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local given_count = 0
            for r = 1, b.n do
                for c = 1, b.n do
                    if b:isGiven(r, c) then
                        given_count = given_count + 1
                        assert.are.equal(b.solution[r][c], b.user[r][c])
                    end
                end
            end
            assert.is_true(given_count > 0)
        end)

        it("Hard stays genre-pure Killer Sudoku (no deliberate givens)", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("hard")
            local given_count = 0
            for r = 1, b.n do
                for c = 1, b.n do
                    if b:isGiven(r, c) then given_count = given_count + 1 end
                end
            end
            -- A rare growth-stranded singleton can still slip through, but
            -- Hard should never carry the Easy/Medium deliberate-given count.
            assert.is_true(given_count <= 2)
        end)
    end)

    describe("generate / cages", function()
        it("generates cages that cover every cell", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local count = 0
            for _, cage in ipairs(b.cages) do
                count = count + #cage.cells
            end
            assert.are.equal(b.n * b.n, count)
        end)

        it("each cage sum matches its solution values", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("medium")
            for _, cage in ipairs(b.cages) do
                local total = 0
                for _, cell in ipairs(cage.cells) do
                    total = total + b.solution[cell.r][cell.c]
                end
                assert.are.equal(cage.sum, total,
                    "cage " .. cage.id .. " sum mismatch")
            end
        end)

        it("cell_cage maps every cell to a valid cage id", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    local id = b.cell_cage[r][c]
                    assert.is_true(id >= 1 and id <= #b.cages,
                        ("cell [%d][%d] has invalid cage id %d"):format(r, c, id))
                end
            end
        end)
    end)

    describe("getCage / getCageLabelCell", function()
        it("getCage returns the cage for a valid cell", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local cage = b:getCage(1, 1)
            assert.is_not_nil(cage)
            assert.is_true(cage.sum > 0)
        end)

        it("getCageLabelCell returns the top-left cell of the cage", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local cage = b:getCage(1, 1)
            local label = b:getCageLabelCell(cage)
            assert.is_not_nil(label)
            -- Label cell must be one of the cage's cells
            local found = false
            for _, cell in ipairs(cage.cells) do
                if cell.r == label.r and cell.c == label.c then found = true; break end
            end
            assert.is_true(found)
        end)
    end)

    describe("recalcConflicts (cage duplicates)", function()
        it("marks duplicate values within a cage as conflicts", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            -- Find a cage with ≥ 2 cells
            local cage
            for _, cg in ipairs(b.cages) do
                if #cg.cells >= 2 then cage = cg; break end
            end
            assert.is_not_nil(cage)
            local r1, c1 = cage.cells[1].r, cage.cells[1].c
            local r2, c2 = cage.cells[2].r, cage.cells[2].c
            -- Write the same value into both cells
            b.user[r1][c1] = 5
            b.user[r2][c2] = 5
            b:recalcConflicts()
            assert.is_true(b.conflicts[r1][c1])
            assert.is_true(b.conflicts[r2][c2])
        end)

        it("no conflict when cage values are distinct", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local cage
            for _, cg in ipairs(b.cages) do
                if #cg.cells >= 2 then cage = cg; break end
            end
            local r1, c1 = cage.cells[1].r, cage.cells[1].c
            local r2, c2 = cage.cells[2].r, cage.cells[2].c
            -- Use the actual solution values: arbitrary distinct digits (e.g. 1
            -- and 2) can coincidentally collide with an already-filled given
            -- cell elsewhere in the shared row/col/box, which would trigger a
            -- legitimate (non-cage) conflict unrelated to what's under test.
            b.user[r1][c1] = b.solution[r1][c1]
            b.user[r2][c2] = b.solution[r2][c2]
            b:recalcConflicts()
            -- These two cells alone won't conflict in their cage
            assert.is_false(b.conflicts[r1][c1])
            assert.is_false(b.conflicts[r2][c2])
        end)
    end)

    describe("isSolved", function()
        it("returns false for a generated puzzle before any user input", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            assert.is_false(b:isSolved())
        end)

        it("returns true when user matches solution with no conflicts", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    b.user[r][c] = b.solution[r][c]
                end
            end
            b:recalcConflicts()
            assert.is_true(b:isSolved())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips cages and user state", function()
            math.randomseed(42)
            local b = KillerSudokuBoard:new()
            b:generate("easy")
            b.user[1][1] = 3
            local data = b:serialize()

            local b2 = KillerSudokuBoard:new()
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(#b.cages, #b2.cages)
            assert.are.equal(3, b2.user[1][1])
            -- cage sums preserved
            for i, cage in ipairs(b.cages) do
                assert.are.equal(cage.sum, b2.cages[i].sum)
            end
        end)

        it("load returns false for invalid data", function()
            local b = KillerSudokuBoard:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)

    -- 1.7.0 rewrote the cage-sum solver for speed (one cage mask instead of
    -- a sorted table per cell and digit). It must explore exactly the same
    -- search tree: the node budget decides which cage layout a seed ends up
    -- with, so these are the counts the 1.6.0 solver gave on three layouts.
    describe("difficulty", function()
        -- Steps beyond singles a grid needs, or nil if logic cannot finish it.
        local function hardSteps(b)
            local LS = require("logic_solver")
            local res = LS.solve(b.user, 9, 3, 3, nil,
                { cages = b.cages, max_tier = LS.TIER.LOCKED, trace = true })
            if not res.solved then return nil end
            local hard = 0
            for _, step in ipairs(res.steps) do
                if step.technique ~= "naked_single" and step.technique ~= "hidden_single"
                    and step.technique ~= "cage_last_cell" then
                    hard = hard + 1
                end
            end
            return hard
        end

        -- Before the cap, Easy needed about 12 such steps, like Medium.
        for _, case in ipairs({ { "easy", 3 }, { "medium", 8 } }) do
            it(case[1] .. " grids need at most " .. case[2] .. " steps beyond singles", function()
                for seed = 1, 8 do
                    math.randomseed(seed)
                    local b = KillerSudokuBoard:new()
                    b:generate(case[1])
                    local hard = hardSteps(b)
                    assert.is_not_nil(hard)
                    assert.is_true(hard <= case[2])
                end
            end)
        end
    end)

    describe("cage-sum solver", function()
        local LAYOUTS = {
            { label = "medium layout with two solutions",
              cell_cage = {{22,22,22,22,9,17,19,19,14},{24,24,24,22,17,17,29,14,14},{7,24,24,4,5,17,29,1,15},{27,26,31,31,20,17,15,15,15},{27,26,31,20,20,20,20,12,15},{16,31,31,32,2,6,18,18,11},{16,16,16,21,21,28,28,30,30},{25,13,13,13,21,28,28,23,10},{25,25,13,3,21,8,23,23,23}},
              sums = {7,6,8,5,8,3,2,2,4,9,2,4,15,12,27,26,24,9,11,23,21,22,12,29,14,8,10,22,11,13,27,9},
              solutions = 2, exhausted = false, nodes = 1867 },
            { label = "hard layout that runs out of budget",
              cell_cage = {{16,7,13,13,13,11,11,17,17},{16,7,16,13,13,11,11,17,17},{16,16,16,14,14,14,3,3,18},{2,2,10,9,9,3,3,3,18},{2,10,10,9,4,4,12,12,18},{2,10,10,9,4,4,12,12,12},{8,6,6,19,19,19,19,19,21},{8,6,6,19,1,1,1,1,21},{5,5,6,20,20,20,15,15,15}},
              sums = {20,21,28,11,7,31,7,7,25,24,21,33,25,7,22,36,23,9,28,8,12},
              solutions = 0, exhausted = true, nodes = 6001 },
            { label = "easy layout with a unique solution",
              cell_cage = {{35,24,24,38,38,13,13,7,17},{35,34,34,25,15,15,37,37,17},{16,33,11,25,1,15,29,29,29},{16,33,10,25,31,31,36,36,40},{16,33,30,2,31,41,12,36,3},{19,19,30,39,27,27,27,18,22},{28,28,28,39,21,26,26,18,18},{32,32,9,39,21,6,26,5,8},{32,4,20,20,21,14,14,23,23}},
              sums = {7,7,2,6,7,6,4,4,8,9,6,9,7,15,19,11,11,10,15,9,16,6,11,16,17,10,15,14,8,5,8,12,12,3,13,17,16,7,12,7,8},
              solutions = 1, exhausted = false, nodes = 529 },
        }
        it("builds its sum tables on first use only, and release() drops them", function()
            Mod.release()
            assert.is_false(Mod.sumTablesBuilt())
            local lay = LAYOUTS[3]
            local cages = {}
            for id, sum in ipairs(lay.sums) do cages[id] = { id = id, sum = sum, cells = {} } end
            for r = 1, 9 do
                for c = 1, 9 do
                    local cells = cages[lay.cell_cage[r][c]].cells
                    cells[#cells + 1] = { r = r, c = c }
                end
            end
            local function count() return select(3, Mod._countCageSolutions(lay.cell_cage, cages, 9, 3, 3, 2, 6000)) end
            assert.are.equal(lay.nodes, count())
            assert.is_true(Mod.sumTablesBuilt())
            Mod.release()
            assert.is_false(Mod.sumTablesBuilt())
            assert.are.equal(lay.nodes, count())   -- rebuilt, same search
        end)

        for _, lay in ipairs(LAYOUTS) do
            it("explores the same tree as before: " .. lay.label, function()
                local cages = {}
                for id, sum in ipairs(lay.sums) do cages[id] = { id = id, sum = sum, cells = {} } end
                for r = 1, 9 do
                    for c = 1, 9 do
                        local cells = cages[lay.cell_cage[r][c]].cells
                        cells[#cells + 1] = { r = r, c = c }
                    end
                end
                local solutions, exhausted, nodes =
                    Mod._countCageSolutions(lay.cell_cage, cages, 9, 3, 3, 2, 6000)
                assert.are.equal(lay.solutions, solutions)
                assert.are.equal(lay.exhausted, exhausted)
                assert.are.equal(lay.nodes, nodes)
            end)
        end

        it("generates Hard and Expert grids quickly (1.6.0 took seconds each)", function()
            local t0 = os.clock()
            for seed = 1, 3 do
                math.randomseed(seed)
                KillerSudokuBoard:new():generate("hard")
                KillerSudokuBoard:new():generate("expert")
            end
            -- Generous: about 0.1 s under LuaJIT and 6 s under busted's Lua
            -- 5.5 with the bit shim; 1.6.0 needed ~18 s under LuaJIT alone.
            assert.is_true(os.clock() - t0 < 30)
        end)
    end)
end)
