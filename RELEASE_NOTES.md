### Usage by model (with Fable 5)

The popover now has a **Usage by model** section showing all-time token totals per Claude model — sourced from `~/.claude/stats-cache.json` — so **Fable 5** usage (and every other model you've run) is finally visible at a glance. Previously the widget only showed rate limits and live sessions, so per-model usage was tracked but never displayed.

- New "USAGE BY MODEL" card lists each model with a colored dot, name, and token total, sorted by usage (Fable 5 shown in pink)
- `formatModelName` now resolves the exact version — Opus 4.5/4.6/4.7/4.8, Sonnet 4.5/4.6, Haiku 4.5, Fable 5 — instead of collapsing every Opus to "Opus 4.5"
- Token counts now format billions (e.g. `4.9B tok`) instead of overflowing the millions unit
- Fable 5 pricing added to the cost estimator ($10/MTok input, $50/MTok output, ~$1/MTok cache read)
