# Builds mkcert against musl so it runs on the alpine below. The published
# binaries are glibc-linked and will not.
FROM golang:1.25-alpine AS build
RUN go install filippo.io/mkcert@v1.4.4

FROM alpine:3.22
# docker-cli reads container labels and the event stream, openssl checks how
# long the certificate has left.
RUN apk add --no-cache docker-cli openssl
COPY --from=build /go/bin/mkcert /usr/local/bin/mkcert
COPY watch.sh /usr/local/bin/watch
ENTRYPOINT ["/usr/local/bin/watch"]
