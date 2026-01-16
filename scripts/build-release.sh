#!/bin/bash

# Claude Usage Tracker - Release Build Script
# This script builds the app and creates a distributable .app bundle

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building Claude Usage Tracker...${NC}"

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Clean previous build
echo -e "${YELLOW}Cleaning previous builds...${NC}"
rm -rf .build/release
rm -rf "ClaudeUsageTracker.app"
rm -f "ClaudeUsageTracker.zip"

# Build release binary
echo -e "${YELLOW}Building release binary...${NC}"
swift build -c release

# Create app bundle structure
echo -e "${YELLOW}Creating app bundle...${NC}"
APP_BUNDLE="ClaudeUsageTracker.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp .build/release/ClaudeUsageTracker "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy app icon
cp Sources/ClaudeUsageTracker/Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Copy resources bundle (contains pricing.json, icons, etc.)
cp -r .build/release/ClaudeUsageTracker_ClaudeUsageTracker.bundle "$APP_BUNDLE/Contents/Resources/"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Create zip for distribution
echo -e "${YELLOW}Creating distribution archive...${NC}"
zip -r "ClaudeUsageTracker.zip" "$APP_BUNDLE"

# Get file sizes
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
ZIP_SIZE=$(du -sh "ClaudeUsageTracker.zip" | cut -f1)

echo ""
echo -e "${GREEN}Build completed successfully!${NC}"
echo ""
echo "Output files:"
echo "  - $APP_BUNDLE ($APP_SIZE)"
echo "  - ClaudeUsageTracker.zip ($ZIP_SIZE)"
echo ""
echo -e "${YELLOW}To install:${NC}"
echo "  1. Unzip ClaudeUsageTracker.zip"
echo "  2. Move ClaudeUsageTracker.app to /Applications"
echo "  3. Right-click and select 'Open' (first time only)"
echo ""
echo -e "${YELLOW}To upload to GitHub Releases:${NC}"
echo "  1. Create a new release on GitHub"
echo "  2. Upload ClaudeUsageTracker.zip as a release asset"
