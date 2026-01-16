# Installation Guide

## Quick Install (Download)

### Step 1: Download
Go to [Releases](../../releases) and download `ClaudeUsageTracker.zip`

### Step 2: Unzip
Double-click the zip file to extract `ClaudeUsageTracker.app`

### Step 3: Move to Applications
Drag `ClaudeUsageTracker.app` to your `/Applications` folder

### Step 4: Allow the App
Since the app is not signed with an Apple Developer certificate, macOS will block it. Run this command in Terminal:

```bash
xattr -cr /Applications/ClaudeUsageTracker.app
```

Then open the app normally from Applications.

### Step 5: Launch at Login (Optional)
To start the app automatically when you log in:

1. Open **System Settings** > **General** > **Login Items**
2. Click the **+** button
3. Navigate to `/Applications` and select `ClaudeUsageTracker.app`
4. Click **Add**

---

## Build from Source

### Prerequisites
- macOS 13.0 or later
- Xcode Command Line Tools (`xcode-select --install`)

### Build Steps

```bash
# 1. Clone the repository
git clone https://github.com/rui-branco/claude-usage-tracker.git
cd ClaudeUsageTracker

# 2. Build the release
./scripts/build-release.sh

# 3. Install to Applications
mv ClaudeUsageTracker.app /Applications/

# 4. Open the app (first time)
open /Applications/ClaudeUsageTracker.app
```

---

## Troubleshooting

### "App is damaged and can't be opened"
This happens due to macOS Gatekeeper. Run:
```bash
xattr -cr /Applications/ClaudeUsageTracker.app
```

### App doesn't appear in menu bar
1. Check that Claude Code is installed and has been used at least once
2. Ensure `~/.claude/` directory exists
3. Try quitting and reopening the app

### No data showing
The app reads from Claude Code's cache files. Make sure:
1. You have used Claude Code at least once
2. The files exist in `~/.claude/`:
   - `config.json`
   - `.stats_cache.json`

### Building fails
Ensure you have the latest Xcode Command Line Tools:
```bash
xcode-select --install
```

---

## Uninstall

1. Quit the app from the menu bar (Click icon → Quit)
2. Delete `/Applications/ClaudeUsageTracker.app`
3. Optionally remove preferences:
   ```bash
   defaults delete com.github.ClaudeUsageTracker
   ```
