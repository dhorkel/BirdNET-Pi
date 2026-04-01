FROM debian:trixie-slim AS base

ARG TARGETARCH
ARG PYTHON_VERSION=3.11

# Phase 1 + Phase 2 system packages (single apt layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Phase 1: analysis pipeline
    python3 python3-pip python3-venv python3-dev \
    sqlite3 sox libsox-fmt-mp3 ffmpeg \
    curl ca-certificates lsof \
    # Phase 2: web UI stack
    php-fpm php-sqlite3 php-curl php-xml php-zip php-mbstring \
    icecast2 supervisor git gnupg inotify-tools alsa-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Caddy from official repo
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && apt-get install -y --no-install-recommends caddy && \
    rm -rf /var/lib/apt/lists/*

ENV BIRDNET_HOME=/opt/birdnet
ENV BIRDNET_DATA=/data
ENV BIRDNET_CONFIG=${BIRDNET_HOME}/birdnet.conf

# Create birdnet user for running services
RUN useradd -r -m -s /bin/bash birdnet

WORKDIR ${BIRDNET_HOME}

# PHP-FPM: switch pool user to birdnet, normalize socket path, pass container
# environment to PHP workers (clear_env=no), and create socket directory
RUN sed -i 's/www-data/birdnet/g' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's|listen = .*|listen = /run/php/php-fpm.sock|' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's|;clear_env = no|clear_env = no|' /etc/php/*/fpm/pool.d/www.conf && \
    mkdir -p /run/php && chown birdnet:birdnet /run/php

# Icecast2 log directory
RUN mkdir -p /var/log/icecast2 && chown birdnet:birdnet /var/log/icecast2

# Copy requirements and install Python dependencies
COPY requirements.txt ${BIRDNET_HOME}/

# Create virtual environment and install dependencies
RUN python3 -m venv ${BIRDNET_HOME}/venv

# Download platform-specific TFLite wheel and install requirements
RUN . ${BIRDNET_HOME}/venv/bin/activate && \
    pip install --no-cache-dir wheel && \
    ARCH=$(uname -m) && \
    PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info[0]}{sys.version_info[1]}')") && \
    BASE_URL=https://github.com/Nachtzuster/BirdNET-Pi/releases/download/v0.1/ && \
    WHL="" && \
    case "${ARCH}-${PY_VERSION}" in \
        aarch64-311) WHL=tflite_runtime-2.17.1-cp311-cp311-linux_aarch64.whl ;; \
        aarch64-312) WHL=tflite_runtime-2.17.1-cp312-cp312-linux_aarch64.whl ;; \
        aarch64-313) WHL=tflite_runtime-2.17.1-cp313-cp313-linux_aarch64.whl ;; \
        x86_64-311) WHL=tflite_runtime-2.17.1-cp311-cp311-linux_x86_64.whl ;; \
        x86_64-312) WHL=tflite_runtime-2.17.1-cp312-cp312-linux_x86_64.whl ;; \
        x86_64-313) WHL=tflite_runtime-2.17.1-cp313-cp313-linux_x86_64.whl ;; \
    esac && \
    if [ -n "$WHL" ]; then \
        mkdir -p /build && \
        curl -L -o /build/$WHL ${BASE_URL}${WHL} && \
        sed "s|tensorflow.*|/build/${WHL}|" ${BIRDNET_HOME}/requirements.txt > /build/requirements_custom.txt && \
        pip install --no-cache-dir -r /build/requirements_custom.txt && \
        rm -rf /build ; \
    else \
        pip install --no-cache-dir -r ${BIRDNET_HOME}/requirements.txt ; \
    fi

# Copy application code
COPY scripts/ ${BIRDNET_HOME}/scripts/
COPY model/ ${BIRDNET_HOME}/model/
COPY homepage/ ${BIRDNET_HOME}/homepage/
COPY templates/ ${BIRDNET_HOME}/templates/
COPY docker/ ${BIRDNET_HOME}/docker/

# Install Docker service configs
COPY docker/supervisord.conf /etc/supervisor/conf.d/birdnet.conf
COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/icecast.xml /etc/icecast2/icecast.xml

# Install GoTTY binaries for log viewing
RUN cp ${BIRDNET_HOME}/scripts/gotty-aarch64 /usr/local/bin/gotty-aarch64 && \
    cp ${BIRDNET_HOME}/scripts/gotty-x86_64 /usr/local/bin/gotty-x86_64 && \
    cp ${BIRDNET_HOME}/scripts/gotty /usr/local/bin/gotty && \
    chmod +x /usr/local/bin/gotty-aarch64 /usr/local/bin/gotty-x86_64 /usr/local/bin/gotty

# Minimal timedatectl shim: 'show --value --property=Timezone' reads /etc/timezone.
# All sudo timedatectl calls (set-timezone, set-ntp) fail at sudo anyway and are harmless.
RUN printf '#!/bin/sh\ncase "$1" in\n  show) cat /etc/timezone 2>/dev/null || echo UTC ;;\nesac\n' \
      > /usr/local/bin/timedatectl && chmod +x /usr/local/bin/timedatectl

# sudo shim: PHP code throughout the app calls sudo for systemctl, timedatectl, etc.
# Without sudo installed these produce "sudo: not found" noise. This shim silently
# runs the command directly (harmless since systemctl/timedatectl are also shims or absent).
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo && chmod +x /usr/local/bin/sudo
# Set up data directories
RUN mkdir -p ${BIRDNET_DATA}/StreamData \
             ${BIRDNET_DATA}/Extracted/By_Date \
             ${BIRDNET_DATA}/Extracted/Charts \
             ${BIRDNET_DATA}/Processed

# Create empty default species list files and BirdDB
RUN touch ${BIRDNET_HOME}/exclude_species_list.txt \
          ${BIRDNET_HOME}/include_species_list.txt \
          ${BIRDNET_HOME}/whitelist_species_list.txt \
          ${BIRDNET_HOME}/confirmed_species_list.txt \
          ${BIRDNET_HOME}/BirdDB.txt

# Ensure birdnet user owns application and data directories
RUN chown -R birdnet:birdnet ${BIRDNET_HOME} ${BIRDNET_DATA}

ENV PATH="${BIRDNET_HOME}/venv/bin:${PATH}"
ENV VIRTUAL_ENV="${BIRDNET_HOME}/venv"

VOLUME ["/data"]
EXPOSE 80

ENTRYPOINT ["/opt/birdnet/docker/entrypoint.sh"]
