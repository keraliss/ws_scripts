#!/bin/bash
# com.greenaddress.greenbits_android_wallet_build.sh v2.0.0 - Standardized verification script for Blockstream Green
# Follows WalletScrutiny reproducible verification standards
# Usage: com.greenaddress.greenbits_android_wallet_build.sh --apk APK_FILE

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
workDir="$(pwd)/blockstream-green-work"
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

# Blockstream Green constants
repo="https://github.com/Blockstream/green_android/"
appId="com.greenaddress.greenbits_android_wallet"

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
  if ! $CONTAINER_CMD run --rm \
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
    $CONTAINER_CMD run --rm \
      --volume $DIR:/mnt:ro \
      --workdir /mnt \
      $wsContainer \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256" | awk '{print $6}' )
  echo $s
}

usage() {
  echo 'NAME
       com.greenaddress.greenbits_android_wallet_build.sh - verify Blockstream Green build

SYNOPSIS
       com.greenaddress.greenbits_android_wallet_build.sh --apk APK_FILE

DESCRIPTION
       This command verifies builds of Blockstream Green wallet.
       Version is automatically extracted from the APK.

       --apk       The apk file to test

EXAMPLES
       com.greenaddress.greenbits_android_wallet_build.sh --apk green.apk
       com.greenaddress.greenbits_android_wallet_build.sh --apk /path/to/green.apk'
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

extractedAppId=$(cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g')
versionName=$(cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
versionCode=$(cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")

# Validate metadata
if [ -z "$extractedAppId" ]; then
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

# Verify this is Blockstream Green
if [ "$extractedAppId" != "$appId" ]; then
  echo "This script is only for Blockstream Green (com.greenaddress.greenbits_android_wallet)"
  echo "Detected appId: $extractedAppId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Set up build variables
tag="release_$versionName"
builtApk="$workDir/app/androidApp/build/outputs/apk/productionGoogle/release/BlockstreamGreen-v${versionName}-productionGoogle-release-unsigned.apk"

prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Cloning repository..."
  git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  commit=$(git log -n 1 --pretty=oneline | sed 's/ .*//g')
  
  echo -e "${GREEN}Environment prepared${NC}"
}

build_green() {
  echo "Starting Blockstream Green build process..."
  
  cd "$workDir/app"
  
  echo "Running containerized build with Blockstream keys..."
  echo "This may take 10-30 minutes..."
  
  if ! $CONTAINER_CMD run --rm \
    --volume "$PWD:/mnt" \
    $wsContainer \
    bash -x -c "chmod 777 /tmp/;
      cd /mnt;
      apt update;
      DEBIAN_FRONTEND=noninteractive apt install -y curl jq openjdk-17-jdk;
      yes | /opt/android-sdk/tools/bin/sdkmanager \"build-tools;34.0.0\";
      ./gradlew useBlockstreamKeys;
      ./gradlew -x test clean assembleProductionGoogleRelease"; then
    echo -e "${RED}Container build failed!${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Blockstream Green build completed successfully!${NC}"
  
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
  
  # Filter out META-INF, stamp-cert-sha256, AndroidManifest.xml
  filteredDiff=$(echo "$diffResult" | grep -vE "(META-INF|stamp-cert-sha256|AndroidManifest\.xml)" || true)
  
  # Count remaining differences
  if [ -z "$filteredDiff" ]; then
    diffCount=0
  else
    diffCount=$(echo "$filteredDiff" | grep -c '^' || echo "0")
  fi
  
  verdict=""
  if [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
  fi

  builtHash=$(sha256sum "$builtApk" | awk '{print $1}')

  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $versionName"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "builtHash:      $builtHash"
  echo "commit:         $commit"
  echo ""
  echo "Diff (excluding META-INF, stamp-cert-sha256, AndroidManifest.xml):"
  if [ -n "$filteredDiff" ]; then
    echo "$filteredDiff"
  else
    echo "(no differences)"
  fi
  echo ""
  echo "Differences found: $diffCount"
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
    firmware_type: productionGoogle
    files:
      - filename: BlockstreamGreen-v${versionName}-productionGoogle-release.apk
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
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Blockstream Green verification..."
echo "This process may take 15-45 minutes depending on your system."
echo

prepare
echo "Repository prepared. Starting build..."

build_green
echo "Build completed. Running comparison..."

result
echo "Verification completed."

cleanup

echo
echo "Blockstream Green verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."