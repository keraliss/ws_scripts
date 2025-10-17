FROM ubuntu:22.04

ARG TAG=v1.51.10

ENV WDIR=trustee
ENV ANDROID_HOME=/${WDIR}/androidsdk \
    ANDROID_SDK_ROOT=/${WDIR}/androidsdk \
    TZ=Europe/Kiev

WORKDIR /${WDIR}

# Install dependencies
RUN apt-get -y update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
    sudo build-essential libtool openjdk-17-jdk git curl sudo \
    pigz unzip python3-distutils python3-apt python3-pip \
    ca-certificates gnupg tzdata && \
    ln -fs /usr/share/zoneinfo/Europe/Kiev /etc/localtime && \
    sudo dpkg-reconfigure --frontend noninteractive tzdata && date

# Install Node.js 20
RUN mkdir -p /etc/apt/sources.list.d/ && \
    mkdir -p /etc/apt/keyrings/ && \
    NODE_MAJOR=20 && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list && \
    sudo apt-get update && sudo apt-get install nodejs -y && \
    npm install --global yarn && \
    apt-get -y autoremove && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/*

# Set up Java
RUN echo "JAVA_HOME=$(which java)" | sudo tee -a /etc/environment && \
    . /etc/environment

# Set up Android SDK
RUN mkdir -p /${WDIR}/androidsdk/cmdline-tools/latest && \
    cd /${WDIR}/androidsdk/cmdline-tools/ && \
    curl -s -o commandlinetools-linux.zip https://dl.google.com/android/repository/commandlinetools-linux-8092744_latest.zip && \
    unzip commandlinetools-linux.zip && \
    cd ./cmdline-tools/ && \
    mv ./* ../latest/ && \
    cd .. && \
    rm -rf ./cmdline-tools && rm -f commandlinetools-linux.zip && \
    ln -sf /trustee/androidsdk/cmdline-tools/latest/bin/sdkmanager /usr/bin/sdkmanager && \
    yes | sdkmanager --licenses

# Install Android SDK components
RUN sdkmanager --install "build-tools;33.0.1" && \
    sdkmanager --install "build-tools;34.0.0" && \
    sdkmanager --install "cmake;3.22.1" && \
    sdkmanager --install "platform-tools" && \
    sdkmanager --install "platforms;android-31" && \
    sdkmanager --install "platforms;android-33" && \
    sdkmanager --install "platforms;android-34" && \
    sdkmanager --install "ndk;25.1.8937393"

# Clone the repository and checkout specific tag
WORKDIR /${WDIR}
RUN git clone https://github.com/trustee-wallet/trusteeWallet.git src && \
    cd src && \
    git fetch --all --tags

# Set up local.properties
RUN cd ./src/android && \
    touch local.properties && \
    echo sdk.dir=/${WDIR}/androidsdk/ >> ./local.properties

# Install dependencies
RUN cd ./src && yarn install --no-progress --frozen-lockfile

# Fix dependencies
RUN echo " " | sudo tee -a /${WDIR}/src/android/app/build.gradle && \
    echo 'configurations.all { resolutionStrategy { force "com.facebook.soloader:soloader:0.11.0" } }' | sudo tee -a /${WDIR}/src/android/app/build.gradle && \
    # Add JitPack repository
    sed -i '/mavenCentral()/a\        maven { url "https://www.jitpack.io" }' /${WDIR}/src/android/build.gradle && \
    # Replace the entire implementation line for BlurView with a working version
    sed -i 's/implementation "com.github.Dimezis:BlurView:version-2.0.3"/implementation "com.github.Dimezis:BlurView:2.0.3"/' /${WDIR}/src/node_modules/@react-native-community/blur/android/build.gradle

# Fix Firebase version mismatch 
RUN cd ./src && \
    yarn add @react-native-firebase/app@18.7.3 --dev && \
    yarn add @react-native-firebase/auth@18.7.3 --dev