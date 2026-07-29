# Changelog

All notable changes to this project will be documented in this file.

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
