#!/bin/bash

# =============================================================================
# Muun Wallet APK Reproducibility Verification Script
# =============================================================================
# SECURITY WARNING: This script downloads and executes code. Please review
# the contents before running.
#
# Usage: ./reproduce_muun_standalone.sh -a /path/to/muun.apk
# =============================================================================

set -e

# Constants
repo="https://github.com/muun/apollo"
wsContainer="docker.io/walletscrutiny/android:5"

# Variables
downloadedApk=""
shouldCleanup=false

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo "Error: Neither Docker nor Podman found. Please install one of them."
    exit 1
fi

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--apk) downloadedApk="$2"; shift ;;
        -c|--cleanup) shouldCleanup=true ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

# Validate APK
if [ ! -f "$downloadedApk" ]; then
    echo "APK file not found: $downloadedApk"
    exit 1
fi

# Make path absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
    downloadedApk="$PWD/$downloadedApk"
fi

# Generate work directory
appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
fromPlayFolder=/tmp/fromPlay$appHash
workDir=/tmp/test_muun_$appHash

echo "Starting Muun verification..."
echo "APK: $downloadedApk"
echo "Work directory: $workDir"

# Extract APK using containerized apktool
containerApktool() {
    targetFolder=$1
    app=$2
    targetFolderParent=$(dirname "$targetFolder")
    targetFolderBase=$(basename "$targetFolder")
    appFolder=$(dirname "$app")
    appFile=$(basename "$app")
    
    $CONTAINER_CMD run \
        --rm \
        --volume $targetFolderParent:/tfp \
        --volume $appFolder:/af:ro \
        $wsContainer \
        sh -c "apktool d -f -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""
}

# Get signer
getSigner() {
    DIR=$(dirname "$1")
    BASE=$(basename "$1")
    s=$(
        $CONTAINER_CMD run \
            --rm \
            --volume $DIR:/mnt:ro \
            --workdir /mnt \
            $wsContainer \
            apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256" | awk '{print $6}' )
    echo $s
}

# Extract APK info
rm -rf $fromPlayFolder
signer=$( getSigner "$downloadedApk" )
echo "Extracting APK content..."
containerApktool $fromPlayFolder "$downloadedApk" || exit 1

appId=$( cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g' )
versionName=$( cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g" )
versionCode=$( cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g" )

echo "App ID: $appId"
echo "Version Name: $versionName"
echo "Version Code: $versionCode"

# Muun-specific build logic
tag=v$versionName
builtApk=$workDir/app/apk/apolloui-prod-release-unsigned.apk

echo "Testing $appId from $repo revision $tag..."

# Cleanup and setup
rm -rf "$workDir" || exit 1
mkdir -p $workDir
cd $workDir

# Clone
echo "Cloning repository..."
git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
commit=$( git log -n 1 --pretty=oneline | sed 's/ .*//g' )

# Build (the working Muun build logic)
echo "Building APK..."
mkdir apk

# Use docker directly as in the original working script
DOCKER_BUILDKIT=1 docker build -f android/Dockerfile -o apk .

# Copy the built APK to where comparison expects it
mkdir -p $workDir/app/apk

# Check if the expected APK file exists
if [ -f "apk/apolloui-prod-arm64-v8a-release-unsigned.apk" ]; then
    cp apk/apolloui-prod-arm64-v8a-release-unsigned.apk $workDir/app/apk/apolloui-prod-release-unsigned.apk
    echo "APK copied successfully"
else
    echo "Expected APK not found, checking available files:"
    ls -la apk/
    # Try to find any APK file and use the first one
    apk_file=$(ls apk/*.apk 2>/dev/null | head -1)
    if [ -n "$apk_file" ]; then
        echo "Using: $apk_file"
        cp "$apk_file" $workDir/app/apk/apolloui-prod-release-unsigned.apk
    else
        echo "No APK files found!"
        exit 1
    fi
fi

docker image prune -f

echo "Build completed!"

# Continue with comparison
cd "$workDir"
echo "Starting comparison phase..."

# Compare results (from test.sh)
echo "Setting up comparison directories..."
fromPlayUnzipped=/tmp/fromPlay_${appId}_$versionCode
fromBuildUnzipped=/tmp/fromBuild_${appId}_$versionCode

echo "Extracting APKs for comparison..."
rm -rf $fromBuildUnzipped $fromPlayUnzipped
unzip -d $fromPlayUnzipped -qq "$downloadedApk" || exit 1
unzip -d $fromBuildUnzipped -qq "$builtApk" || exit 1

echo "Running diff comparison..."
diffResult=$( diff --brief --recursive $fromPlayUnzipped $fromBuildUnzipped 2>/dev/null || true )
diffCount=$( echo "$diffResult" | grep -vcE "(META-INF|^$)" || echo "0" )

echo "Generating results..."

# Results
echo "=================================================================="
echo "                    MUUN VERIFICATION RESULTS"
echo "=================================================================="
echo "appId:          $appId"
echo "signer:         $signer"
echo "apkVersionName: $versionName"
echo "apkVersionCode: $versionCode"
echo "appHash:        $appHash"
echo "commit:         $commit"
echo ""
echo "Diff:"
echo "$diffResult"
echo ""
echo "Differences found: $diffCount"

if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "For detailed analysis, run:"
    echo "diff --recursive $fromPlayUnzipped $fromBuildUnzipped"
    echo "diffoscope \"$downloadedApk\" \"$builtApk\""
else
    echo "Cleaning up..."
    rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
fi

echo "=================================================================="