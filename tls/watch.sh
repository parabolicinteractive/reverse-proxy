#!/bin/sh
# Keeps one certificate per .test hostname Traefik is routing, as one file per
# hostname in the directory Traefik watches. Adding, removing or renewing one
# changes that directory, which is what makes Traefik reload.
set -eu

export CAROOT=/certs
DYNAMIC=/dynamic

# mkcert issues leaf certificates lasting about 27 months. Replacing one a
# month out keeps a quiet machine from waking up to an expired certificate.
RENEW_WITHIN=2592000

# mkcert creates the authority the first time it is asked for anything, which
# would otherwise be the first time a project appears. bin/trust needs it
# before then, on a machine where this stack is all that is running.
ensure_authority() {
    [ -f /certs/rootCA.pem ] && return 0

    # .invalid is reserved by RFC 6761 and never resolves, so this throwaway
    # name cannot collide with anything. Only the authority is kept.
    mkcert -cert-file /tmp/init.crt -key-file /tmp/init.key init.invalid >/dev/null 2>&1
    rm -f /tmp/init.crt /tmp/init.key
    echo "created the certificate authority"
}

# Every hostname Traefik is routing, one per line. Returns non-zero when
# Docker cannot be asked, which must never be mistaken for nothing running.
discover() {
    ids=$(docker ps --filter label=traefik.enable=true --format '{{.ID}}') || return 1

    for id in $ids; do
        labels=$(docker inspect --format \
            '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$id") || return 1

        # A rule may hold more than one Host(). Traefik accepts backticks,
        # double quotes or single quotes around the value, and tolerates
        # spaces inside the brackets.
        printf '%s\n' "$labels" |
            grep -E '^traefik\.http\.routers\.[^=]+\.rule=' |
            grep -oE "Host\([[:space:]]*[\`\"'][^\`\"']+[\`\"'][[:space:]]*\)" |
            sed -E "s/^Host\([[:space:]]*[\`\"']//; s/[\`\"'][[:space:]]*\)\$//" || true

        # Traefik applies its defaultRule per router, not per container, and
        # treats an empty rule as none, hence matching on a value below. A
        # container with no router labels at all gets one too.
        routers=$(printf '%s\n' "$labels" |
            sed -n 's/^traefik\.http\.routers\.\([^.]*\)\..*/\1/p' | sort -u)
        derive=no
        if [ -z "$routers" ]; then
            derive=yes
        else
            for router in $routers; do
                if ! printf '%s\n' "$labels" |
                    grep -q "^traefik\.http\.routers\.$router\.rule=."; then
                    derive=yes
                fi
            done
        fi

        if [ "$derive" = yes ]; then
            service=$(printf '%s\n' "$labels" | sed -n 's/^com\.docker\.compose\.service=//p')
            project=$(printf '%s\n' "$labels" | sed -n 's/^com\.docker\.compose\.project=//p')
            if [ -n "$service" ] && [ -n "$project" ]; then
                echo "$service.$project.test"
            fi
        fi
    done

    return 0
}

# A local authority vouching for a real domain is not something to hand out,
# and Traefik would not be serving one here anyway.
only_test_names() {
    grep -Ei '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.test$' || true
}

# The certificate is the file's contents rather than a path it points at, so
# that every file in this directory is self-contained and replacing one is a
# single atomic rename.
issue() {
    mkcert -cert-file /tmp/cert -key-file /tmp/key "$1" >/dev/null
    {
        echo 'tls:'
        echo '  certificates:'
        echo '    - certFile: |-'
        sed 's/^/        /' /tmp/cert
        echo '      keyFile: |-'
        sed 's/^/        /' /tmp/key
    } >"$DYNAMIC/$1.yaml.tmp"
    mv "$DYNAMIC/$1.yaml.tmp" "$DYNAMIC/$1.yaml"
    rm -f /tmp/cert /tmp/key
}

usable() {
    [ -f "$1" ] || return 1
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$1" | sed 's/^ *//' |
        openssl x509 -checkend "$RENEW_WITHIN" -noout >/dev/null 2>&1
}

sync_certificates() {
    mkdir -p "$DYNAMIC"
    ensure_authority

    # A failed query must never read as an empty one. Pruning against a
    # partial list would delete certificates that are still in use.
    if ! snapshot=$(discover); then
        echo "could not ask Docker what is running; leaving certificates alone" >&2
        return 0
    fi

    names=$(printf '%s\n' "$snapshot" | only_test_names | sort -u | sed '/^$/d')

    for name in $names; do
        usable "$DYNAMIC/$name.yaml" && continue
        issue "$name"
        echo "issued $name"
    done

    for file in "$DYNAMIC"/*.yaml; do
        [ -f "$file" ] || continue
        name=$(basename "$file" .yaml)
        printf '%s\n' "$names" | grep -qxF "$name" && continue
        rm -f "$file"
        echo "dropped $name"
    done

    return 0
}

# Polled rather than event-driven: a pass that changes nothing costs a few
# Docker queries, and polling also catches expiry on a machine where no
# container has started in months.
while true; do
    sync_certificates
    sleep 10
done
