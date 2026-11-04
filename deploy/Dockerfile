# Web app: Vite build of Web/ into static files.
FROM node:22-bookworm-slim AS web
WORKDIR /web
COPY Web/package.json Web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY Web/ ./
RUN npm run build

# Server: Swift release build.
FROM swift:6-noble AS build
WORKDIR /build
COPY AgentSamCore/ AgentSamCore/
COPY Server/ Server/
WORKDIR /build/Server
RUN swift build -c release --static-swift-stdlib --product AgentSamServer

FROM ubuntu:noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/Server/.build/release/AgentSamServer .
COPY --from=web /web/dist ./Public
RUN mkdir -p /data
ENV AGENTSAM_DATA=/data \
    AGENTSAM_BIND_ALL=1 \
    AGENTSAM_PORT=8080 \
    AGENTSAM_WEB_DIR=/app/Public
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["./AgentSamServer"]
