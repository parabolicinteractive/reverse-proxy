# Built from alpine rather than pulled from a third-party dnsmasq image, so the
# only trust dependency is the distro itself.
FROM alpine:3.20

RUN apk add --no-cache dnsmasq

# -k keeps it in the foreground so Docker owns the process lifecycle.
ENTRYPOINT ["dnsmasq", "-k", "--conf-file=/etc/dnsmasq.conf"]
