FROM swift:6-noble AS build
WORKDIR /build
COPY AgentSamCore/ AgentSamCore/
COPY Server/ Server/
WORKDIR /build/Server
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/Server/.build/release/AgentSamServer .
RUN mkdir -p /data
ENV AGENTSAM_DATA=/data \
    AGENTSAM_BIND_ALL=1 \
    AGENTSAM_PORT=8080
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["./AgentSamServer"]
