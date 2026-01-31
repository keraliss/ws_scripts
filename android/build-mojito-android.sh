#!/bin/bash

# Build script for Mojito Mobile Wallet Android APK

set -e

echo "Building Mojito Mobile Wallet Android APK..."

# Create Dockerfile for React Native Android build
cat > Dockerfile << 'EOF'
FROM ubuntu:20.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    openjdk-11-jdk \
    build-essential \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Set JAVA_HOME
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# Install Node.js 16.14.2 (required for Android build)
RUN curl -fsSL https://deb.nodesource.com/setup_16.x | bash - \
    && apt-get install -y nodejs

# Verify Node.js version
RUN node --version && npm --version

# Install Android SDK
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=${PATH}:${ANDROID_HOME}/tools:${ANDROID_HOME}/tools/bin:${ANDROID_HOME}/platform-tools

RUN mkdir -p ${ANDROID_HOME} && cd ${ANDROID_HOME} \
    && wget https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip \
    && unzip commandlinetools-linux-9477386_latest.zip \
    && rm commandlinetools-linux-9477386_latest.zip \
    && mkdir -p cmdline-tools/latest \
    && mv cmdline-tools/* cmdline-tools/latest/ || true \
    && rmdir cmdline-tools/bin cmdline-tools/lib || true

ENV PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin

# Accept Android licenses and install required packages
RUN yes | sdkmanager --licenses
RUN sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0"

# Set up workspace
WORKDIR /workspace

# Clone the repository
RUN git clone https://github.com/mintlayer/mojito_mobile_wallet.git

WORKDIR /workspace/mojito_mobile_wallet

# Install npm dependencies with legacy peer deps flag (as suggested in README)
RUN npm install --legacy-peer-deps

# Create build script
RUN echo '#!/bin/bash\n\
set -e\n\
echo "Starting Mojito Android build..."\n\
\n\
# Set Android environment variables\n\
export ANDROID_HOME=/opt/android-sdk\n\
export PATH=$PATH:$ANDROID_HOME/tools:$ANDROID_HOME/tools/bin:$ANDROID_HOME/platform-tools\n\
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64\n\
\n\
echo "Environment variables set:"\n\
echo "ANDROID_HOME: $ANDROID_HOME"\n\
echo "JAVA_HOME: $JAVA_HOME"\n\
echo "Node version: $(node --version)"\n\
echo "Java version: $(java -version 2>&1 | head -1)"\n\
\n\
# Build the Android APK\n\
echo "Building Android APK..."\n\
cd android\n\
./gradlew assembleRelease\n\
\n\
echo "Build complete! APK location:"\n\
find app/build/outputs/apk -name "*.apk" -type f\n\
' > /workspace/build.sh && chmod +x /workspace/build.sh

CMD ["/bin/bash"]
EOF

echo "Building Docker image..."
docker build -t mojito-android-build .

# Create output directory
mkdir -p output

echo "Starting Android build..."
docker run --rm \
  -v $(pwd)/output:/workspace/mojito_mobile_wallet/android/app/build/outputs \
  mojito-android-build \
  /workspace/build.sh

echo ""
echo "✅ Build completed!"
echo "APK should be in: ./output/apk/release/"
ls -la output/apk/release/ 2>/dev/null || echo "Check ./output/ directory for APK files"