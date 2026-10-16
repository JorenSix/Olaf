# syntax=docker/dockerfile:1
# Build tools stay in Alpine stages; the runtime contains only binaries and their dependencies.
FROM --platform=$BUILDPLATFORM alpine:3.24 AS builder
ARG BUILDARCH
ARG TARGETARCH
RUN apk add --no-cache ca-certificates wget xz git
RUN case "$BUILDARCH" in \
      arm64) arch=aarch64; sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
      amd64) arch=x86_64; sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
      *) exit 1 ;; \
    esac && \
    wget -q "https://ziglang.org/download/0.16.0/zig-${arch}-linux-0.16.0.tar.xz" -O /tmp/zig.tar.xz && \
    echo "$sha  /tmp/zig.tar.xz" | sha256sum -c - && \
    mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
ENV PATH="/opt/zig:${PATH}"
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY cli/ cli/
RUN case "$TARGETARCH" in arm64) target=aarch64 ;; amd64) target=x86_64 ;; *) exit 1 ;; esac && \
    zig build -Dtarget=${target}-linux-musl -Dcpu=baseline -Doptimize=ReleaseSmall

# Use Alpine's prebuilt FFmpeg binaries; copy only their runtime dependencies.
# Shared libraries avoid duplicating the codec payload in ffmpeg and ffprobe.
FROM alpine:3.24 AS ffmpeg
RUN apk add --no-cache ffmpeg=8.1.2-r0 ca-certificates lddtree
RUN mkdir -p /rootfs/usr/local/bin /rootfs/etc/ssl /rootfs/tmp /rootfs/data/db /rootfs/data/cache /rootfs/music && \
    cp /usr/bin/ffmpeg /usr/bin/ffprobe /rootfs/usr/local/bin/ && \
    lddtree -l /usr/bin/ffmpeg /usr/bin/ffprobe > /tmp/runtime-libs && \
    sort -u /tmp/runtime-libs | \
      while read -r lib; do \
        case "$lib" in /usr/bin/ffmpeg|/usr/bin/ffprobe) ;; *) cp -a --parents "$lib" /rootfs/ ;; esac; \
      done && \
    cp /etc/ssl/cert.pem /rootfs/etc/ssl/cert.pem && \
    chmod 1777 /rootfs/tmp && chown -R 65532:65532 /rootfs/data

# Distroless: no shell, package manager, or build tools.
FROM scratch
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED
LABEL org.opencontainers.image.title="Olaf" \
      org.opencontainers.image.description="Lightweight acoustic fingerprinting with FFmpeg" \
      org.opencontainers.image.source="https://github.com/JorenSix/Olaf" \
      org.opencontainers.image.url="https://github.com/JorenSix/Olaf" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.created=$CREATED
COPY --from=ffmpeg /rootfs/ /
COPY --from=builder /src/zig-out/bin/olaf /usr/local/bin/olaf
COPY LICENSE /usr/share/licenses/olaf/LICENSE
COPY docker/olaf_config.json /usr/local/bin/olaf_config.json
ENV HOME=/data PATH=/usr/local/bin SSL_CERT_FILE=/etc/ssl/cert.pem
USER 65532:65532
WORKDIR /music
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/olaf"]
CMD ["help"]
