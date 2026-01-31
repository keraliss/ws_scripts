#!/bin/bash
# com.mycelium.wallet_build.sh v2.0.0 - Standardized verification script for Mycelium Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: com.mycelium.wallet_build.sh --apk APK_FILE

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

# Global Variables
SCRIPT_VERSION="v2.0.0"
BUILD_TYPE="apk"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
wsContainer="docker.io/walletscrutiny/android:5"

# Detect container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo "Error: Neither podman nor docker found. Please install one of them."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Mycelium Wallet constants
repo="https://github.com/mycelium-com/wallet-android"

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
       com.mycelium.wallet_build.sh - verify Mycelium Wallet build

SYNOPSIS
       com.mycelium.wallet_build.sh --apk APK_FILE

DESCRIPTION
       This command verifies builds of Mycelium Wallet.
       Version is automatically extracted from the APK.

       --apk       The apk file to test

EXAMPLES
       com.mycelium.wallet_build.sh --apk mycelium.apk
       com.mycelium.wallet_build.sh --apk /path/to/mycelium.apk'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --apk) downloadedApk="$2"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
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

# Verify this is Mycelium Wallet
if [ "$appId" != "com.mycelium.wallet" ]; then
  echo "This script is only for Mycelium Wallet (com.mycelium.wallet)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="v$versionName"
builtApk=$workDir/app/mbw/build/outputs/apk/prodnet/release/mbw-prodnet-release.apk

prepare() {
  echo "Testing $appId from $repo revision $tag..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # create work directory
  mkdir -p $workDir
  cd $workDir
  # clone
  echo "Cloning repository..."
  git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  commit=$(git log -n 1 --pretty=oneline | sed 's/ .*//g')
  echo -e "${GREEN}Environment prepared${NC}"
}

build_mycelium() {
  echo "Starting Mycelium Wallet build process..."
  
  cd "$workDir/app"
  
  # Apply hack to fetch submodules through https instead of ssh
  echo "Configuring submodules to use HTTPS instead of SSH..."
  sed -i 's/git@github.com:/https:\/\/github.com\//g' .gitmodules
  
  echo "Initializing and updating submodules..."
  git submodule update --init --recursive
  
  echo "Building Docker image for Mycelium Wallet..."
  echo "This may take several minutes..."
  
  # Build the Docker image using the repository's Dockerfile
  if ! $CONTAINER_CMD build --tag mycelium_builder .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Running container to complete build..."
  echo "This build process may take 10-30 minutes and requires disorderfs for reproducible builds..."
  
  # Run the container with the complex build command that includes disorderfs
  if ! $CONTAINER_CMD run \
    --rm \
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    --security-opt apparmor:unconfined \
    --volume $workDir/app:/app \
    mycelium_builder \
    bash -c "apt update && apt install -y disorderfs && mkdir /project/ && disorderfs --sort-dirents=yes --reverse-dirents=no /app/ /project/ && cd /project/ && ./gradlew -x lint -x test clean :mbw:assembleProdnetRelease"; then
    echo -e "${RED}Container build failed!${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Mycelium Wallet build completed successfully!${NC}"
  
  # Verify the built APK exists
  if [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
    echo "Checking build output directories:"
    find . -name "*.apk" -type f 2>/dev/null || echo "No APK files found"
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
  
  # Count non-META-INF differences
  if [ -z "$diffResult" ]; then
    diffCount=0
  else
    diffCount=$(echo "$diffResult" | grep -vE "(META-INF|^$)" | wc -l || echo "0")
  fi
  
  verdict=""
  if [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
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
  echo "===== End Results ====="

  write_results "$verdict" "$appHash" "$([ "$verdict" = "reproducible" ] && echo 'true' || echo 'false')"
}

write_results() {
  local status=$1
  local hash=$2
  local match=$3
  
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")
  
  cat > "$RESULTS_FILE" << EOF
date: ${timestamp}
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: android
    firmware_type: prodnet
    files:
      - filename: mbw-prodnet-release.apk
        hash: ${hash}
        match: ${match}
        expected_hash: ${hash}
        status: ${status}
        signer: ${signer}
        app_id: ${appId}
        version_name: ${versionName}
        version_code: ${versionCode}
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

cleanup() {
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rmi mycelium_builder -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Mycelium Wallet verification..."
echo "This process may take 15-45 minutes depending on your system."
echo "Note: This build requires FUSE support and privileged container access for disorderfs."
echo

prepare
echo "Repository prepared. Starting build..."

build_mycelium
echo "Build completed. Running comparison..."

result
echo "Verification completed."

cleanup

echo
echo "Mycelium Wallet verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."