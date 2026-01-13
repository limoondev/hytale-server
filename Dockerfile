# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim

ARG TEMURIN_MAJOR=25
ARG TEMURIN_RELEASE=ea
ENV JAVA_HOME=/opt/java
ENV PATH="${JAVA_HOME}/bin:${PATH}" \
    HYTALE_DATA_DIR=/data \
    HYTALE_ASSETS_PATH=/data/Assets.zip \
    HYTALE_SERVER_DIR=/data/Server \
    HYTALE_SERVER_JAR=/data/Server/HytaleServer.jar \
    HYTALE_AOT_PATH=/data/Server/HytaleServer.aot \
    HYTALE_SESSION_FILE=/data/hytale-session.json

WORKDIR /opt/hytale

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl jq tar; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) temurin_arch=x64 ;; \
        arm64) temurin_arch=aarch64 ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/${TEMURIN_MAJOR}/${TEMURIN_RELEASE}/linux/${temurin_arch}/jre/hotspot/normal/eclipse" -o /tmp/temurin.tar.gz; \
    mkdir -p "$JAVA_HOME"; \
    tar -xzf /tmp/temurin.tar.gz --strip-components=1 -C "$JAVA_HOME"; \
    rm /tmp/temurin.tar.gz; \
    rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && mkdir -p /data

VOLUME ["/data"]
EXPOSE 5520/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD []
