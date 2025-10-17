#!/bin/bash
set -e

echo "Building Flash Mobile in Docker..."

# Create output directory
mkdir -p output

# Build Docker image
echo "Building Docker image..."
docker build -t flash-mobile-builder .

# Run container to build APK
echo "Running build in container..."
docker run --rm \
    -v "$(pwd)/output:/output" \
    flash-mobile-builder

echo "Build complete. Check output/ directory for APK."