# Built from alpine rather than pulled from a third-party pgbouncer image, so
# the only trust dependency is the distro itself. Same reasoning as dnsmasq.
# The result is around 10MB, of which pgbouncer is 1.5MB.
FROM alpine:3.24

RUN apk add --no-cache pgbouncer \
    && adduser -S -D -H -h /var/lib/pgbouncer pgbouncer

# pgbouncer refuses to run as root, and the alpine package ships only the
# binary and a sample config, so the user is created above.
USER pgbouncer

# Foreground, so Docker owns the process lifecycle.
ENTRYPOINT ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
