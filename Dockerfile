FROM node:24-slim

# Install base dependencies
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      git \
      ca-certificates \
      curl \
      unzip \
      gnupg \
      software-properties-common \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @github/copilot

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
 && unzip awscliv2.zip \
 && ./aws/install \
 && rm -rf aws awscliv2.zip

# Add HashiCorp GPG key
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Add HashiCorp repo (based on distro codename)
RUN CODENAME=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release) \
 && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
    > /etc/apt/sources.list.d/hashicorp.list

# Install Terraform
RUN apt-get update \
 && apt-get install -y --no-install-recommends terraform \
 && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Install jq
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*

# Install JDK 25 LTS (Eclipse Temurin)
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /usr/share/keyrings/adoptium-archive-keyring.gpg \
 && CODENAME=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release) \
 && echo "deb [signed-by=/usr/share/keyrings/adoptium-archive-keyring.gpg] https://packages.adoptium.net/artifactory/deb ${CODENAME} main" \
    > /etc/apt/sources.list.d/adoptium.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends temurin-25-jdk \
 && rm -rf /var/lib/apt/lists/*

# Install latest Gradle
RUN GRADLE_VERSION=$(curl -s https://services.gradle.org/versions/current | jq -r '.version') \
 && curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip \
 && unzip /tmp/gradle.zip -d /opt \
 && ln -s "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle \
 && rm /tmp/gradle.zip

WORKDIR /workspace
CMD ["bash"]
