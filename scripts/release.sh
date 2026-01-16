#!/bin/bash
set -e

# Release script for Claude Usage Tracker
# Usage: ./scripts/release.sh 1.3.1 "Release notes here"
# Or:    ./scripts/release.sh 1.3.1 -f release-notes.md

VERSION=$1
NOTES_ARG=$2
NOTES_FILE=$3

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh <version> [notes or -f <file>]"
    echo "Examples:"
    echo "  ./scripts/release.sh 1.3.1 \"Fix pricing calculation\""
    echo "  ./scripts/release.sh 1.3.1 -f RELEASE_NOTES.md"
    exit 1
fi

# Get release notes
WHATS_NEW=""
if [ "$NOTES_ARG" = "-f" ] && [ -f "$NOTES_FILE" ]; then
    WHATS_NEW=$(cat "$NOTES_FILE")
elif [ -f "RELEASE_NOTES.md" ]; then
    WHATS_NEW=$(cat "RELEASE_NOTES.md")
elif [ -n "$NOTES_ARG" ]; then
    WHATS_NEW="- $NOTES_ARG"
fi

echo "🚀 Releasing v$VERSION..."

# Update version in Info.plist
sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string>/<string>$VERSION<\/string>/g" Info.plist
echo "✅ Updated Info.plist to v$VERSION"

# Build release (incremental, no clean)
swift build -c release
echo "✅ Built release"

# Create app bundle
rm -rf ClaudeUsageTracker.app
mkdir -p ClaudeUsageTracker.app/Contents/MacOS
mkdir -p ClaudeUsageTracker.app/Contents/Resources
cp .build/release/ClaudeUsageTracker ClaudeUsageTracker.app/Contents/MacOS/
cp Info.plist ClaudeUsageTracker.app/Contents/
cp Sources/ClaudeUsageTracker/Resources/AppIcon.icns ClaudeUsageTracker.app/Contents/Resources/
cp -r .build/release/ClaudeUsageTracker_ClaudeUsageTracker.bundle ClaudeUsageTracker.app/Contents/Resources/
echo -n "APPL????" > ClaudeUsageTracker.app/Contents/PkgInfo
echo "✅ Created app bundle"

# Create zip
rm -f ClaudeUsageTracker.zip
zip -r ClaudeUsageTracker.zip ClaudeUsageTracker.app
echo "✅ Created zip"

# Git commit and tag
git add -A
git commit -m "chore: bump version to $VERSION" || true
git push

# Build release notes
RELEASE_NOTES="## What's New

$WHATS_NEW

## Installation

1. Download \`ClaudeUsageTracker.zip\` below
2. Move \`ClaudeUsageTracker.app\` to \`/Applications\`
3. Run: \`xattr -cr /Applications/ClaudeUsageTracker.app\`
4. Open the app

## Requirements
- macOS 13.0 (Ventura) or later"

# Create GitHub release
gh release create "v$VERSION" ClaudeUsageTracker.zip \
  --title "Claude Usage Tracker v$VERSION" \
  --notes "$RELEASE_NOTES"

echo ""
echo "🎉 Released v$VERSION!"
echo "https://github.com/rui-branco/claude-usage-tracker/releases/tag/v$VERSION"
