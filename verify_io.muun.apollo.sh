#!/bin/bash
# verify_io.muun.apollo.sh v1.0.0 - Standalone verification script for Muun Wallet
# Usage: verify_io.muun.apollo.sh -a path/to/muun.apk [-r revisionOverride] [-n] [-c]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"
sleep 2
echo

# Global Constants
wsContainer="docker.io/walletscrutiny/android:5"
takeUserActionCommand='echo "CTRL-D to continue";
  bash'
shouldCleanup=false

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither Docker nor Podman found. Please install one of them."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Muun Wallet constants
repo="https://github.com/muun/apollo"

# Helper functions
containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")
  
  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  echo "Running apktool with $CONTAINER_CMD..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume $targetFolderParent:/tfp \
    --volume $appFolder:/af:ro \
    $wsContainer \
    sh -c "apktool d -f -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then
    echo -e "${RED}Container apktool failed${NC}"
    return 1
  fi
  return 0
}

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

usage() {
  echo 'NAME
       verify_io.muun.apollo.sh - verify Muun Wallet build

SYNOPSIS
       verify_io.muun.apollo.sh -a downloadedApk [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of Muun Wallet.

       -a|--apk The apk file we want to test.
       -r|--revision-override git revision id to use if tag is not found
       -n|--not-interactive The script will not ask for user actions
       -c|--cleanup Clean up temporary files after testing'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -a|--apk) downloadedApk="$2"; shift ;;
    -r|--revision-override) revisionOverride="$2"; shift ;;
    -n|--not-interactive) takeUserActionCommand='' ;;
    -c|--cleanup) shouldCleanup=true ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ ! -f "$downloadedApk" ]; then
  echo "APK file not found!"
  echo
  usage
  exit 1
fi

# Make path absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Extract APK metadata
appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
fromPlayFolder=/tmp/fromPlay$appHash
rm -rf $fromPlayFolder
signer=$(getSigner "$downloadedApk")
echo "Extracting APK content..."
containerApktool $fromPlayFolder "$downloadedApk" || exit 1

appId=$(cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g')
versionName=$(cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
versionCode=$(cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")
workDir=/tmp/test_$appId

# Validate metadata
if [ -z "$appId" ]; then
  echo "appId could not be determined"
  exit 1
fi

if [ -z "$versionName" ]; then
  echo "versionName could not be determined"
  exit 1
fi

if [ -z "$versionCode" ]; then
  echo "versionCode could not be determined"
  exit 1
fi

# Verify this is Muun Wallet
if [ "$appId" != "io.muun.apollo" ]; then
  echo "This script is only for Muun Wallet (io.muun.apollo)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="v$versionName"
builtApk="$workDir/app/apk/apolloui-prod-release-unsigned.apk"

prepare() {
  echo "Testing $appId from $repo revision $tag (revisionOverride: '$revisionOverride')..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # create work directory
  mkdir -p $workDir
  cd $workDir
  # clone
  echo "Cloning repository..."
  if [ -n "$revisionOverride" ]; then
    git clone --quiet $repo app && cd app && git checkout "$revisionOverride" || exit 1
  else
    git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  fi
  commit=$(git log -n 1 --pretty=oneline | sed 's/ .*//g')
}

test_muun() {
  echo "Starting Muun Wallet build process..."
  echo "This build uses Docker BuildKit and may take 15-30 minutes..."
  
  # Create output directory
  mkdir -p apk
  
  # Build using Docker BuildKit (must use docker, not podman for BuildKit)
  echo "Building APK with Docker BuildKit..."
  if ! DOCKER_BUILDKIT=1 docker build -f android/Dockerfile -o apk .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  # Copy the built APK to expected location
  mkdir -p $workDir/app/apk
  
  # Check for the expected APK file
  if [ -f "apk/apolloui-prod-arm64-v8a-release-unsigned.apk" ]; then
    cp apk/apolloui-prod-arm64-v8a-release-unsigned.apk $workDir/app/apk/apolloui-prod-release-unsigned.apk
    echo -e "${GREEN}APK copied successfully${NC}"
  else
    echo "Expected APK not found, checking available files:"
    ls -la apk/
    # Try to find any APK file and use the first one
    apk_file=$(ls apk/*.apk 2>/dev/null | head -1)
    if [ -n "$apk_file" ]; then
      echo "Using: $apk_file"
      cp "$apk_file" $workDir/app/apk/apolloui-prod-release-unsigned.apk
    else
      echo -e "${RED}No APK files found!${NC}"
      exit 1
    fi
  fi
  
  # Clean up Docker images
  docker image prune -f 2>/dev/null || true
  
  echo "Muun Wallet build completed successfully!"
  
  # Verify the built APK exists
  if [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Built APK found: $builtApk${NC}"
  echo "APK size: $(ls -lh "$builtApk" | awk '{print $5}')"
}

result() {
  echo "Setting up comparison..."
  fromPlayUnzipped=/tmp/fromPlay_${appId}_$versionCode
  fromBuildUnzipped=/tmp/fromBuild_${appId}_$versionCode
  rm -rf $fromBuildUnzipped $fromPlayUnzipped
  
  echo "Extracting APKs for comparison..."
  unzip -d $fromPlayUnzipped -qq "$downloadedApk" || exit 1
  unzip -d $fromBuildUnzipped -qq "$builtApk" || exit 1
  
  echo "Running diff comparison..."
  diffResult=$(diff --brief --recursive $fromPlayUnzipped $fromBuildUnzipped 2>/dev/null || true)
  diffCount=$(echo "$diffResult" | grep -vcE "(META-INF|^$)" || echo "0")

  # Analyze the differences
  if [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  elif [ "$diffCount" -eq 1 ] && echo "$diffResult" | grep -q "resources.arsc"; then
    # Special case: only resources.arsc differs (Firebase Crashlytics mapping ID)
    verdict="reproducible"
  else
    verdict=""
  fi

  diffGuide="
For detailed analysis, run:
diff --recursive $fromPlayUnzipped $fromBuildUnzipped
meld $fromPlayUnzipped $fromBuildUnzipped
diffoscope \"$downloadedApk\" \"$builtApk\""

  if [ "$shouldCleanup" = true ]; then
    diffGuide=''
  fi

  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $versionName"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "commit:         $commit"
  echo ""
  echo "Diff:"
  echo "$diffResult"
  echo ""
  echo "Differences found (excluding META-INF): $diffCount"

  # Check git signatures
  echo ""
  echo "Checking git signatures..."
  tagInfo=$(git for-each-ref "refs/tags/$tag")
  if [[ $tagInfo == *"tag"* ]]; then
    echo "Tag type: annotated"
    tagVerification=$(git tag -v "$tag" 2>&1) || true
    if [[ $tagVerification == *"Good signature"* ]]; then
      echo "✓ Good signature on annotated tag"
    else
      echo "⚠️ No valid signature found on annotated tag"
    fi
  else
    echo "Tag type: lightweight (cannot contain signature)"
  fi

  commitVerification=$(git verify-commit "$tag" 2>&1) || true
  if [[ $commitVerification == *"Good signature"* ]]; then
    echo "✓ Good signature on commit"
  else
    echo "⚠️ No valid signature found on commit"
  fi

  echo "===== End Results ====="
  echo "$diffGuide"
}

cleanup() {
  echo "Cleaning up..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  docker image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Muun Wallet verification..."
echo "This process may take 20-40 minutes depending on your system."
echo "Note: This build requires Docker (not Podman) for BuildKit support."
echo

prepare
echo "Repository prepared. Starting build..."

test_muun
echo "Build completed. Running comparison..."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Muun Wallet verification finished!"