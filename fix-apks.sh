#!/bin/bash

# Script to move APK files from temp to build directory
# This fixes the issue where APKs are built but not published

echo "Moving APK files from temp to build directory..."

# Create build directory if it doesn't exist
mkdir -p build

# Check if temp directory exists
if [ ! -d "temp" ]; then
    echo "ERROR: temp directory not found!"
    echo "Current directory contents:"
    ls -la
    exit 1
fi

# Find and move APK files from temp directory
APK_COUNT=0
while IFS= read -r -d '' apk; do
    if [ -f "$apk" ]; then
        echo "Moving: $(basename "$apk")"
        cp "$apk" build/
        APK_COUNT=$((APK_COUNT + 1))
    fi
done < <(find temp -name "*.apk" -type f -print0)

# Verify APK files were moved
FINAL_COUNT=$(find build -name "*.apk" -type f | wc -l)
echo "APK files moved successfully! Total APKs in build directory: $FINAL_COUNT"

if [ "$FINAL_COUNT" -eq 0 ]; then
    echo "WARNING: No APK files were found or moved!"
    echo "Temp directory contents:"
    ls -la temp/ 2>/dev/null || echo "Temp directory is empty or not accessible"
    echo "Build directory contents:"
    ls -la build/
fi

ls -la build/
