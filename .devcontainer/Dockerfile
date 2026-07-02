FROM mcr.microsoft.com/devcontainers/base:trixie@sha256:a30da48cdf5f9144ff7f2156622e701e752fc258d77ca7bb00120624f1a95938 AS devcontainer_base

# -- Build arguments
ARG CLAUDECODE=true
ARG GOLANG=false
ARG PYTHON=false
ARG NODEJS=false
ARG POWERSHELL=false
ARG AZCLI=false
ARG AWSCLI=false
ARG AZPWSH=false

# -- Versions
ARG GO_URL=https://go.dev/dl/go1.26.1.linux-amd64.tar.gz
ARG NVM_URL=https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh
ARG PWSH_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.6.3/powershell_7.6.3-1.deb_amd64.deb
ARG AZ_VER=2.87.0
ARG AWS_VER=2.35.14
ARG AZPWSH_VER=15.1.0
ARG POETRY_VER=2.4.1
ARG NODE_VER=24
ARG BUN_VER=1.3.14
ARG PNPM_VER=11.9.0

# -- Persistent environment variables
# Set unconditionally — a missing directory on PATH is harmless.
ENV PATH="/usr/local/go/bin:${PATH}" \
    GOROOT="/usr/local/go" \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# -- Base dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget curl git jq lsb-release \
    apt-transport-https bash unzip whois \
    libssl-dev gnupg2 iputils-ping ca-certificates \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Use bash as the default shell
RUN ln -sf /bin/bash /bin/sh

# -- Claude Code
RUN if [ "$CLAUDECODE" = "true" ]; then \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
    -o /etc/apt/keyrings/claude-code.asc && \
    ACTUAL=$(gpg --show-keys --fingerprint /etc/apt/keyrings/claude-code.asc 2>/dev/null \
    | grep -A1 "pub" | tail -1 | tr -d ' ') && \
    EXPECTED="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" && \
    [ "$ACTUAL" = "$EXPECTED" ] && \
    echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] \
    https://downloads.claude.ai/claude-code/apt/stable stable main" \
    | tee /etc/apt/sources.list.d/claude-code.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends claude-code && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# -- Go
RUN if [ "$GOLANG" = "true" ]; then \
    apt-get update && \
    apt-get install -y --no-install-recommends build-essential make && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL "${GO_URL}" | tar -xz -C /usr/local; \
    fi

# -- Python
RUN if [ "$PYTHON" = "true" ]; then \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv pipx && \
    pipx ensurepath && \
    pipx install poetry==$POETRY_VER && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# -- Node.js
USER vscode
RUN if [ "$NODEJS" = "true" ]; then \
    curl -o- "${NVM_URL}" | bash && \
    . /home/vscode/.nvm/nvm.sh && \
    nvm install $NODE_VER && \
    nvm alias default $NODE_VER && \
    nvm use default && \
    npm install -g bun@$BUN_VER pnpm@$PNPM_VER; \
    fi
USER root

# -- AZCLI
RUN if [ "$AZCLI" = "true" ]; then \
    mkdir -p /etc/apt/keyrings && \
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/microsoft.gpg && \
    AZ_DIST="bookworm" && \
    printf "Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n" \
    "${AZ_DIST}" "$(dpkg --print-architecture)" \
    | tee /etc/apt/sources.list.d/azure-cli.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends azure-cli=$AZ_VER-1~${AZ_DIST} && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# -- AWS CLI
RUN --mount=type=bind,source=.devcontainer/awscli.pub,target=/tmp/awscli.pub \
    if [ "$AWSCLI" = "true" ]; then \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWS_VER.zip" \
    -o /tmp/awscliv2.zip && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWS_VER.zip.sig" \
    -o /tmp/awscliv2.sig && \
    gpg --import /tmp/awscli.pub && \
    ACTUAL=$(gpg --fingerprint A6310ACC4672475C 2>/dev/null \
    | grep -A1 "pub" | tail -1 | tr -d ' ') && \
    EXPECTED="FB5DB77FD5C118B80511ADA8A6310ACC4672475C" && \
    [ "$ACTUAL" = "$EXPECTED" ] && \
    gpg --verify /tmp/awscliv2.sig /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/awscliv2.sig /tmp/aws; \
    fi

# -- PowerShell
RUN if [ "$POWERSHELL" = "true" ]; then \
    wget -q "${PWSH_URL}" -O /tmp/powershell.deb && \
    dpkg -i /tmp/powershell.deb; \
    apt-get install -f -y && \
    rm /tmp/powershell.deb && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# -- Az PowerShell module (requires both POWERSHELL=true and AZPWSH=true)
RUN if [ "$POWERSHELL" = "true" ] && [ "$AZPWSH" = "true" ]; then \
    pwsh -Command "Install-Module -Name Az -RequiredVersion $AZPWSH_VER -Repository PSGallery -Force"; \
    fi

# -- CUSTOM
FROM devcontainer_base
# Build on top of base image here

ENTRYPOINT ["sleep", "infinity"]
