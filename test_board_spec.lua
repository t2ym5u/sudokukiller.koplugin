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
end)
