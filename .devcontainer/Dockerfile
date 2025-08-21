FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install deps
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y \
       curl unzip git xz-utils zip libglu1-mesa openjdk-17-jdk \
    && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Set JAVA
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:${PATH}"
