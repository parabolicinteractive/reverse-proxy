# Built from alpine so the only trust dependency is the distro itself.
FROM alpine:3.24

# The package ships the binary and a sample config, no user.
RUN apk add --no-cache pgbouncer \
    && adduser -S -D -H -h /var/lib/pgbouncer pgbouncer

# pgbouncer refuses to run as root.
USER pgbouncer

# -k equivalent: foreground, so Docker owns the process lifecycle.
ENTRYPOINT ["pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
