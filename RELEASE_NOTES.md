### Fable 5 support

The tracker now recognizes Anthropic's Fable 5 model (`claude-fable-5`) everywhere it already knew Opus, Sonnet, and Haiku.

- Live session rows show **Fable 5** (in pink) instead of the raw `claude-fable-5` model ID when Claude Code's session cache doesn't provide a friendly display name
- Added Fable 5 to the model name/color helpers used by the per-model token breakdown
- Added Fable 5 pricing to the cost estimator ($10/MTok input, $50/MTok output, ~$1/MTok cache read → ~$1.90/MTok blended input)
