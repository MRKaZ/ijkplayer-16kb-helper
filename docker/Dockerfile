FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip git make perl patch \
    openjdk-17-jre-headless \
    nasm pkg-config \
  && rm -rf /var/lib/apt/lists/*

# Android commandline tools
ENV ANDROID_SDK_ROOT=/opt/android-sdk
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools
RUN curl -fsSL -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
  && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
  && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
  && rm /tmp/cmdline-tools.zip

ENV PATH=${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}

# Pin NDK r26.2 (a.k.a. 26.2.11394342)
ENV ANDROID_NDK_VERSION=26.2.11394342
RUN yes | sdkmanager --sdk_root=${ANDROID_SDK_ROOT} --licenses >/dev/null
RUN sdkmanager --sdk_root=${ANDROID_SDK_ROOT} \
    "platform-tools" \
    "ndk;${ANDROID_NDK_VERSION}" \
  >/dev/null

ENV ANDROID_NDK=${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}

WORKDIR /workspace

# Use `bash` to run scripts because Windows volume mounts may not preserve executable bits.
CMD ["bash", "-lc", "bash ./scripts/run.sh"]
