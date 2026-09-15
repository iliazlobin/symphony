# syntax=docker/dockerfile:1
# Official multi-architecture Elixir 1.19.5 / OTP 28 image.
FROM --platform=$BUILDPLATFORM elixir:1.19.5-otp-28-slim@sha256:597474ac81f0d0bfa4d67546c2591a033315a2b9e6ab2f1a22824af9c913066a AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /build
RUN mix local.hex --force && mix local.rebar --force
COPY elixir/mix.exs elixir/mix.lock ./
COPY elixir/config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY elixir/lib ./lib
COPY elixir/priv ./priv
# The escript is portable BEAM code; fail if application dependencies add native libraries.
RUN mix escript.build && test -z "$(find _build/prod/lib -name '*.so' -o -name '*.dylib')"

FROM elixir:1.19.5-otp-28-slim@sha256:597474ac81f0d0bfa4d67546c2591a033315a2b9e6ab2f1a22824af9c913066a
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 symphony \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp/home symphony \
    && install -d -o 10001 -g 10001 /var/lib/symphony /opt/symphony
ARG SOURCE_REVISION
RUN python3 -c 'import re,sys; assert re.fullmatch("[0-9a-f]{40}", sys.argv[1])' "$SOURCE_REVISION"
LABEL org.opencontainers.image.source="https://github.com/iliazlobin/symphony" \
      org.opencontainers.image.revision="$SOURCE_REVISION" \
      org.opencontainers.image.description="Paused, unconfigured Symphony GKE controller bootstrap; no worker execution"
COPY --from=build /build/bin/symphony /opt/symphony/symphony
COPY deploy/gke/WORKFLOW.md deploy/gke/entrypoint.py /opt/symphony/
USER 10001:10001
WORKDIR /opt/symphony
EXPOSE 8080
ENTRYPOINT ["python3", "-I", "/opt/symphony/entrypoint.py"]
CMD ["serve"]
