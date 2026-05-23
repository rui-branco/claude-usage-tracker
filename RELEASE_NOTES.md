### Antigravity quota + no more keychain prompt

The rate-limit section was showing a stale model list at 0% across the board because it was hitting the old Gemini Code Assist quota endpoint. This release switches to the same `fetchAvailableModels` endpoint Antigravity itself uses, so the popover now mirrors the tiers shown in `agy`'s Model Quota view (3.5 Flash High/Medium, 3.1 Pro High/Low, Claude Sonnet/Opus, GPT-OSS).

- Calls `cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` with the `User-Agent: antigravity` header that unlocks the curated quota data
- Groups by display name, shows only the effort-tiered variants, hides tiers with no usage so the section disappears entirely when nothing's active
- Reads the Antigravity OAuth token via the `/usr/bin/security` CLI instead of `SecItemCopyMatching` — macOS no longer pops up a keychain access prompt on launch (same approach the Claude credentials path already used)
- Renames the popover section label from GEMINI to ANTIGRAVITY and adds the `agy` Go binary to the live-process scanner
