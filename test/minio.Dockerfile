# Test-only S3 service and client. Upstream removed its public registry images;
# build the official source at immutable release commits instead of a mirror.
FROM golang:1.24-bookworm AS build
RUN git init /src/minio && cd /src/minio \
    && git remote add origin https://github.com/minio/minio.git \
    && git fetch --depth=1 origin 01ce918d8279a20e4706b96a64396146894adee4 \
    && git checkout --detach FETCH_HEAD \
    && CGO_ENABLED=0 go build -trimpath -o /out/minio .
RUN git init /src/mc && cd /src/mc \
    && git remote add origin https://github.com/minio/mc.git \
    && git fetch --depth=1 origin d6541ea280b73a834b64d4097e21f2be77676104 \
    && git checkout --detach FETCH_HEAD \
    && CGO_ENABLED=0 go build -trimpath -o /out/mc .
FROM debian:bookworm-slim
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/minio /out/mc /usr/local/bin/
ENTRYPOINT ["minio"]
