### Gemini support

- Track Gemini CLI usage alongside Claude and Codex in the same menu bar icon
- Real rate-limit gauge per model, fetched from Google's quota API using the OAuth token in `~/.gemini/oauth_creds.json`
- Gemini % shown in **blue** in the menu bar label, next to Claude (orange) and Codex (green)
- Live Gemini sessions surfaced in the same list as Claude/Codex (project, model, token total, memory)
- Sessions read from `~/.gemini/tmp/<project>/chats/session-*.jsonl`
- New Settings toggles: "Include Gemini %" (menu bar) and Gemini rate-limits / sessions visibility

Gemini's quotas reset daily (per model), unlike Claude's 5h+weekly or Codex's primary+weekly windows — that's expected, the API only exposes daily buckets.
