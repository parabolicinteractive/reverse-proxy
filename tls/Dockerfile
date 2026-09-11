# Build for Alpine/musl; published binaries require glibc.
FROM golang:1.25-alpine AS build
RUN go install filippo.io/mkcert@v1.4.4

FROM alpine:3.22
# docker-cli reads labels; openssl checks certificate expiry.
RUN apk add --no-cache docker-cli openssl
COPY --from=build /go/bin/mkcert /usr/local/bin/mkcert
COPY watch.sh /usr/local/bin/watch.sh
COPY test.sh /usr/local/bin/test.sh
ENTRYPOINT ["/usr/local/bin/watch.sh"]
