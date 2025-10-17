#!/bin/bash
repo=https://github.com/spesmilo/electrum
tag=$( echo "$versionName" | sed 's/\.0$//g' )

# Function to determine the APK architecture
determine_architecture() {
  APK_PATH=$1
  aapt dump badging "$APK_PATH" | grep native-code | awk -F"'" '{print $2}'
}

test() {
  # Determine the architecture of the provided APK
  apk_arch=$(determine_architecture "$downloadedApk")
  echo -e "\e[1;36mDetermined APK Architecture: $apk_arch\e[0m"
  
  if [ -z "$apk_arch" ]; then
    echo -e "\e[1;36mError: Unable to determine APK architecture\e[0m"
    exit 1
  fi
  
  # Create temporary directory for electrum
  ELECTRUM_DIR="$workDir/electrum_repo"
  
  echo -e "\e[1;36mSetting up Electrum repository at $ELECTRUM_DIR\e[0m"
  
  # Remove existing directory to start fresh
  if [ -d "$ELECTRUM_DIR" ]; then
    echo -e "\e[1;36mRemoving existing repository for fresh clone\e[0m"
    rm -rf "$ELECTRUM_DIR"
  fi
  
  # Clone the repository fresh
  echo -e "\e[1;36mCloning Electrum repository\e[0m"
  git clone --recurse-submodules "$repo" "$ELECTRUM_DIR"
  cd "$ELECTRUM_DIR"
  
  # Checkout the correct tag
  echo -e "\e[1;36mChecking out tag: $tag\e[0m"
  git checkout "$tag"
  git submodule update --init --recursive
  
  # Set the built APK path
  builtApk="$workDir/app/dist/Electrum-$versionName-$apk_arch-release-unsigned.apk"
  
  # Verify Dockerfile exists
  if [ ! -f "contrib/android/Dockerfile" ]; then
    echo -e "\e[1;31mError: Dockerfile not found at contrib/android/Dockerfile\e[0m"
    exit 1
  fi
  
  # Build setup
  cp contrib/deterministic-build/requirements-build-android.txt contrib/android/
  
  # Handle UID issue
  DOCKER_UID=$(id -u)
  if [ "$DOCKER_UID" -eq 0 ]; then
    echo -e "\e[1;33mWarning: Running as root, using UID 1000 for Docker build\e[0m"
    DOCKER_UID=1000
  fi
  
  # Build Docker image
  echo -e "\e[1;36mBuilding Docker image with UID: $DOCKER_UID\e[0m"
  docker build --no-cache -t electrum-android-builder-img --build-arg UID=$DOCKER_UID --file contrib/android/Dockerfile .
  
  if [ $? -ne 0 ]; then
    echo -e "\e[1;31mError: Docker build failed\e[0m"
    exit 1
  fi
  
  # Create necessary directories
  mkdir -p .buildozer/.gradle
  mkdir -p dist
  
  echo -e "\e[1;36mStarting APK build for architecture: $apk_arch\e[0m"
  
  # Clean up any existing container
  docker rm -f electrum-android-builder-cont 2>/dev/null || true
  
  docker run -it --rm \
    --name electrum-android-builder-cont \
    --volume "$ELECTRUM_DIR:/home/user/wspace/electrum" \
    --volume "$ELECTRUM_DIR/.buildozer/.gradle:/home/user/.gradle" \
    --workdir /home/user/wspace/electrum \
    electrum-android-builder-img \
    /bin/bash -c "
      # Set environment to avoid pager issues
      export GIT_PAGER=cat
      export PAGER=cat
      
      # Ensure proper ownership
      sudo chown -R user:user /home/user/wspace/electrum || true
      
      # Set git config
      git config --global user.email 'builder@example.com'
      git config --global user.name 'Builder'
      git config --global --add safe.directory /home/user/wspace/electrum
      git config --global core.pager cat
      
      # Quick git status check without pager
      echo 'Git repository status:'
      git status --porcelain | head -5 || echo 'Git status failed, continuing...'
      git describe --tags --exact-match 2>/dev/null || echo 'Could not get exact tag'
      
      # Verify make_apk.sh exists
      if [ ! -f contrib/android/make_apk.sh ]; then
        echo 'Error: make_apk.sh not found!'
        ls -la contrib/android/
        exit 1
      fi
      
      chmod +x contrib/android/make_apk.sh
      mkdir -p dist
      
      # Run the build
      echo 'Starting APK build process...'
      ./contrib/android/make_apk.sh qml $apk_arch release-unsigned
      
      # Check results
      if ls dist/*.apk >/dev/null 2>&1; then
        echo 'APK build completed successfully!'
        ls -la dist/*.apk
      else
        echo 'Error: No APK files found in dist/'
        echo 'Searching for APK files elsewhere:'
        find . -name '*.apk' -type f 2>/dev/null || echo 'No APK files found anywhere'
        ls -la dist/ || echo 'dist/ directory missing'
      fi
      
      # Auto-exit to trigger result processing
      exit
    "
  
  # Check if APK was built
  if [ ! -f "$builtApk" ]; then
    echo -e "\e[1;31mError: Built APK not found at expected location\e[0m"
    echo -e "\e[1;36mSearching for APK files:\e[0m"
    find "$ELECTRUM_DIR" -name "*.apk" -type f 2>/dev/null || echo "No APK files found"
    
    # If we find an APK with a different name/location, update the path
    FOUND_APK=$(find "$ELECTRUM_DIR" -name "*$apk_arch*.apk" -type f | head -1)
    if [ -n "$FOUND_APK" ]; then
      echo -e "\e[1;36mFound APK at different location: $FOUND_APK\e[0m"
      builtApk="$FOUND_APK"
    else
      exit 1
    fi
  fi
  
  # Copy the built APK to expected location
  echo -e "\e[1;36mCopying built APK to expected location\e[0m"
  mkdir -p "$workDir/app/dist"
  cp "$builtApk" "$workDir/app/dist/"
  
  # Cleanup
  docker rmi electrum-android-builder-img -f
  docker image prune -f
  
  cd "$workDir"
  
  echo -e "\e[1;32mBuild completed successfully!\e[0m"
  echo -e "\e[1;36mBuilt APK: $workDir/app/dist/$(basename $builtApk)\e[0m"
}