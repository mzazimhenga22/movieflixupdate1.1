FROM mcr.microsoft.com/devcontainers/base:ubuntu

# ensure noninteractive apt
ENV DEBIAN_FRONTEND=noninteractive

# Provide ANDROID_HOME and PATH early so postCreate steps can use them
ENV ANDROID_HOME=/usr/local/android-sdk
ENV PATH=/usr/local/flutter/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${PATH}
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:${PATH}"

# Install system deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
       curl unzip git xz-utils zip libglu1-mesa openjdk-11-jdk \
       qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils \
       virt-manager x11vnc xvfb fluxbox novnc websockify \
    && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Create android-sdk dir so setup.sh can write to it
RUN mkdir -p ${ANDROID_HOME} && chown -R root:root ${ANDROID_HOME}

# Ensure /usr/local/flutter exists later by setup.sh; keep build lightweight
# Expose noVNC port used by your start script
EXPOSE 6080

# Use a non-root vscode user already present in the base image
# (the devcontainer will set remoteUser to "vscode")
