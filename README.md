# Claude Usage Tracker

A lightweight macOS menu bar app to monitor your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage in real-time.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## Features

- **Real-time Rate Limit Monitoring** - Track your 5-hour and 7-day usage limits
- **Live Session Tracking** - See all active Claude Code sessions with token counts
- **Usage Statistics** - View messages, sessions, and tool calls over configurable time periods
- **Model Breakdown** - See token usage by model (Opus, Sonnet, Haiku)
- **Activity Trends** - Visual chart showing your usage patterns
- **Cost Estimation** - Track estimated costs for API and Bedrock usage
- **Menu Bar Integration** - Unobtrusive menu bar icon with optional usage percentage

## Screenshots

*Menu bar view showing rate limits, live sessions, and usage statistics*

## Requirements

- macOS 13.0 (Ventura) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed

## Installation

### Option 1: Download Pre-built App (Recommended)

1. Go to the [Releases](../../releases) page
2. Download the latest `ClaudeUsageTracker.zip`
3. Unzip the file
4. Move `ClaudeUsageTracker.app` to your `/Applications` folder
5. Right-click the app and select **Open** (required first time for unsigned apps)

### Option 2: Build from Source

```bash
# Clone the repository
git clone https://github.com/rui-branco/claude-usage-tracker.git
cd ClaudeUsageTracker

# Build and create app bundle
./scripts/build-release.sh

# Move to Applications
mv ClaudeUsageTracker.app /Applications/
```

### Option 3: Run with Swift

```bash
# Clone and run directly
git clone https://github.com/rui-branco/claude-usage-tracker.git
cd ClaudeUsageTracker
swift run
```

## Usage

Once installed, the app runs in your menu bar. Click the icon to see:

- **Rate Limits** - Your current usage against 5-hour and 7-day limits
- **Live Sessions** - Active Claude Code sessions with project names
- **Period Stats** - Token usage, messages, sessions, and tool calls
- **Model Usage** - Breakdown by Claude model
- **Activity Trend** - Visual chart of recent activity

### Settings

Click the gear icon to customize:

- Show/hide menu bar percentage
- Enable/disable auto-refresh
- Toggle individual sections

## How It Works

Claude Usage Tracker reads data from Claude Code's local configuration and cache files:

- `~/.claude/config.json` - Project sessions and token usage
- `~/.claude/.stats_cache.json` - Aggregated usage statistics
- `~/.claude/.rate_limit_cache.json` - Current rate limit status

The app monitors these files for changes and updates the display automatically.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- Built with SwiftUI for macOS
- Designed for use with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
