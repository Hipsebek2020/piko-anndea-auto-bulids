#!/bin/bash

# Script to move APK files from temp to build directory
# This fixes the issue where APKs are built but not published

echo "Moving APK files from temp to build directory..."

# Create build directory if it doesn't exist
mkdir -p build

# Find and move APK files from temp directory
find temp -name "*.apk" -type f | while read apk; do
    if [ -f "$apk" ]; then
        echo "Moving: $(basename "$apk")"
        cp "$apk" build/
    fi
done

echo "APK files moved successfully!"
ls -la build/
