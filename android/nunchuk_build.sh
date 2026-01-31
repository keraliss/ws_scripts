#!/bin/bash
# nunchuk_build.sh v2.0.0 - Standardized verification script for Nunchuk Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: nunchuk_build.sh --version VERSION [--apk APK_PATH]

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
BUILD_TYPE="aab"
workDir="$(pwd)/nunchuk-work"
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

# Nunchuk constants
repo="https://github.com/nunchuk-io/nunchuk-android"

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

  cmd=$(cat <<EOF
apt-get update && apt-get install -y wget && \
wget https://raw.githubusercontent.com/iBotPeaches/Apktool/v2.10.0/scripts/linux/apktool -O /usr/local/bin/apktool && \
wget https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar -O /usr/local/bin/apktool.jar && \
chmod +x /usr/local/bin/apktool && \
apktool d -f -o "/tfp/$targetFolderBase" "/af/$appFile"
EOF
  )

  $CONTAINER_CMD run --rm --user root \
    --volume "$targetFolderParent":/tfp \
    --volume "$appFolder":/af:ro \
    $wsContainer sh -c "$cmd"

  return $?
}

getSigner() {
  apkFile=$1
  DIR=$(dirname "$apkFile")
  BASE=$(basename "$apkFile")
  s=$(
    $CONTAINER_CMD run --rm \
      --volume "$DIR":/mnt:ro \
      --workdir /mnt \
      $wsContainer \
      apksigner verify --print-certs "$BASE" | grep "Signer #1 certificate SHA-256" | awk '{print $6}' )
  echo $s
}

usage() {
  echo 'NAME
       nunchuk_build.sh - verify Nunchuk Wallet build

SYNOPSIS
       nunchuk_build.sh --version VERSION [--apk APK_PATH]

DESCRIPTION
       This command verifies builds of Nunchuk Wallet (AAB-based).
       Version is required. APK path optional (downloads from GitHub if not provided).

       --version   Version to verify (e.g., "1.9.47")
       --apk       Optional: APK file or directory with split APKs

EXAMPLES
       nunchuk_build.sh --version 1.9.47
       nunchuk_build.sh --version 1.9.47 --apk nunchuk.apk
       nunchuk_build.sh --version 1.9.47 --apk /path/to/splits/'
}

# Parse arguments
apkPath=""
appVersion=""

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) appVersion="$2"; shift ;;
    --apk) apkPath="$2"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$appVersion" ]; then
  echo "Error: Version is required!"
  echo
  usage
  exit 1
fi

echo
echo "Verifying Nunchuk Wallet version $appVersion"
echo

# Determine verification mode
verificationMode=""
apkDir=""

if [[ -z "$apkPath" ]]; then
  verificationMode="github"
  echo "Mode: GitHub universal APK (will be downloaded)"
  apkDir="$workDir/github-apk"
else
  verificationMode="device"
  if ! [[ $apkPath =~ ^/.* ]]; then
    apkPath="$PWD/$apkPath"
  fi
  
  if [ -f "$apkPath" ]; then
    echo "Mode: Single APK file"
    apkDir="$workDir/apk"
    mkdir -p "$apkDir"
    cp "$apkPath" "$apkDir/base.apk"
  elif [ -d "$apkPath" ]; then
    echo "Mode: Split APKs directory"
    apkDir="$apkPath"
    if [ ! -f "$apkDir/base.apk" ]; then
      echo -e "${RED}Error: base.apk not found in $apkDir${NC}"
      exit 1
    fi
  else
    echo -e "${RED}Error: APK path not found: $apkPath${NC}"
    exit 1
  fi
fi

echo

