#!/bin/bash
# verify_io.hexawallet.bitcoinkeeper.sh v1.0.0 - Standalone verification script for Bitcoin Keeper
# Usage: verify_io.hexawallet.bitcoinkeeper.sh -a path/to/keeper.apk [-r revisionOverride] [-n] [-c]

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

# Bitcoin Keeper constants
repo="https://github.com/bithyve/bitcoin-keeper.git"

# Create Dockerfile content
create_dockerfile() {
  cat > keeper.dockerfile << 'EOF'
FROM node:18-slim

ARG TAG
ARG VERSION
ARG UID=1000

# Install dependencies
RUN apt-get update && \
    apt-get install -y \
    git \
    wget \
    unzip \
    openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

# Install Android SDK
ENV ANDROID_HOME=/opt/android-sdk
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd ${ANDROID_HOME}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-7583922_latest.zip && \
    unzip commandlinetools-linux-7583922_latest.zip && \
    rm commandlinetools-linux-7583922_latest.zip && \
    yes | cmdline-tools/bin/sdkmanager --sdk_root=${ANDROID_HOME} --licenses && \
    cmdline-tools/bin/sdkmanager --sdk_root=${ANDROID_HOME} "build-tools;33.0.0" "platforms;android-33"

ENV PATH="${ANDROID_HOME}/cmdline-tools/bin:${ANDROID_HOME}/build-tools/33.0.0:${PATH}"

# Clone and build
WORKDIR /app
RUN git clone --branch ${TAG} --depth 1 https://github.com/bithyve/bitcoin-keeper.git . && \
    yarn install --frozen-lockfile && \
    cd android && \
    ./gradlew assembleProductionRelease --no-daemon
EOF
}

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
    sh -c "apktool d -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then
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
       verify_io.hexawallet.bitcoinkeeper.sh - verify Bitcoin Keeper build

SYNOPSIS
       verify_io.hexawallet.bitcoinkeeper.sh -a downloadedApk [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of Bitcoin Keeper wallet.

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

# Verify this is Bitcoin Keeper
if [ "$appId" != "io.hexawallet.bitcoinkeeper" ]; then
  echo "This script is only for Bitcoin Keeper (io.hexawallet.bitcoinkeeper)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="v$versionName"
builtApk="$workDir/app-production-release.apk"

prepare() {
  echo "Testing $appId from $repo revision $tag (revisionOverride: '$revisionOverride')..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # create work directory
  mkdir -p $workDir
  cd $workDir
  
  # Note: We don't clone here because the Dockerfile does it
  # Just prepare the working directory
  commit=""  # Will be determined after build
}

test_keeper() {
  echo "Starting Bitcoin Keeper build process..."
  echo "This build uses Docker and may take 20-40 minutes..."
  
  # Create Dockerfile
  echo "Creating Dockerfile..."
  create_dockerfile
  
  # Cleanup any existing images
  echo "Cleaning up old Docker images..."
  $CONTAINER_CMD rmi bitcoin-keeper-builder -f 2>/dev/null || true
  
  # Determine tag to use
  local build_tag="$tag"
  if [ -n "$revisionOverride" ]; then
    build_tag="$revisionOverride"
  fi
  
  echo "Building Docker image for Bitcoin Keeper..."
  echo "Using tag: $build_tag"
  
  if ! $CONTAINER_CMD build \
    --tag bitcoin-keeper-builder \
    --build-arg UID=$(id -u) \
    --build-arg TAG="$build_tag" \
    --build-arg VERSION="$versionCode" \
    --file keeper.dockerfile .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Extracting built APK from container..."
  if ! $CONTAINER_CMD run \
    --volume "$workDir":/mnt \
    --rm \
    -u root \
    bitcoin-keeper-builder \
    bash -c 'find /app -name "*.apk" -type f | xargs -I {} cp {} /mnt/'; then
    echo -e "${RED}Failed to extract APK from container!${NC}"
    exit 1
  fi
  
  # Find the copied APK
  local found_apk=$(find "$workDir" -name "*.apk" -type f | head -1)
  if [ -z "$found_apk" ]; then
    echo -e "${RED}No APK found in build output!${NC}"
    exit 1
  fi
  
  # Move/rename to expected location
  mv "$found_apk" "$builtApk"
  
  # Get commit hash from the container
  commit=$($CONTAINER_CMD run --rm bitcoin-keeper-builder git rev-parse HEAD 2>/dev/null || echo "unknown")
  
  # Cleanup Docker resources
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rmi bitcoin-keeper-builder -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
  
  echo "Bitcoin Keeper build completed successfully!"
  
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
  diffCount=$(echo "$diffResult" | grep -vcE "(META-INF|^$)" 2>/dev/null || echo "0")

  if [[ "$diffCount" =~ ^[0-9]+$ ]] && [ "$diffCount" -eq 0 ]; then
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

  # Check git signatures (if we have a local clone)
  if [ -d "$workDir/bitcoin-keeper" ]; then
    cd "$workDir/bitcoin-keeper"
    echo ""
    echo "Checking git signatures..."
    tagInfo=$(git for-each-ref "refs/tags/$tag" 2>/dev/null || true)
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
  fi

  echo "===== End Results ====="
  echo "$diffGuide"
}

cleanup() {
  echo "Cleaning up..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  # Cleanup Docker resources
  $CONTAINER_CMD rmi bitcoin-keeper-builder -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
  # Remove temporary Dockerfile
  rm -f keeper.dockerfile
}

# Main execution
echo "Starting Bitcoin Keeper verification..."
echo "This process may take 30-50 minutes depending on your system."
echo

prepare
echo "Environment prepared. Starting build..."

test_keeper
echo "Build completed. Running comparison..."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Bitcoin Keeper verification finished!"