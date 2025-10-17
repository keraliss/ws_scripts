#!/bin/bash
# verify_phoenix.sh v1.0.0 - Standalone verification script for Phoenix Lightning Network wallet
# Combines functionality from test.sh and phoenix build logic
# Usage: verify_phoenix.sh -a path/to/phoenix.apk [-r revisionOverride] [-n] [-c]

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
# ================
wsContainer="docker.io/walletscrutiny/android:5"
takeUserActionCommand='echo "CTRL-D to continue";
  bash'
shouldCleanup=false

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
# ===============

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
       verify_phoenix.sh - verify Phoenix Lightning Network wallet build

SYNOPSIS
       verify_phoenix.sh -a downloadedApk [-r revisionOverride] [-n] [-c]

DESCRIPTION
       This command tries to verify builds of Phoenix Lightning Network wallet.

       -a|--apk The apk file we want to test.
       -r|--revision-override git revision id to use if tag is not found
       -n|--not-interactive The script will not ask for user actions
       -c|--cleanup Clean up temporary files after testing'
}

# Read script arguments and flags
# ===============================

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

# make sure path is absolute
if ! [[ $downloadedApk =~ ^/.* ]]; then
  downloadedApk="$PWD/$downloadedApk"
fi

# Extract APK metadata
# ===================

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
# =====================

tag="android-v$versionName"
builtApk="$workDir/app/phoenix-android/build/outputs/apk/release/phoenix-$versionCode-$versionName-mainnet-release.apk"

prepare() {
  echo "Testing $appId from $repo revision $tag (revisionOverride: '$revisionOverride')..."
  # cleanup
  rm -rf "$workDir" || exit 1
  # get unique folder
  mkdir -p $workDir
  cd $workDir
  # clone
  echo "Trying to clone …"
  if [ -n "$revisionOverride" ]
  then
    git clone --quiet $repo app && cd app && git checkout "$revisionOverride" || exit 1
  else
    git clone --quiet --branch "$tag" --depth 1 $repo app && cd app || exit 1
  fi
  commit=$( git log -n 1 --pretty=oneline | sed 's/ .*//g' )
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
  echo "Note: Build may pause for user input if compilation needs fixing..."
  
  if ! $CONTAINER_CMD run -it --rm --volume $PWD:/home/ubuntu/phoenix \
      --workdir /home/ubuntu/phoenix phoenix_build \
      bash -x -c "./gradlew :phoenix-android:assemble;
      $takeUserActionCommand"; then
    echo -e "${RED}Phoenix build failed!${NC}"
    exit 1
  fi
  
  echo "Cleaning up Docker images..."
  $CONTAINER_CMD image prune -f
  
  echo "Phoenix build completed!"
  
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
  diffCount=$( echo "$diffResult" | grep -vcE "(META-INF|^$)" || echo "0" )
  verdict=""
  if ((diffCount == 0)); then
    verdict="reproducible"
  fi

  diffGuide="
Run a full
diff --recursive $fromPlayUnzipped $fromBuildUnzipped
meld $fromPlayUnzipped $fromBuildUnzipped
or
diffoscope \"$downloadedApk\" $builtApk
for more details."
  if [ "$shouldCleanup" = true ]; then
    diffGuide=''
  fi
  if [ "$additionalInfo" ]; then
    additionalInfo="===== Also ====
$additionalInfo
"
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

Revision, tag (and its signature):"

  # Determine if tag is annotated or lightweight
  tagInfo=$(git for-each-ref "refs/tags/$tag")
  isAnnotatedTag=false
  tagType="lightweight"
  if [[ $tagInfo == *"tag"* ]]; then
    isAnnotatedTag=true
    tagType="annotated"
  fi

  # Check signatures
  signatureWarnings=""
  tagSignatureStatus=""
  commitSignatureStatus=""
  signatureKeys=""

  # Try to verify tag signature (will work for annotated tags)
  if $isAnnotatedTag; then
    tagVerification=$(git tag -v "$tag" 2>&1) || true
    echo "$tagVerification"

    if [[ $tagVerification == *"Good signature"* ]]; then
      tagSignatureStatus="✓ Good signature on annotated tag"
      # Extract signing key
      tagKey=$(echo "$tagVerification" | grep "using .* key" | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)
      if [[ ! -z "$tagKey" ]]; then
        signatureKeys="Tag signed with: $tagKey"
      fi
    else
      tagSignatureStatus="⚠️ No valid signature found on annotated tag"
      signatureWarnings="$signatureWarnings\n- Annotated tag exists but is not signed"
    fi
  else
    tagSignatureStatus="ℹ️ Tag is lightweight (cannot contain signature)"
  fi

  # Try to verify commit signature
  commitObj="$tag"
  if $isAnnotatedTag; then
    # For annotated tags, we need to get the commit it points to
    commitObj="$tag^{commit}"
  fi

  commitVerification=$(git verify-commit "$commitObj" 2>&1) || true
  if [[ $commitVerification == *"Good signature"* ]]; then
    commitSignatureStatus="✓ Good signature on commit"
    # Extract signing key
    commitKey=$(echo "$commitVerification" | grep "using .* key" | sed -E 's/.*using .* key ([A-F0-9]+).*/\1/' | tail -1)
    if [[ ! -z "$commitKey" ]]; then
      if [[ ! -z "$signatureKeys" ]]; then
        signatureKeys="$signatureKeys\nCommit signed with: $commitKey"
      else
        signatureKeys="Commit signed with: $commitKey"
      fi

      # Compare keys if both tag and commit are signed
      if [[ ! -z "$tagKey" && ! -z "$commitKey" && "$tagKey" != "$commitKey" ]]; then
        signatureWarnings="$signatureWarnings\n- Tag and commit signed with different keys"
      fi
    fi
  else
    commitSignatureStatus="⚠️ No valid signature found on commit"
    if [[ -z "$signatureWarnings" ]]; then
      signatureWarnings="- Commit is not signed"
    else
      signatureWarnings="$signatureWarnings\n- Commit is not signed"
    fi
  fi

  # Output the signature summary
  echo "
Signature Summary:
Tag type: $tagType
$tagSignatureStatus
$commitSignatureStatus"

  if [[ ! -z "$signatureKeys" ]]; then
    echo -e "\nKeys used:
$signatureKeys"
  fi

  if [[ ! -z "$signatureWarnings" ]]; then
    echo -e "\nWarnings:$signatureWarnings"
  fi

  echo -e "\n$additionalInfo===== End Results =====
$diffGuide"
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf $fromPlayFolder $workDir $fromBuildUnzipped $fromPlayUnzipped
  # Additional container cleanup
  $CONTAINER_CMD rmi phoenix_build -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
# =============

echo "Starting Phoenix Lightning Network wallet verification process..."
echo "This process may take 10-30 minutes depending on your system."
echo

prepare
echo "Preparation completed. Starting build..."

test_phoenix
echo "Build completed. Starting comparison..."

result
echo "Comparison completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "Phoenix verification completed!"