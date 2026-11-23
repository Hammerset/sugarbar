FROM swift:6.4-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product sugarbar-server --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/sugarbar-server" /sugarbar-server

FROM ubuntu:noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home sugarbar \
    && install -d -o sugarbar -g sugarbar -m 700 /var/lib/sugarbar
COPY --from=build /sugarbar-server /usr/local/bin/sugarbar-server
USER sugarbar
ENV HOST=0.0.0.0 PORT=8080 GLOOKO_CREDENTIALS_FILE=/var/lib/sugarbar/glooko-credentials.json
EXPOSE 8080
ENTRYPOINT ["sugarbar-server"]
CMD ["serve"]
