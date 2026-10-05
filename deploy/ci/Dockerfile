# syntax=docker/dockerfile:1
# Linux CI only. No model client, Docker daemon, container hooks or credentials.
FROM elixir:1.19.5-otp-28-slim@sha256:597474ac81f0d0bfa4d67546c2591a033315a2b9e6ab2f1a22824af9c913066a
ARG TARGETARCH
RUN test "$TARGETARCH" = amd64 \
    && apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git jq libgssapi-krb5-2 libicu-dev \
      libssl-dev libstdc++6 procps python3 python3-venv unzip xz-utils zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1001 runner \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash runner
ADD --checksum=sha256:70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613 https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz /tmp/runner.tar.gz
ADD --checksum=sha256:69b09dba5c8dcb05c4e4273a4340db1005abeafe3927efda2bc5b249e80437ec https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz /tmp/node.tar.xz
RUN tar -xzf /tmp/runner.tar.gz -C /home/runner \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/runner.tar.gz /tmp/node.tar.xz \
    && mkdir /home/runner/_work \
    && chown -R 1001:1001 /home/runner \
    && test -x /home/runner/run.sh && test -x /bin/kill \
    && node --version | grep -Fx v22.14.0 \
    && elixir --version | grep -F 'Elixir 1.19.5' \
    && erl -noshell -eval '"28" = erlang:system_info(otp_release), halt().'
ARG SOURCE_REVISION
RUN python3 -c 'import re,sys; assert re.fullmatch("[0-9a-f]{40}",sys.argv[1])' "$SOURCE_REVISION"
LABEL org.opencontainers.image.source="https://github.com/iliazlobin/symphony" \
      org.opencontainers.image.revision="$SOURCE_REVISION" \
      org.opencontainers.image.description="Ephemeral Symphony Linux CI: Elixir 1.19.5 OTP 28 Node 22.14.0"
ENV HOME=/home/runner LANG=C.UTF-8 \
    RUNNER_MANUALLY_TRAP_SIG=1 ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    ERL_FLAGS="+S 2:2 +SDcpu 2 +SDio 2"
USER 1001:1001
WORKDIR /home/runner
CMD ["/home/runner/run.sh"]
