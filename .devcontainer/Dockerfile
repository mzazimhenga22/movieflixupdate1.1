FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Install dependencies
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y \
       curl unzip git xz-utils zip libglu1-mesa openjdk-11-jdk \
    && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Set JAVA_HOME for JDK 11
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:${PATH}"