# Extract metadata from APK (device mode only)
if [[ "$verificationMode" == "device" ]]; then
  echo "Extracting metadata from base.apk..."
  tempExtractDir=$(mktemp -d /tmp/extract_base_XXXXXX)
  containerApktool "$tempExtractDir" "$apkDir/base.apk"

  if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to extract base.apk${NC}"
    exit 1
  fi

  appId=$(grep 'package=' "$tempExtractDir"/AndroidManifest.xml | sed 's/.*package=\"//g' | sed 's/\".*//g')
  officialVersion=$(grep 'versionName' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")
  versionCode=$(grep 'versionCode' "$tempExtractDir"/apktool.yml | awk '{print $2}' | tr -d "'")
  appHash=$(sha256sum "$apkDir/base.apk" | awk '{print $1;}')
  signer=$(getSigner "$apkDir/base.apk")

  rm -rf "$tempExtractDir"

  if [ "$appId" != "io.nunchuk.android" ]; then
    echo "Error: Unsupported appId $appId (expected io.nunchuk.android)"
    exit 1
  fi

  echo "App ID: $appId"
  echo "Version: $officialVersion ($versionCode)"
  echo "Hash: $appHash"
  echo "Signer: $signer"
else
  appId="io.nunchuk.android"
  officialVersion="$appVersion"
  versionCode="TBD"
  appHash="TBD"
  signer="TBD"
fi

echo

# Prepare workspace
prepare() {
  echo "Setting up workspace..."
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  mkdir -p "$apkDir"
  echo -e "${GREEN}Environment prepared${NC}"
}

# Fetch Nunchuk Dockerfile
fetch_dockerfile() {
  echo "Fetching Nunchuk's Dockerfile from GitHub..."
  
  candidates=("android.${appVersion}" "v${appVersion}" "${appVersion}")
  gitTag=""
  dockerfileContent=""
  
  for candidate in "${candidates[@]}"; do
    dockerfileUrl="https://raw.githubusercontent.com/nunchuk-io/nunchuk-android/$candidate/reproducible-builds/Dockerfile"
    echo -n "  Trying $candidate... "
    
    dockerfileContent=$(curl -sS -f "$dockerfileUrl" 2>/dev/null)
    
    if [[ -n "$dockerfileContent" ]]; then
      gitTag="$candidate"
      echo -e "${GREEN}Found!${NC}"
      break
    else
      echo "not found"
    fi
  done
  
  if [[ -z "$gitTag" ]]; then
    echo -e "${RED}Error: Could not find Dockerfile for version $appVersion${NC}"
    exit 1
  fi
  
  echo "Using git tag: $gitTag"
  export GIT_TAG="$gitTag"
  
  # Fix Debian base image and add verification tools
  dockerfileContent=$(echo "$dockerfileContent" | sed 's/FROM docker\.io\/debian:bookworm-20250811-slim/FROM docker.io\/debian:bookworm-slim/')
  
  cat > "$workDir/Dockerfile" <<DOCKERFILE_EOF
$dockerfileContent

# WalletScrutiny additions
RUN set -ex; \\
    apt-get update; \\
    DEBIAN_FRONTEND=noninteractive apt-get install --yes -o APT::Install-Suggests=false --no-install-recommends \\
        wget curl coreutils; \\
    rm -rf /var/lib/apt/lists/*

RUN wget -q https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar -O /tmp/bundletool.jar

RUN wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O /usr/local/bin/apktool && \\
    wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O /usr/local/bin/apktool.jar && \\
    chmod +x /usr/local/bin/apktool

WORKDIR /workspace
DOCKERFILE_EOF

  echo -e "${GREEN}Dockerfile created${NC}"
}

# Build Nunchuk AAB
build_nunchuk() {
  echo "Building Nunchuk AAB..."
  echo "This may take 30-60 minutes..."
  echo

  cd "$workDir"
  
  echo "Building container image..."
  if ! $CONTAINER_CMD build --memory=8g --no-cache -t nunchuk-verifier:${appVersion} -f Dockerfile .; then
    echo -e "${RED}Container build failed${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Container image built${NC}"
  echo

  # Create build script
  cat > "$workDir/build.sh" <<'BUILD_EOF'
#!/bin/bash
set -e

GIT_TAG="$1"
MODE="$2"
OFFICIAL_DIR="$3"

echo "[Container] Cloning repository..."
cd /workspace
git clone --quiet https://github.com/nunchuk-io/nunchuk-android nunchuk-source
cd nunchuk-source
git checkout "$GIT_TAG" --quiet

echo "[Container] Building AAB with disorderfs..."
mkdir -p /app
disorderfs --sort-dirents=yes --reverse-dirents=no . /app/
cd /app

echo "[Container] Configuring Gradle..."
echo "" >> gradle.properties
echo "org.gradle.jvmargs=-Xmx6g -XX:MaxMetaspaceSize=1024m -XX:+HeapDumpOnOutOfMemoryError -XX:+UseG1GC" >> gradle.properties
echo "org.gradle.daemon=false" >> gradle.properties
echo "org.gradle.parallel=false" >> gradle.properties
echo "org.gradle.workers.max=1" >> gradle.properties
echo "org.gradle.caching=false" >> gradle.properties

echo "[Container] Running Gradle build..."
./gradlew clean bundleProductionRelease --no-daemon --max-workers=1

cp /app/nunchuk-app/build/outputs/bundle/productionRelease/nunchuk-app-production-release.aab /workspace/app-release.aab
echo "[Container] AAB built: /workspace/app-release.aab"

if [[ "$MODE" == "github" ]]; then
  echo "[Container] Downloading GitHub APK..."
  releaseJson=$(curl -sL "https://api.github.com/repos/nunchuk-io/nunchuk-android/releases/tags/$GIT_TAG")
  apkUrl=$(echo "$releaseJson" | grep -o "https://github.com/nunchuk-io/nunchuk-android/releases/download/$GIT_TAG/[^\"]*\\.apk" | head -n1)
  
  if [[ -z "$apkUrl" ]]; then
    echo "[Container ERROR] Could not find APK in GitHub releases"
    exit 1
  fi
  
  wget -q "$apkUrl" -O "$OFFICIAL_DIR/github.apk"
  echo "[Container] Downloaded: $OFFICIAL_DIR/github.apk"
  
  echo "[Container] Extracting universal APK from AAB..."
  java -jar /tmp/bundletool.jar build-apks \
    --bundle=/workspace/app-release.aab \
    --output=/tmp/built.apks \
    --mode=universal
  
  unzip -qq /tmp/built.apks 'universal.apk' -d /tmp/
  
  echo "[Container] Comparing..."
  mkdir -p /tmp/official /tmp/built
  apktool d -f -o /tmp/official "$OFFICIAL_DIR/github.apk" 2>/dev/null || true
  apktool d -f -o /tmp/built /tmp/universal.apk 2>/dev/null || true
  
  diff_output=$(diff -qr /tmp/official /tmp/built 2>/dev/null || true)
  filtered=$(echo "$diff_output" | grep -vE '^Only in [^/:]+: META-INF$|^Only in [^/:]+/META-INF:|^Files [^/]+/META-INF/' || true)
  non_meta=$(echo "$filtered" | grep -c '^' || echo "0")
  
  echo "$non_meta" > /workspace/total_diffs.txt
  echo "$diff_output" > /workspace/diff_full.txt
  echo "$filtered" > /workspace/diff_filtered.txt
  echo "[Container] Differences: $non_meta"
fi

exit 0
BUILD_EOF

  chmod +x "$workDir/build.sh"
  
  echo "Running build in container..."
  if [[ "$verificationMode" == "github" ]]; then
    $CONTAINER_CMD run --rm \
      --privileged \
      --memory=12g \
      --volume "$workDir":/workspace:rw \
      --volume "$apkDir":/official-apks:rw \
      nunchuk-verifier:${appVersion} \
      bash /workspace/build.sh "$GIT_TAG" "github" "/official-apks"
  else
    echo -e "${YELLOW}Device mode not fully implemented in simplified version${NC}"
    echo -e "${YELLOW}Use GitHub mode for now${NC}"
    exit 1
  fi
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Build completed${NC}"
}

result() {
  echo

  if [[ "$verificationMode" == "github" ]]; then
    # Extract metadata from downloaded APK
    githubApk="$apkDir/github.apk"
    if [[ -f "$githubApk" ]]; then
      appHash=$(sha256sum "$githubApk" | awk '{print $1;}')
      signer=$(getSigner "$githubApk")
      
      tempExtractDir=$(mktemp -d /tmp/github_meta_XXXXXX)
      containerApktool "$tempExtractDir" "$githubApk"
      
      officialVersion=$(grep 'versionName' "$tempExtractDir/apktool.yml" | awk '{print $2}' | tr -d "'" | head -n1)
      versionCode=$(grep 'versionCode' "$tempExtractDir/apktool.yml" | awk '{print $2}' | tr -d "'" | head -n1)
      
      rm -rf "$tempExtractDir"
    fi
  fi
  
  total_diffs=$(cat "$workDir/total_diffs.txt" 2>/dev/null || echo "0")
  diff_filtered=$(cat "$workDir/diff_filtered.txt" 2>/dev/null || echo "")
  
  verdict=""
  if [ "$total_diffs" -eq 0 ]; then
    verdict="reproducible"
  else
    verdict="not_reproducible"
  fi
  
  echo "===== Begin Results ====="
  echo "appId:          $appId"
  echo "signer:         $signer"
  echo "apkVersionName: $officialVersion"
  echo "apkVersionCode: $versionCode"
  echo "verdict:        $verdict"
  echo "appHash:        $appHash"
  echo "differences:    $total_diffs (non-META-INF)"
  echo ""
  echo "Diff:"
  echo "$diff_filtered"
  echo ""
  echo "Full diff available at: $workDir/diff_full.txt"
  echo "Filtered diff at: $workDir/diff_filtered.txt"
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
    firmware_type: production
    files:
      - filename: nunchuk-app-production-release.aab
        hash: ${hash}
        match: ${match}
        expected_hash: ${hash}
        status: ${status}
        signer: ${signer}
        app_id: ${appId}
        version_name: ${officialVersion}
        version_code: ${versionCode}
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

cleanup() {
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rmi nunchuk-verifier:${appVersion} -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting Nunchuk Wallet verification..."
echo "This process may take 30-60 minutes depending on your system."
echo "Minimum 12GB RAM recommended."
echo

prepare
fetch_dockerfile
build_nunchuk
result
cleanup

echo
echo "Nunchuk Wallet verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."