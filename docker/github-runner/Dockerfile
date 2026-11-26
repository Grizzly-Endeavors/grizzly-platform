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
      clang \
      mold \
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

# Node.js 24 LTS (Krypton) — pinned explicitly instead of floating setup_lts.x
# to ensure reproducible builds. GitHub Actions is deprecating Node 20 for
# running JavaScript actions; Node 24 is the current LTS that the runner
# enforces (since actions/runner v2.333.0). See:
# https://github.com/actions/runner/releases (v2.332.0 deprecation warning,
# v2.333.0 Node 24 enforcement).
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y -qq nodejs && \
    rm -rf /var/lib/apt/lists/*

# Playwright Chromium and its system libraries. The version must match the
# @playwright/test pin of the repos that run browser tests, or Playwright looks
# for a different browser revision and fails at launch.
ARG PLAYWRIGHT_VERSION=1.64.1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npx -y playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium && \
    chmod -R a+rX /ms-playwright && \
    rm -rf /var/lib/apt/lists/* /root/.npm

# Rust toolchain — install as runner user so paths match workflow execution
USER runner
ENV RUSTUP_HOME=/home/runner/.rustup \
    CARGO_HOME=/home/runner/.cargo \
    PATH=/home/runner/.cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default && \
    rustup component add clippy rustfmt && \
    rustup target add aarch64-unknown-linux-gnu x86_64-pc-windows-gnu && \
    cargo install cargo-deny --locked

# Prebuilt static release binaries (much faster than cargo install)
USER root
ARG SCCACHE_VERSION=0.20.1
ARG JUST_VERSION=1.59.0
ARG NEXTEST_VERSION=0.9.152
ARG GITLEAKS_VERSION=8.30.1
RUN curl -fsSL "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar xz -C /usr/local/bin --strip-components=1 "sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" && \
    curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar xz -C /usr/local/bin just && \
    curl -fsSL "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-${NEXTEST_VERSION}/cargo-nextest-${NEXTEST_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
      | tar xz -C /usr/local/bin cargo-nextest && \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
      | tar xz -C /usr/local/bin gitleaks && \
    chown root:root /usr/local/bin/sccache /usr/local/bin/just /usr/local/bin/cargo-nextest /usr/local/bin/gitleaks && \
    chmod 755 /usr/local/bin/sccache /usr/local/bin/just /usr/local/bin/cargo-nextest /usr/local/bin/gitleaks

# Symlink Rust binaries into /usr/local/bin so they're on PATH regardless of
# how the runner spawns shell steps
USER root
RUN for bin in /home/runner/.cargo/bin/*; do \
      ln -sf "$bin" /usr/local/bin/; \
    done

# Cargo linker and compiler-cache config
RUN printf '%s\n' \
      '[target.x86_64-pc-windows-gnu]' \
      'linker = "x86_64-w64-mingw32-gcc"' \
      '' \
      '[target.x86_64-unknown-linux-gnu]' \
      'linker = "clang"' \
      'rustflags = ["-C", "link-arg=-fuse-ld=mold"]' \
      '' \
      '[build]' \
      'rustc-wrapper = "sccache"' \
    >> /home/runner/.cargo/config.toml

# Verify all tools are accessible
RUN helm version && \
    kubectl version --client && \
    rustc --version && \
    cargo --version && \
    cargo deny --version && \
    sccache --version && \
    cargo nextest --version && \
    just --version && \
    mold --version && \
    clang --version && \
    gitleaks version && \
    find /ms-playwright -path '*/chromium-*/chrome-linux*/chrome' -type f -perm -o+x | grep -q . && \
    node --version && \
    npm --version && \
    gh --version

USER runner
