#!/bin/bash
# org.electrum.electrum_build.sh v2.0.0 - Standardized verification script for Electrum Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: org.electrum.electrum_build.sh --apk APK_FILE

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
workDir="$(pwd)/electrum-work"
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
    echo "Error: Neither podman nor docker found. Please install Docker or Podman."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Electrum constants
repo="https://github.com/spesmilo/electrum"
appId="org.electrum.electrum"

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

determine_architectures() {
  local apk="$1"
  local output

  if command -v aapt >/dev/null 2>&1; then
    output=$(aapt dump badging "$apk" 2>/dev/null || true)
  else
    local apk_dir apk_name
    apk_dir="$(dirname "$apk")"
    apk_name="$(basename "$apk")"
    output=$($CONTAINER_CMD run --rm --volume "$apk_dir":/apk:ro $wsContainer \
      sh -c "aapt dump badging /apk/$apk_name" 2>/dev/null || true)
  fi

  if [[ -z "$output" ]]; then
    echo "armeabi-v7a"  # Default
    return 0
  fi

  awk -F"'" '/native-code/ {for (i=2; i<=NF; i+=2) print $i}' <<<"$output" | head -1 || echo "armeabi-v7a"
}

usage() {
  echo 'NAME
       org.electrum.electrum_build.sh - verify Electrum wallet build

SYNOPSIS
       org.electrum.electrum_build.sh --apk APK_FILE

DESCRIPTION
       This command verifies builds of Electrum wallet.
       Version is automatically extracted from the APK.

       --apk       The apk file to test

EXAMPLES
       org.electrum.electrum_build.sh --apk electrum.apk
       org.electrum.electrum_build.sh --apk /path/to/electrum.apk'
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

# Verify this is Electrum
if [ "$extractedAppId" != "$appId" ]; then
  echo "This script is only for Electrum wallet (org.electrum.electrum)"
  echo "Detected appId: $extractedAppId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Detect architecture
build_arch=$(determine_architectures "$downloadedApk")
echo "Detected architecture: $build_arch"

# Determine tag
tag="$versionName"
if [[ "$versionName" =~ ^(.+)\.0$ ]]; then
  tag="${BASH_REMATCH[1]}"
fi

builtApk="$workDir/app/dist/Electrum-$versionName-$build_arch-release-unsigned.apk"

prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Cloning repository..."
  git clone --quiet --recurse-submodules $repo app
  cd app
  
  echo "Checking out version: $tag"
  git fetch --quiet --tags
  git checkout --quiet "refs/tags/$tag" || git checkout --quiet "$tag"
  git submodule update --init --recursive
  
  commit=$(git rev-parse HEAD)
  echo -e "${GREEN}Environment prepared${NC}"
}

build_electrum() {
  echo "Building Electrum from source..."
  
  cd "$workDir/app"
  
  if [ ! -f contrib/android/Dockerfile ]; then
    echo -e "${RED}Missing contrib/android/Dockerfile${NC}"
    exit 1
  fi
  
  cp contrib/deterministic-build/requirements-build-android.txt contrib/android/ || true
  
  # Always use UID 1000 for container to avoid conflicts
  uid=1000
  gid=1000
  
  echo "Building Docker image..."
  if ! $CONTAINER_CMD build \
    --tag electrum-android:local \
    --file contrib/android/Dockerfile \
    --build-arg UID="$uid" \
    --build-arg GID="$gid" \
    .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  mkdir -p "$workDir/app/.gradle"
  mkdir -p "$workDir/app/dist"
  chmod -R 777 "$workDir/app/dist" 2>/dev/null || true
  
  echo "Starting containerized build for architecture: $build_arch"
  echo "This may take 15-30 minutes..."
  
  if ! $CONTAINER_CMD run --rm \
    --user root \
    --env GIT_PAGER=cat \
    --env PAGER=cat \
    --env VIRTUAL_ENV=/opt/venv \
    --env PATH="/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --env BUILDOZER_WARN_ON_ROOT=0 \
    --volume "$workDir/app:/home/user/wspace/electrum" \
    --volume "$workDir/app/.gradle:/home/user/.gradle" \
    --workdir /home/user/wspace/electrum \
    electrum-android:local \
    bash -lc "set -x && \
      source /opt/venv/bin/activate && \
      git config --global --add safe.directory /home/user/wspace/electrum && \
      mkdir -p dist && \
      chmod +x contrib/android/make_apk.sh && \
      ./contrib/android/make_apk.sh qml '$build_arch' release-unsigned"; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Build completed successfully!${NC}"
  
  # Find built APK - try multiple locations
  echo "Searching for built APK..."
  
  # First try the expected location
  if [ -f "$builtApk" ]; then
    echo "Found APK at expected location: $builtApk"
  else
    # Search in buildozer output directories
    builtApk=$(find "$workDir/app/.buildozer" -type f -name "*Electrum*${build_arch}*release*.apk" -o -name "*electrum*${build_arch}*release*.apk" 2>/dev/null | head -1)
    
    if [ -z "$builtApk" ]; then
      # Search more broadly for any arm64 APK
      builtApk=$(find "$workDir/app/.buildozer" -type f -name "*${build_arch}*.apk" 2>/dev/null | grep -i electrum | head -1)
    fi
    
    if [ -z "$builtApk" ]; then
      # Last resort: search for any APK in dist directories
      builtApk=$(find "$workDir/app/.buildozer/android/platform/build-${build_arch}/dists" -type f -name "*.apk" 2>/dev/null | head -1)
    fi
    
    if [ -z "$builtApk" ]; then
      # Ultimate fallback: any APK anywhere
      builtApk=$(find "$workDir/app" -type f -name "*.apk" 2>/dev/null | head -1)
    fi
  fi
  
  if [ -z "$builtApk" ] || [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found${NC}"
    echo "Checking build outputs:"
    find "$workDir/app" -name "*.apk" -type f 2>/dev/null || echo "No APK files found"
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
  echo "architecture:   $build_arch"
  echo ""
  echo "Diff:"
  if [ -n "$diffResult" ]; then
    echo "$diffResult" | grep -vE "META-INF" || echo "(all differences were in META-INF)"
  else
    echo "(no differences)"
  fi
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
  - architecture: ${build_arch}
    firmware_type: release
    files:
      - filename: Electrum-${versionName}-${build_arch}-release.apk
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
  $CONTAINER_CMD rmi electrum-android:local -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Electrum wallet verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Repository prepared. Starting build..."

build_electrum
echo "Build completed. Running comparison..."

result
echo "Verification completed."

cleanup

echo
echo "Electrum verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."