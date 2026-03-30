# Epoxy — Secure Claude Code Sandbox
# Base: Node 22 on Debian Bookworm
FROM node:22-bookworm-slim

ARG GO_VERSION=1.23.6
ARG CLAUDE_CODE_VERSION=""
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000

# System packages (single layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core
    git curl wget sudo ca-certificates gnupg lsb-release \
    # CLI
    ripgrep fd-find jq tree htop tmux vim-tiny unzip \
    # USB
    usbutils libusb-1.0-0 libusb-1.0-0-dev \
    # Python
    python3 python3-pip python3-venv \
    # Build
    build-essential pkg-config \
    # Network
    iproute2 iptables iputils-ping dnsutils socat \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Go
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
       | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Claude Code
RUN if [ -n "$CLAUDE_CODE_VERSION" ]; then \
      npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    else \
      npm install -g @anthropic-ai/claude-code; \
    fi

# User setup — remove existing node user (UID 1000 conflict), then create claude
RUN userdel -r node 2>/dev/null || true \
    && groupmod -n ${USERNAME} node 2>/dev/null || groupadd --gid ${USER_GID} ${USERNAME} 2>/dev/null || true \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && groupadd -f plugdev \
    && groupadd -f docker \
    && usermod -aG plugdev,docker ${USERNAME}

# udev rules
COPY udev-rules/ /etc/udev/rules.d/

# Workspace
RUN mkdir -p /workspace/{input,output,output/logs,cases,temp,project} \
    && chown -R ${USER_UID}:${USER_GID} /workspace

# Go workspace
ENV GOPATH="/home/${USERNAME}/go"
ENV PATH="${GOPATH}/bin:${PATH}"
RUN mkdir -p ${GOPATH}/{bin,src,pkg} && chown -R ${USER_UID}:${USER_GID} ${GOPATH}

# Claude Code config
# Stash originals outside the volume mount so entrypoint can refresh them
RUN mkdir -p /home/${USERNAME}/.claude /usr/local/share/claude-sandbox
COPY claude-settings.json /home/${USERNAME}/.claude/settings.local.json
COPY CLAUDE.md /home/${USERNAME}/.claude/CLAUDE.md
COPY claude-settings.json /usr/local/share/claude-sandbox/settings.local.json
COPY CLAUDE.md /usr/local/share/claude-sandbox/CLAUDE.md
RUN chown -R ${USER_UID}:${USER_GID} /home/${USERNAME}/.claude

# Scripts
COPY entrypoint.sh init-firewall.sh auto-deps.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh /usr/local/bin/auto-deps.sh

USER ${USERNAME}

# GSD — spec-driven development workflow for Claude Code
# Install globally so /gsd:* commands are available in all sessions
RUN npx get-shit-done-cc@latest --claude --global

WORKDIR /workspace
ENTRYPOINT ["entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
