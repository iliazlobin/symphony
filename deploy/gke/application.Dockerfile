# syntax=docker/dockerfile:1
# Compile architecture-independent BEAM code on the builder's native platform.
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
COPY elixir/assets ./assets
# Compile the accepted application, including the shared web implementation.
# Never substitute the preview script, an older service binary or a stub tracker.
RUN mix escript.build && test -z "$(find _build/prod/lib -name '*.so' -o -name '*.dylib')"
RUN mix run --no-start -e '\
  modules = [SymphonyElixir.Application, SymphonyElixir.Chat.Store, \
    SymphonyElixir.Chat.Persistence, SymphonyElixir.Chat.Runtime, \
    SymphonyElixirWeb.DashboardLive, SymphonyElixirWeb.ChatPanel, \
    SymphonyElixirWeb.ChatLive, SymphonyElixirWeb.SettingsPanel, SymphonyElixirWeb.BrowserAuth, \
    SymphonyElixirWeb.Router, SymphonyElixirWeb.StaticAssets]; \
  Enum.each(modules, fn module -> true = Code.ensure_loaded?(module) end); \
  routes = SymphonyElixirWeb.Router.__routes__(); \
  Enum.each(["/", "/chat"], fn path -> true = Enum.any?(routes, &(&1.path == path and &1.verb == :get)) end); \
  Enum.each(["/dashboard.css", "/dashboard.js", "/favicon.png", \
    "/vendor/phoenix_html/phoenix_html.js", "/vendor/phoenix/phoenix.js", \
    "/vendor/phoenix_live_view/phoenix_live_view.js"], fn path -> \
    {:ok, _type, bytes} = SymphonyElixirWeb.StaticAssets.fetch(path); true = byte_size(bytes) > 0 end); \
  Enum.each(SymphonyElixirWeb.StaticAssets.design_editor_paths(), fn path -> \
    {:ok, _type, bytes} = SymphonyElixirWeb.StaticAssets.fetch(path); true = byte_size(bytes) > 0 end); \
  "0.154.0" = SymphonyElixir.Chat.Runtime.supported_version()'

FROM --platform=$BUILDPLATFORM elixir:1.19.5-otp-28-slim@sha256:597474ac81f0d0bfa4d67546c2591a033315a2b9e6ab2f1a22824af9c913066a AS codex
# Preserve helper/resource layout; the native executable does not need Node.
ADD --checksum=sha256:fc6e3e3b85f2cf7d664520ee5c66a7fe4aa12bae7d46834f47e2f165fd0d6f78 https://github.com/openai/codex/releases/download/rust-v0.154.0/codex-package-x86_64-unknown-linux-musl.tar.gz /tmp/codex.tar.gz
RUN mkdir /package && tar -xzf /tmp/codex.tar.gz -C /package \
    && test -x /package/bin/codex && test -x /package/bin/codex-code-mode-host \
    && test -f /package/codex-package.json

FROM elixir:1.19.5-otp-28-slim@sha256:597474ac81f0d0bfa4d67546c2591a033315a2b9e6ab2f1a22824af9c913066a
ARG TARGETARCH
RUN test "$TARGETARCH" = amd64 \
    && apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-venv libatomic1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 symphony \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp/home symphony \
    && install -d -o 10001 -g 10001 /var/lib/symphony /opt/symphony
RUN python3 -m venv /opt/symphony/python \
    && /opt/symphony/python/bin/python -m pip install --no-cache-dir --disable-pip-version-check PyYAML==6.0.3
ARG SOURCE_REVISION
RUN python3 -c 'import re,sys; assert re.fullmatch("[0-9a-f]{40}", sys.argv[1])' "$SOURCE_REVISION"
LABEL org.opencontainers.image.source="https://github.com/iliazlobin/symphony" \
      org.opencontainers.image.revision="$SOURCE_REVISION" \
      org.opencontainers.image.description="Symphony application with shared Phoenix board and management chat"
COPY --from=build /build/bin/symphony /opt/symphony/symphony
COPY --from=codex /package/ /opt/symphony/
COPY deploy/gke/application_entrypoint.py /opt/symphony/application_entrypoint.py
ENV HOME=/tmp/home LANG=C.UTF-8
USER 10001:10001
WORKDIR /opt/symphony
ENTRYPOINT ["/opt/symphony/python/bin/python", "-I", "/opt/symphony/application_entrypoint.py"]
# Both mounted configuration paths are mandatory; no automatic dispatch or stub.
CMD ["serve"]
