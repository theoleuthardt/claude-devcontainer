FROM docker.io/library/debian:trixie-slim

ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
ARG NODE_MAJOR=22
ARG FLUTTER_REF=stable

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    REPO_URL=https://github.com/theoleuthardt/backlog-manager.git

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gh gnupg openssh-client \
        build-essential pkg-config \
        unzip xz-utils zip \
        jq ripgrep less procps nano tmux \
        postgresql-client \
        podman-remote podman-compose \
        clang cmake ninja-build libgtk-3-dev libglu1-mesa \
        xvfb libgl1-mesa-dri libegl1 \
    && rm -rf /var/lib/apt/lists/*

RUN printf '#!/bin/sh\nexec /usr/bin/podman-remote "$@"\n' > /usr/local/bin/podman \
    && chmod +x /usr/local/bin/podman

RUN printf '%s\n' \
        '#!/bin/bash' \
        'export TERM=xterm-256color' \
        '[ -d /workspace/.git ] || git clone "$REPO_URL" /workspace || echo "Clone fehlgeschlagen"' \
        'rc_loop() { while true; do claude remote-control --name backlog-manager; echo "Remote Control beendet - Neustart in 15s"; sleep 15; done; }' \
        'export -f rc_loop' \
        'tmux new-session -d -s claude -c /workspace "bash -c rc_loop"' \
        'exec sleep infinity' \
        > /usr/local/bin/blm-start \
    && chmod +x /usr/local/bin/blm-start

COPY scripts/review.sh /usr/local/bin/review
RUN chmod +x /usr/local/bin/review

RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

ENV FLUTTER_HOME=/opt/flutter

RUN groupadd -g ${GID} ${USERNAME} \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} \
    && mkdir -p /workspace /home/${USERNAME}/.claude /home/${USERNAME}/.config/gh \
    && chown -R ${USERNAME}:${USERNAME} /workspace /home/${USERNAME}

RUN git clone --depth 1 --branch ${FLUTTER_REF} https://github.com/flutter/flutter.git ${FLUTTER_HOME} \
    && chown -R ${USERNAME}:${USERNAME} ${FLUTTER_HOME}

ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:/home/${USERNAME}/.pub-cache/bin:/home/${USERNAME}/.local/bin:/home/${USERNAME}/.coderabbit/bin:${PATH}"

USER ${USERNAME}

RUN flutter --disable-analytics \
    && dart --disable-analytics \
    && flutter config --enable-linux-desktop \
    && flutter precache --linux

RUN curl -fsSL https://claude.ai/install.sh | bash

RUN (curl -fsSL https://cli.coderabbit.ai/install.sh | sh) || true \
    && test -x /home/${USERNAME}/.local/bin/coderabbit

RUN curl -fsSL https://taskfile.dev/install.sh | sh -s -- -b /home/${USERNAME}/.local/bin

ENV DOCKER_HOST=unix:///run/podman.sock \
    CONTAINER_HOST=unix:///run/podman.sock \
    TESTCONTAINERS_RYUK_DISABLED=true \
    TESTCONTAINERS_HOST_OVERRIDE=host.containers.internal \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    UV_LINK_MODE=copy

WORKDIR /workspace
CMD ["/usr/local/bin/blm-start"]
