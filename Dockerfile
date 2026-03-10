# Stage 1: Build Olaf with Zig 0.15.2
FROM alpine:latest AS builder

ARG TARGETARCH

RUN apk add --no-cache xz wget tar make

# Download and extract Zig 0.15.2 for the target architecture
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      ZIG_ARCH="aarch64"; \
    else \
      ZIG_ARCH="x86_64"; \
    fi && \
    wget -q "https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz" && \
    tar xf zig-${ZIG_ARCH}-linux-0.15.2.tar.xz && \
    mv zig-${ZIG_ARCH}-linux-0.15.2 /usr/local/zig

ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /usr/src/olaf
COPY . .

RUN make

# Stage 2: Minimal runtime image
FROM alpine:latest AS runner

RUN apk add --no-cache ffmpeg

COPY --from=builder /usr/src/olaf/zig-out/bin/olaf /usr/local/bin/olaf

ENV HOME=/root
RUN printf '{ "db_folder": "/root/.olaf/docker/db/", "cache_folder": "/root/.olaf/docker/cache/" }' > /usr/local/bin/olaf_config.json
RUN mkdir -p /root/audio
WORKDIR /root/audio
