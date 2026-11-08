FROM alpine:3.19

ARG XRAY_VERSION=v26.10.31
ARG TARGETPLATFORM

RUN apk add --no-cache ca-certificates curl tzdata jq

# Create xray user, but TUN requires root in container
RUN adduser -D -s /sbin/nologin xray || true

# Download Xray-Core
RUN case "$TARGETPLATFORM" in \
    "linux/amd64")  ARCH="64" ;; \
    "linux/arm64")  ARCH="arm64-v8a" ;; \
    "linux/arm/v7") ARCH="arm32-v7a" ;; \
    *)              ARCH="64" ;; \
    esac && \
    curl -L -o /tmp/xray.zip \
    "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH}.zip" && \
    unzip /tmp/xray.zip -d /usr/local/bin/ && \
    rm /tmp/xray.zip && \
    chmod +x /usr/local/bin/xray && \
    mkdir -p /etc/xray

COPY --chmod=755 entrypoint.sh /entrypoint.sh

VOLUME ["/etc/xray"]

# No EXPOSE: TUN needs no port, and the SOCKS port is runtime-configurable via
# SOCKS_PORT (default 1080). EXPOSE is metadata only and ignored by Mikrotik
# Container, so a hardcoded value would just be misleading.

ENTRYPOINT ["/entrypoint.sh"]
