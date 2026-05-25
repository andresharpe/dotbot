FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8

SHELL ["/bin/bash", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    build-essential \
    locales \
    sudo \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

# Ensure the `ubuntu` user exists (present by default in 24.04+ base images) and give it passwordless sudo
RUN if ! id -u ubuntu >/dev/null 2>&1; then useradd -m -s /bin/bash -u 1000 ubuntu; fi \
    && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu
WORKDIR /home/ubuntu

# Install mise
RUN curl https://mise.run | sh

# Make mise and its shims available on PATH for build and runtime commands
ENV PATH="/home/ubuntu/.local/bin:/home/ubuntu/.local/share/mise/shims:${PATH}"

# Copy mise config and install all tools
COPY --chown=ubuntu:ubuntu mise.toml /home/ubuntu/.config/mise/config.toml
RUN mise trust /home/ubuntu/.config/mise/config.toml && mise install

# Activate mise for interactive shells
RUN echo 'eval "$(mise activate bash)"' >> /home/ubuntu/.bashrc

# AGY (Google Antigravity CLI) — not available via mise
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash

# Pester module for PowerShell testing
RUN mise exec -- pwsh -Command '$ProgressPreference="SilentlyContinue"; Install-Module -Name Pester -Force -SkipPublisherCheck -Scope CurrentUser'

ENV DOTBOT_HOME=/workspaces/dotbot

WORKDIR /workspaces/dotbot
