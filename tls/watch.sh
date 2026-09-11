#!/bin/sh
# Maintain one certificate file per routed .test hostname.
# Traefik watches the directory for additions, renewals and removals.
set -eu

export CAROOT=/certs
DYNAMIC=/dynamic

# Renew within 30 days of expiry, including on otherwise idle machines.
RENEW_WITHIN=2592000

# Create the CA before any project starts so bin/trust.sh can export it.
ensure_authority() {
    if [ -f "$CAROOT/rootCA.pem" ]; then
        return 0
    fi

    # Bootstrap with a reserved .invalid name; keep only the CA.
    mkcert -cert-file /tmp/init.crt -key-file /tmp/init.key init.invalid >/dev/null 2>&1
    rm -f /tmp/init.crt /tmp/init.key
    echo "created the certificate authority"
}

# Read key=value labels from stdin; emit requested hostnames, one per line.
names_from_labels() {
    labels=$(cat)

    # Extract Host() values with backticks or either quote style.
    # Allow whitespace and multiple matches; exclude HostRegexp and HostSNI.
    printf '%s\n' "$labels" |
        grep -E '^traefik\.http\.routers\.[^=]+\.rule=' |
        grep -oE "Host\([[:space:]]*[\`\"'][^\`\"']+[\`\"'][[:space:]]*\)" |
        sed -E "s/^Host\([[:space:]]*[\`\"']//; s/[\`\"'][[:space:]]*\)\$//" || true

    # defaultRule applies to each router with a missing or empty rule,
    # and to containers with no router labels.
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
}

# Emit routed names; distinguish Docker failures from an empty result.
discover() {
    ids=$(docker ps --filter label=traefik.enable=true --format '{{.ID}}') || return 1

    for id in $ids; do
        labels=$(docker inspect --format \
            '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$id") || return 1
        printf '%s\n' "$labels" | names_from_labels
    done

    return 0
}

# Limit issuance to valid .test hostnames.
only_test_names() {
    grep -Ei '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.test$' || true
}

# Inline the certificate and key for a self-contained, atomic replacement.
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

    # Preserve certificates if discovery fails; partial results must not prune.
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

# Polling catches expiry even without container events.
main() {
    while true; do
        sync_certificates
        sleep 10
    done
}

# Tests source the functions without starting the loop.
[ -n "${TLS_WATCH_SOURCED:-}" ] || main
