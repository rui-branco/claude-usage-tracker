### Gemini polish

- Real per-model Gemini quota: the app now sends a GCP project ID with the quota request so Google returns actual usage instead of placeholder fractions (previously stuck at 0% even with active usage)
- Hides model bars at 0% to remove noise — only models you've actually hit are shown
- Deduplicates pooled models: `gemini-2.5-pro`, `gemini-3-pro-preview`, and `gemini-3.1-pro-preview` share the same quota pool, now collapsed into one bar labelled with the newest variant
- Reset display switched from countdown (`23h 22m`) to clock time (`TMR 21:36`) — much easier to read for daily-reset quotas
- Real brand logos (Claude / Codex / Gemini) replace the colored dots in the Rate Limits header and the Live Sessions rows
