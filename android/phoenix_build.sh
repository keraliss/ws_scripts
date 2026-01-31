#!/bin/bash
# phoenix_build.sh v2.0.0 - Standardized verification script for Phoenix Lightning Network wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: phoenix_build.sh --version VERSION --apk APK_FILE

set -e

# Display disclaimer at start of script
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Running this script grants it access to your"
echo "system and may modify files."
echo "Use at your own risk and ensure you understand what the script does before"
echo "execution."
echo "=============================================================================="
echo -e "\033[0m"
sleep 2
echo

# Global Constants
SCRIPT_VERSION="v2.0.0"
BUILD_TYPE="apk"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
wsContainer="docker.io/walletscrutiny/android:5"

# Detect available container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
else
    echo -e "${RED}Error: Neither podman nor docker found. Please install one of them.${NC}"
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m' # No Color

# Phoenix specific constants
repo="https://github.com/ACINQ/phoenix"

# Helper functions
containerApktool() {
  targetFolder=$1
  app=$2
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")
  
  # Check if APK file exists and is readable
  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  # Run apktool in a container so apktool doesn't need to be installed.
  echo "Running apktool with $CONTAINER_CMD..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume $targetFolderParent:/tfp \
    --volume $appFolder:/af:ro \
    $wsContainer \
    sh -c "apktool d -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then

    echo -e "${RED}Container apktool failed. This might be due to storage issues.${NC}"
    if [ "$CONTAINER_CMD" = "podman" ]; then
      echo -e "${YELLOW}Try running: podman system reset --force${NC}"
    elif [ "$CONTAINER_CMD" = "docker" ]; then
      echo -e "${YELLOW}Try running: docker system prune -f${NC}"
    fi
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
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256"  | awk '{print $6}' )
  echo $s
}

usage() {
  echo 'NAME
       phoenix_build.sh - verify Phoenix Lightning Network wallet build

SYNOPSIS
       phoenix_build.sh --apk APK_FILE

DESCRIPTION
       This command verifies builds of Phoenix Lightning Network wallet.
       Version is automatically extracted from the APK.

       --apk       The apk file to test

EXAMPLES
       phoenix_build.sh --apk phoenix.apk
       phoenix_build.sh --apk /path/to/phoenix.apk'
}

# Read script arguments and flags
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
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

# make sure path is absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Extract APK metadata
appHash=$(sha256sum "$downloadedApk" | awk '{print $1;}')
fromPlayFolder=/tmp/fromPlay$appHash
rm -rf $fromPlayFolder
signer=$( getSigner "$downloadedApk" )
echo "Extracting APK content ..."
containerApktool $fromPlayFolder "$downloadedApk" || exit 1
appId=$( cat $fromPlayFolder/AndroidManifest.xml | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g' )
versionName=$( cat $fromPlayFolder/apktool.yml | grep versionName | sed 's/.*\: //g' | sed "s/'//g" )
versionCode=$( cat $fromPlayFolder/apktool.yml | grep versionCode | sed 's/.*\: //g' | sed "s/'//g" )
workDir=/tmp/test_$appId

# Validate extracted metadata
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

# Verify this is Phoenix
if [ "$appId" != "fr.acinq.phoenix.mainnet" ]; then
  echo "This script is only for Phoenix Lightning Network wallet (fr.acinq.phoenix.mainnet)"
  echo "Detected appId: $appId"
  exit 1
fi

echo
echo "Testing \"$downloadedApk\" ($appId version $versionName)"
echo

# Phoenix specific logic
tag="android-v$versionName"
builtApk="$workDir/app/phoenix-android/build/outputs/apk/release/phoenix-$versionCode-$versionName-mainnet-release.apk"

prepare() {
  echo "Testing $appId from $repo revision $tag..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # get unique folder
  mkdir -p $workDir
  cd $workDir
  # clone
  echo "Trying to clone …"
  git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  commit=$( git log -n 1 --pretty=oneline | sed 's/ .*//g' )
  echo -e "${GREEN}Environment prepared${NC}"
}

test_phoenix() {
  echo "Starting Phoenix build process..."
  
  # Phoenix specific build logic
  echo "Checking out Dockerfile from master branch..."
  git checkout origin/master Dockerfile || {
    echo -e "${YELLOW}Warning: Could not checkout Dockerfile from master, using existing version${NC}"
  }
  
  echo "Building Phoenix Docker image..."
  echo "This may take several minutes..."
  
  if ! $CONTAINER_CMD build -t phoenix_build .; then
    echo -e "${RED}Docker build failed!${NC}"
    exit 1
  fi
  
  echo "Running Phoenix build in container..."
  
  if ! $CONTAINER_CMD run -it --rm --volume $PWD:/home/ubuntu/phoenix \
      --workdir /home/ubuntu/phoenix phoenix_build \
      bash -x -c "./gradlew :phoenix-android:assemble"; then
    echo -e "${RED}Phoenix build failed!${NC}"
    exit 1
  fi
  
  echo "Cleaning up Docker images..."
  $CONTAINER_CMD image prune -f
  
  echo -e "${GREEN}Phoenix build completed!${NC}"
  
  # Verify the built APK exists
  if [ ! -f "$builtApk" ]; then
    echo -e "${RED}Error: Built APK not found at expected location: $builtApk${NC}"
    echo "Checking build outputs directory:"
    find phoenix-android/build/outputs/apk/ -name "*.apk" 2>/dev/null || echo "No APK files found in build outputs"
    exit 1
  fi
  
  echo -e "${GREEN}Built APK found: $builtApk${NC}"
  echo "APK size: $(ls -lh "$builtApk" | awk '{print $5}')"
}

result() {
  set +x
  echo "Setting up comparison directories..."
  # collect results
  fromPlayUnzipped=/tmp/fromPlay_${appId}_$versionCode
  fromBuildUnzipped=/tmp/fromBuild_${appId}_$versionCode
  rm -rf $fromBuildUnzipped $fromPlayUnzipped
  
  echo "Extracting downloaded APK for comparison..."
  if ! unzip -d $fromPlayUnzipped -qq "$downloadedApk"; then
    echo -e "${RED}Failed to extract downloaded APK${NC}"
    exit 1
  fi
  
  echo "Extracting built APK for comparison..."
  if ! unzip -d $fromBuildUnzipped -qq "$builtApk"; then
    echo -e "${RED}Failed to extract built APK${NC}"
    exit 1
  fi
  
  echo "Running diff comparison..."
  diffResult=$( diff --brief --recursive $fromPlayUnzipped $fromBuildUnzipped 2>/dev/null || true )
  
  # Count non-META-INF differences
  if [ -z "$diffResult" ]; then
    diffCount=0
  else
    diffCount=$( echo "$diffResult" | grep -vE "(META-INF|^$)" | wc -l || echo "0" )
  fi
  
  verdict=""
  if [ "$diffCount" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
  fi

  echo "===== Begin Results =====
appId:          $appId
signer:         $signer
apkVersionName: $versionName
apkVersionCode: $versionCode
verdict:        $verdict
appHash:        $appHash
commit:         $commit

Diff:
$diffResult

===== End Results ====="

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
    firmware_type: mainnet
    files:
      - filename: phoenix-${versionCode}-${versionName}-mainnet-release.apk
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
  $CONTAINER_CMD rmi phoenix_build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Phoenix Lightning Network wallet verification process..."
echo "This process may take 10-30 minutes depending on your system."
echo

prepare
echo "Preparation completed. Starting build..."

test_phoenix
echo "Build completed. Starting comparison..."

result
echo "Comparison completed."

cleanup

echo
echo "Phoenix verification completed!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."