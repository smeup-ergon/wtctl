# syntax=docker/dockerfile:1
FROM alpine:3.21 AS lab
RUN apk add --no-cache ca-certificates curl openssl python3 \
    && mkdir -p /etc/init.d \
    && printf '%s\n' '#!/bin/sh' \
       '# Test-only registration recorder, not an init implementation.' \
       'printf "%s\\n" "$*" >> /lab/registration.log' \
       > /usr/sbin/update-rc.d \
    && chmod 755 /usr/sbin/update-rc.d
WORKDIR /work
COPY . /work
ENTRYPOINT ["python3", "/work/tests/compose/lab.py"]

# Official image executable requires glibc; the upstream release executable is
# static musl and matches the Alpine/BusyBox device baseline. Init only.
FROM lab AS artifacts
RUN curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --max-time 180 \
      https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_linux_amd64.tar.gz \
      -o /tmp/wstunnel.tar.gz \
    && echo '512edf4e7bb64fc133522220123514868fae75b5bae4124b53e396787276aa23  /tmp/wstunnel.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/wstunnel.tar.gz -C /opt wstunnel \
    && mv /opt/wstunnel /opt/wstunnel-source \
    && chmod 755 /opt/wstunnel-source \
    && /opt/wstunnel-source --version \
    && rm /tmp/wstunnel.tar.gz
