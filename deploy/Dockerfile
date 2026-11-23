# Base images come from Docker's official-image mirror on Amazon ECR Public (same images as
# Docker Hub), which has no anonymous pull rate limit.

# Web app: Vite build of Web/ into static files.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS web
WORKDIR /web
COPY Web/package.json Web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY Web/ ./
RUN npm run build

# Server: Swift release build.
FROM public.ecr.aws/docker/library/swift:6.4-noble AS build
WORKDIR /build
# Compile third-party dependencies (Vapor, NIO, swift-crypto...) in their own layer. Only the
# manifests and empty stub sources are copied first, so this layer stays cached until Package.swift
# or Package.resolved changes; editing app code then rebuilds just the two AgentSam modules.
COPY AgentSamCore/Package.swift AgentSamCore/Package.swift
COPY Server/Package.swift Server/Package.resolved Server/
RUN mkdir -p AgentSamCore/Sources/AgentSamCore/Resources AgentSamCore/Tests/AgentSamCoreTests \
             Server/Sources/AgentSamServer/Resources Server/Tests/AgentSamServerTests \
    && touch AgentSamCore/Sources/AgentSamCore/Stub.swift AgentSamCore/Tests/AgentSamCoreTests/Stub.swift \
             Server/Sources/AgentSamServer/main.swift Server/Tests/AgentSamServerTests/Stub.swift
WORKDIR /build/Server
RUN swift build -c release --static-swift-stdlib --product AgentSamServer

# Now the real sources. Drop the stubs so they cannot end up in the build.
WORKDIR /build
RUN rm -rf AgentSamCore/Sources AgentSamCore/Tests Server/Sources Server/Tests
COPY AgentSamCore/ AgentSamCore/
COPY Server/ Server/
WORKDIR /build/Server
RUN swift build -c release --static-swift-stdlib --product AgentSamServer

FROM public.ecr.aws/docker/library/ubuntu:noble
# nodejs/python3/gcc run the programs Ada writes with the run_program chat tool. bubblewrap
# sandboxes persistent terminal sessions. Each language is a separate layer so a registry that
# already cached the base still only pulls what changed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 tzdata \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update \
    && apt-get install -y --no-install-recommends bubblewrap \
    && rm -rf /var/lib/apt/lists/*
# Google's Google Ads MCP server (github.com/googleads/google-ads-mcp) in its own virtualenv, so
# it never touches the python3 Ada's programs use. Ada runs it on loopback when
# AGENTSAM_GOOGLE_ADS_MCP=1; see deploy/google-ads-mcp/README.md.
COPY deploy/google-ads-mcp/requirements.txt /opt/google-ads-mcp-requirements.txt
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/google-ads-mcp \
    && /opt/google-ads-mcp/bin/pip install --no-cache-dir --require-virtualenv -r /opt/google-ads-mcp-requirements.txt \
    && /opt/google-ads-mcp/bin/python3 -I -c "import ads_mcp.server" \
    && rm /opt/google-ads-mcp-requirements.txt
COPY deploy/google-ads-mcp/ada_launch.py deploy/google-ads-mcp/tools_config.yaml /opt/google-ads-mcp/
# ssh client for Ada's workstation over SSH (AGENTSAM_WORKSTATION_SSH)
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/Server/.build/release/AgentSamServer .
# SwiftPM resource bundles. Bundle.module resolves them next to the executable on Linux;
# without them the first localized lookup (e.g. GET /api/templates) fatalErrors the process.
COPY --from=build /build/Server/.build/release/AgentSamCore_AgentSamCore.bundle ./AgentSamCore_AgentSamCore.bundle
COPY --from=build /build/Server/.build/release/AgentSamServer_AgentSamServer.bundle ./AgentSamServer_AgentSamServer.bundle
COPY --from=web /web/dist ./Public
RUN mkdir -p /data
ENV AGENTSAM_DATA=/data \
    AGENTSAM_BIND_ALL=1 \
    AGENTSAM_WEB_DIR=/app/Public
EXPOSE 8080
ENTRYPOINT ["./AgentSamServer"]
