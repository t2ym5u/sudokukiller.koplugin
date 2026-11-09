# sudokukiller.koplugin

A Killer Sudoku plugin for [KOReader](https://github.com/koreader/koreader).

## Screenshot

![Screenshot](images/killer-sudoku.png)

## Rules

Standard Sudoku rules (fill 1–9; no repeats in rows, columns, or 3×3 boxes) plus **cage constraints**: cells are grouped into cages, each labelled with a target sum. The digits in each cage must add up to that sum with no repeats within the cage.

## Features

- **Four difficulty levels** — Easy, Medium, Hard and Expert
- **Hint** — two taps: the first says which cell is about to give, the second fills it. Works on every level, since every grid is solvable by deduction alone
- **Cage highlighting** — tapping a caged cell highlights the whole cage
- **Note mode** — pencil in candidate digits
- **Check** — highlights incorrect cells
- **Reveal solution** — shows the full solution
- **Undo** — step back through your moves
- **Auto-save** — game state saved and restored on next launch

## Installation

1. Download `sudokukiller.koplugin.zip` from the [latest release](../../releases/latest).
2. Extract into the `plugins/` folder of your KOReader data directory.
3. Restart KOReader.
4. Open the menu → **Tools** → **Killer Sudoku**.

## Controls

| Action | How |
|--------|-----|
| Select a cell | Tap it |
| Enter a digit | Tap the digit button |
| Erase a cell | Tap **Erase** |
| Toggle note mode | Tap **Note: Off / On** |
| Undo last move | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change difficulty | Tap **Difficulty** |
| Show rules | Tap **Rules** |

## How the levels differ

Every grid has one solution and is solvable by deduction alone (no
guessing): the generator adds given digits until it is. It also caps how
much cage reasoning a grid asks for — working out which digits fit a cage,
or the 45 rule — and the rest is plain singles:

| Level | Largest cage | Cage reasoning steps (at most) | Given digits (about) |
|---|---|---|---|
| Easy | 3 cells | 3 | 22 |
| Medium | 5 cells | 8 | 20 |
| Hard | 5 cells | 16 | 17 |
| Expert | 5 cells | 24 | 14 |

Unlike a book Killer, Hard and Expert show a few given digits: random cages
alone almost never decide the grid, so without them these levels needed
guessing and some grids had two solutions.

## License

GPL-3.0 — see [LICENSE](LICENSE).
