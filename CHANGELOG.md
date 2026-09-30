# Changelog

All notable changes to this project will be documented in this file.

## [1.2.19] - 2026-09-30

### Fixed
- The shared game UI now speaks French (and Spanish/German) again. Its strings
  were going straight to KOReader's gettext, which knows none of them, so
  messages like "Hide result to keep playing." stayed English whatever the
  device language.
- README claimed three difficulty levels; there have been four for a while.

### Note
- No **Hint** button here, unlike the other sudoku variants. A killer grid's
  information lives in its cage sums, which the shared logic solver does not
  model: classic deduction places under 1 of the 65-80 empty cells before
  stalling. The pure-deduction guarantee added to the other variants likewise
  does not apply, since this plugin has its own cage-based generator.

## [1.2.11] - 2026-07-29

### Fixed
- Easy and Medium puzzles could end up solvable only by guesswork —
  cage-sum constraints alone rarely produce a layout that a human can
  actually work through with standard deduction techniques (naked/hidden
  singles, cage-sum combos, the 45-rule). Added a human-solvability
  check plus a handful of deliberate "given" cage cells to guarantee
  Easy/Medium puzzles are solvable by deduction alone within a bounded
  retry budget. Hard and Expert are unchanged — guessing is still a
  normal part of solving those tiers.
