### Energy fix

macOS was flagging the app as "Using Significant Energy" because the Codex, Gemini, and live-Claude scanners were doing heavy work on a 5-second loop. This release fixes that without changing any visible behavior — the menu-bar label and popover data still refresh at the same cadence.

- Caches parsed Codex/Gemini session JSONL by `(path, mtime, size)` — unchanged session files are no longer re-read and re-decoded on every tick (was the dominant CPU cost when you had any active sessions)
- Replaces every `lsof -p <pid>` subprocess with a direct `proc_pidinfo` syscall to read each session's working directory — no more per-scan subprocess spawning across three scanners
- Throttles the Claude live-sessions and Gemini session scanners to 30s while the popover is closed, back to 5s the moment you open it (an immediate refresh fires on open so the data is fresh by the time you see it). Codex stays on 5s because it publishes the menu-bar % directly.
- Removes a dead 1-second focus-detection timer that was defined but never started.
