# Custom GitHub Actions Runner for the grizzly-endeavors org.
# Built automatically by Argo Workflows (see kubernetes/infrastructure/argo-workflows/build-runner-image.yaml).
# Base: ARC v2 runner image (not the old summerwind/actions-runner-dind).

FROM ghcr.io/actions/actions-runner:latest

USER root

# Build tools and GitHub CLI
# GTK4 and WebKitGTK 6.0 come from apt; gtk4-layer-shell is built from source
# below because Ubuntu 24.04 (Noble) doesn't package it yet. Required by
# grizzly-widget-builder (see grizzly-widget-builder/CLAUDE.md "System packages").
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      build-essential \
      pkg-config \
      libssl-dev \
      openssh-client \
      rsync \
      gcc-aarch64-linux-gnu \
      libc6-dev-arm64-cross \
      gcc-mingw-w64-x86-64 \
      libgtk-4-dev \
      libwebkitgtk-6.0-dev \
      meson \
      ninja-build \
      libwayland-dev && \
    (type -p wget >/dev/null || apt-get install -y -qq wget) && \
    mkdir -p -m 755 /etc/apt/keyrings && \
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update -qq && \
    apt-get install -y -qq gh && \
    rm -rf /var/lib/apt/lists/*

# gtk4-layer-shell from source — not yet packaged on Ubuntu 24.04 (Noble).
# Pinned to a tagged release so rebuilds are reproducible. Introspection and
# docs are disabled because the Rust `gtk4-layer-shell` crate only needs the
# C library and pkg-config file.
ARG GTK4_LAYER_SHELL_VERSION=1.3.0
RUN git clone --depth 1 --branch v${GTK4_LAYER_SHELL_VERSION} \
      https://github.com/wmww/gtk4-layer-shell.git /tmp/gtk4-layer-shell && \
    cd /tmp/gtk4-layer-shell && \
    meson setup build \
      -Dexamples=false \
      -Ddocs=false \
      -Dtests=false \
      -Dintrospection=false \
      -Dvapi=false && \
    ninja -C build && \
    ninja -C build install && \
    ldconfig && \
    rm -rf /tmp/gtk4-layer-shell

# kubectl (not included in ARC v2 base image)
RUN curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod 755 /usr/local/bin/kubectl

# Helm
RUN curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
    chmod 700 /tmp/get_helm.sh && \
    /tmp/get_helm.sh && \
    rm /tmp/get_helm.sh

# Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y -qq nodejs && \
    rm -rf /var/lib/apt/lists/*

# Rust toolchain — install as runner user so paths match workflow execution
USER runner
ENV RUSTUP_HOME=/home/runner/.rustup \
    CARGO_HOME=/home/runner/.cargo \
    PATH=/home/runner/.cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default && \
    rustup component add clippy rustfmt && \
    rustup target add aarch64-unknown-linux-gnu x86_64-pc-windows-gnu && \
    cargo install cargo-deny --locked

# sccache — prebuilt static binary (much faster than cargo install)
USER root
RUN curl -fsSL https://github.com/mozilla/sccache/releases/download/v0.16.0/sccache-v0.16.0-x86_64-unknown-linux-musl.tar.gz \
      | tar xz -C /tmp && \
    mv /tmp/sccache-v0.16.0-x86_64-unknown-linux-musl/sccache /usr/local/bin/sccache && \
    chmod 755 /usr/local/bin/sccache && \
    rm -rf /tmp/sccache-*

# Symlink Rust binaries into /usr/local/bin so they're on PATH regardless of
# how the runner spawns shell steps
USER root
RUN for bin in /home/runner/.cargo/bin/*; do \
      ln -sf "$bin" /usr/local/bin/; \
    done

# Cargo linker config for cross-compilation targets
RUN printf '[target.x86_64-pc-windows-gnu]\nlinker = "x86_64-w64-mingw32-gcc"\n' \
    >> /home/runner/.cargo/config.toml

# Verify all tools are accessible
RUN helm version && \
    kubectl version --client && \
    rustc --version && \
    cargo --version && \
    cargo deny --version && \
    sccache --version && \
    node --version && \
    npm --version && \
    gh --version

USER runner
