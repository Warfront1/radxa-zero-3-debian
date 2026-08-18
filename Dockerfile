FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        parted \
        gdisk \
        debootstrap \
        e2fsprogs \
        libarchive-tools \
        openssl \
        coreutils \
        uuid-runtime \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/build-image.sh /usr/local/bin/build-image.sh
RUN chmod +x /usr/local/bin/build-image.sh

ENTRYPOINT ["/usr/local/bin/build-image.sh"]