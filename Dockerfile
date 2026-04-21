FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Sandbox user: created at container startup by the entrypoint using
# the SANDBOX_UID/SANDBOX_GID env vars that runme.sh passes automatically
# (defaults to the host user's id -u / id -g).
# No user is baked into the image so that the same image works for every
# team member without rebuilding.

# ── Essential packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  git vim grep mc \
  wget iputils-ping \
  iptables ipset dnsutils \
  openssh-client \
  libcap2-bin \
  unzip \
  tcpdump \
  tshark && \
  rm -rf /var/lib/apt/lists/*

# Node.js + npm (LTS) — always installed; required by optional npm-based agent tools
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
  apt-get update && apt-get install -y nodejs && \
  rm -rf /var/lib/apt/lists/*

# ── Optional: OpenJDK 21 ────────────────────────────────────────────────────────
ARG INSTALL_OPENJDK_21=1
RUN if [ "$INSTALL_OPENJDK_21" = "1" ]; then \
      apt-get update && apt-get install -y openjdk-21-jdk && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Optional: OpenJDK 25 (Adoptium Temurin) ────────────────────────────────────
ARG INSTALL_OPENJDK_25=0
RUN if [ "$INSTALL_OPENJDK_25" = "1" ]; then \
      set -eux; \
      ARCH=$(uname -m | sed 's/x86_64/x64/; s/aarch64/aarch64/'); \
      URL=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/25/hotspot?os=linux&architecture=${ARCH}&image_type=jdk" \
            | grep -o '"link":"[^"]*"' | head -1 | sed 's/"link":"//; s/"$//'); \
      mkdir -p /opt/jdk-25; \
      curl -fsSL "$URL" | tar xz -C /opt/jdk-25 --strip-components=1; \
      update-alternatives --install /usr/bin/java  java  /opt/jdk-25/bin/java  25000; \
      update-alternatives --install /usr/bin/javac javac /opt/jdk-25/bin/javac 25000; \
    fi

# ── Optional: GraalVM CE 25 + Native Image ─────────────────────────────────────
ARG INSTALL_GRAALVM_25=0
RUN if [ "$INSTALL_GRAALVM_25" = "1" ]; then \
      set -eux; \
      ARCH=$(uname -m | sed 's/x86_64/x64/; s/aarch64/aarch64/'); \
      URL=$(curl -fsSL "https://api.github.com/repos/graalvm/graalvm-ce-builds/releases/latest" \
            | grep '"browser_download_url"' \
            | grep "_linux-${ARCH}_bin.tar.gz" \
            | head -1 \
            | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/'); \
      mkdir -p /opt/graalvm-25; \
      curl -fsSL "$URL" | tar xz -C /opt/graalvm-25 --strip-components=1; \
      update-alternatives --install /usr/bin/java         java         /opt/graalvm-25/bin/java         25100; \
      update-alternatives --install /usr/bin/javac        javac        /opt/graalvm-25/bin/javac        25100; \
      update-alternatives --install /usr/bin/native-image native-image /opt/graalvm-25/bin/native-image 25100; \
    fi

# ── Optional: kubectl ───────────────────────────────────────────────────────────
ARG INSTALL_KUBECTL=1
RUN if [ "$INSTALL_KUBECTL" = "1" ]; then \
      curl -fsSL https://dl.k8s.io/release/stable.txt | \
        xargs -I{} curl -LO https://dl.k8s.io/release/{}/bin/linux/amd64/kubectl && \
      install kubectl /usr/local/bin/kubectl && rm kubectl; \
    fi

# ── Optional: AWS CLI v2 ────────────────────────────────────────────────────────
ARG INSTALL_AWS_CLI=1
RUN if [ "$INSTALL_AWS_CLI" = "1" ]; then \
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && \
      unzip awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip; \
    fi

# ── Optional: Azure CLI ─────────────────────────────────────────────────────────
ARG INSTALL_AZURE_CLI=0
RUN if [ "$INSTALL_AZURE_CLI" = "1" ]; then \
      curl -sL https://aka.ms/InstallAzureCLIDeb | bash; \
    fi

# ── Optional: GitHub CLI ────────────────────────────────────────────────────────
ARG INSTALL_GITHUB_CLI=1
RUN if [ "$INSTALL_GITHUB_CLI" = "1" ]; then \
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
      apt-get update && apt-get install -y gh && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# ── Optional: npm-based agent tools ────────────────────────────────────────────
ARG INSTALL_COPILOT=1
ARG INSTALL_ANGULAR_CLI=1
ARG INSTALL_CLAUDE_CODE=1
ARG INSTALL_CODEX=0
ARG INSTALL_GEMINI=0
RUN set -e; \
    pkgs=""; \
    if [ "$INSTALL_COPILOT"     = "1" ]; then pkgs="$pkgs @github/copilot"; fi; \
    if [ "$INSTALL_ANGULAR_CLI" = "1" ]; then pkgs="$pkgs @angular/cli"; fi; \
    if [ "$INSTALL_CLAUDE_CODE" = "1" ]; then pkgs="$pkgs @anthropic-ai/claude-code"; fi; \
    if [ "$INSTALL_CODEX"       = "1" ]; then pkgs="$pkgs @openai/codex"; fi; \
    if [ "$INSTALL_GEMINI"      = "1" ]; then pkgs="$pkgs @google/gemini-cli"; fi; \
    if [ -n "$pkgs" ]; then npm install -g $pkgs; fi

# ── Optional: Kiro CLI ──────────────────────────────────────────────────────────
ARG INSTALL_KIRO=0
RUN if [ "$INSTALL_KIRO" = "1" ]; then \
      curl -fsSL https://cli.kiro.dev/install | bash && \
      cp ~/.local/bin/kiro-cli /usr/local/bin/kiro-cli && \
      cp ~/.local/bin/kiro-cli-chat /usr/local/bin/kiro-cli-chat && \
      cp ~/.local/bin/kiro-cli-term /usr/local/bin/kiro-cli-term; \
    fi

# ── Optional: dtctl and dtmgd ───────────────────────────────────────────────────
ARG INSTALL_DTCTL=1
ARG INSTALL_DTMGD=1
RUN if [ "$INSTALL_DTCTL" = "1" ] || [ "$INSTALL_DTMGD" = "1" ]; then \
      set -eux; \
      ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/'); \
      OS=$(uname -s | tr '[:upper:]' '[:lower:]'); \
      if [ "$INSTALL_DTCTL" = "1" ]; then \
        TAG=$(curl -fsSL https://api.github.com/repos/dynatrace-oss/dtctl/releases/latest | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'); \
        curl -fsSL "https://github.com/dynatrace-oss/dtctl/releases/download/${TAG}/dtctl_${TAG#v}_${OS}_${ARCH}.tar.gz" \
          | tar xz -C /usr/local/bin dtctl; \
        chmod +x /usr/local/bin/dtctl; \
      fi; \
      if [ "$INSTALL_DTMGD" = "1" ]; then \
        TAG=$(curl -fsSL https://api.github.com/repos/dynatrace-oss/dtmgd/releases/latest | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'); \
        curl -fsSL "https://github.com/dynatrace-oss/dtmgd/releases/download/${TAG}/dtmgd_${TAG#v}_${OS}_${ARCH}.tar.gz" \
          | tar xz -C /usr/local/bin dtmgd; \
        chmod +x /usr/local/bin/dtmgd; \
      fi; \
    fi

COPY refresh-ipset-allowlist.sh /usr/local/bin/
COPY capture-agent-destinations.sh /usr/local/bin/
COPY capture-blocked-traffic.sh /usr/local/bin/
COPY allowlist-domains.txt /tmp/
COPY allowlist-cidrs.txt /tmp/
COPY allowlist-proxy-domains.txt /tmp/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/refresh-ipset-allowlist.sh \
  /usr/local/bin/capture-agent-destinations.sh \
  /usr/local/bin/capture-blocked-traffic.sh \
  /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
WORKDIR /workspace
