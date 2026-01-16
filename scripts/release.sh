#!/bin/bash
set -e

# Release script for Claude Usage Tracker
# Usage: ./scripts/release.sh 1.3.1

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh <version>"
    echo "Example: ./scripts/release.sh 1.3.1"
    exit 1
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

# Create GitHub release
gh release create "v$VERSION" ClaudeUsageTracker.zip \
  --title "Claude Usage Tracker v$VERSION" \
  --notes "## Installation

1. Download \`ClaudeUsageTracker.zip\` below
2. Unzip the file
3. Move \`ClaudeUsageTracker.app\` to \`/Applications\`
4. Run this command in Terminal:
   \`\`\`
   xattr -cr /Applications/ClaudeUsageTracker.app
   \`\`\`
5. Open the app

## Requirements
- macOS 13.0 (Ventura) or later"

echo ""
echo "🎉 Released v$VERSION!"
echo "https://github.com/rui-branco/claude-usage-tracker/releases/tag/v$VERSION"
