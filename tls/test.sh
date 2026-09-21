#!/bin/sh
# Test hostname selection and Docker failures with isolated fixtures.
# Run with bin/test; no live containers or certificates are used.
set -eu

TLS_WATCH_SOURCED=1 . /usr/local/bin/watch.sh

passed=0
failed=0

# Assert both filters together, matching certificate issuance.
issued_for() {
    printf '%s\n' "$1" | names_from_labels | only_test_names | sort -u | sed '/^$/d'
}

names() {
    actual=$(issued_for "$3")
    if [ "$2" = "$actual" ]; then
        passed=$((passed + 1))
        return
    fi
    failed=$((failed + 1))
    echo "FAIL  $1"
    echo "      expected: [$(printf '%s' "$2" | tr '\n' ' ')]"
    echo "      actual:   [$(printf '%s' "$actual" | tr '\n' ' ')]"
}

ok() {
    if [ "$2" = yes ]; then
        passed=$((passed + 1))
        return
    fi
    failed=$((failed + 1))
    echo "FAIL  $1"
}

names 'an explicit hostname' 'app.demo.test' \
    'traefik.enable=true
traefik.http.routers.app.rule=Host(`app.demo.test`)
com.docker.compose.service=nginx
com.docker.compose.project=demo'

names 'no rule at all takes the default' 'nginx.demo.test' \
    'traefik.enable=true
com.docker.compose.service=nginx
com.docker.compose.project=demo'

names 'an empty rule counts as no rule' 'nginx.demo.test' \
    'traefik.enable=true
traefik.http.routers.app.rule=
com.docker.compose.service=nginx
com.docker.compose.project=demo'

names 'a router with labels but no rule takes the default' 'nginx.demo.test' \
    'traefik.enable=true
traefik.http.routers.app.service=app
com.docker.compose.service=nginx
com.docker.compose.project=demo'

names 'one router explicit, another defaulted, both issued' 'app.demo.test
nginx.demo.test' \
    'traefik.enable=true
traefik.http.routers.app.rule=Host(`app.demo.test`)
traefik.http.routers.admin.service=admin
com.docker.compose.service=nginx
com.docker.compose.project=demo'

names 'backticks, double quotes, single quotes, and spaces' 'one.demo.test
three.demo.test
two.demo.test' \
    'traefik.http.routers.a.rule=Host(`one.demo.test`)
traefik.http.routers.b.rule=Host("two.demo.test")
traefik.http.routers.c.rule=Host( '"'"'three.demo.test'"'"' )'

names 'two hostnames in one rule' 'one.demo.test
two.demo.test' \
    'traefik.http.routers.a.rule=Host(`one.demo.test`) || Host(`two.demo.test`)'

names 'a hostname joined to another matcher' 'app.demo.test' \
    'traefik.http.routers.a.rule=Host(`app.demo.test`) && PathPrefix(`/api`)'

names 'a real domain is never issued for' 'ok.demo.test' \
    'traefik.http.routers.a.rule=Host(`real.example.com`)
traefik.http.routers.b.rule=Host(`ok.demo.test`)'

names 'a regexp names nothing a certificate can cover' '' \
    'traefik.http.routers.a.rule=HostRegexp(`^.+\.demo\.test$`)'

names 'no compose labels and no rule leaves nothing to derive from' '' \
    'traefik.enable=true'

# Override watch's paths to keep tests away from the live CA and certificates.
CAROOT=/tmp/test-ca
DYNAMIC=/tmp/test-dynamic
export CAROOT
rm -rf "$CAROOT" "$DYNAMIC" /tmp/test-stub
mkdir -p "$CAROOT" "$DYNAMIC" /tmp/test-stub

# watch calls docker by name, so a stub earlier on PATH is what it finds.
real_path=$PATH
with_stub() {
    printf '%s\n' "$1" >/tmp/test-stub/docker
    chmod +x /tmp/test-stub/docker
    PATH=/tmp/test-stub:$real_path
    sync_certificates >/dev/null 2>&1 || true
    PATH=$real_path
}

printf 'issued earlier\n' >"$DYNAMIC/keep.demo.test.yaml"

with_stub '#!/bin/sh
exit 1'
[ -f "$DYNAMIC/keep.demo.test.yaml" ] && kept=yes || kept=no
ok 'a docker that will not run keeps existing certificates' "$kept"

with_stub '#!/bin/sh
case "$1" in
    ps) echo deadbeef ;;
    *) exit 1 ;;
esac'
[ -f "$DYNAMIC/keep.demo.test.yaml" ] && kept=yes || kept=no
ok 'a container that cannot be inspected keeps existing certificates' "$kept"

# Nothing routed at all is a real answer, so this pass does prune.
with_stub '#!/bin/sh
case "$1" in
    ps) : ;;
    *) exit 1 ;;
esac'
[ -f "$DYNAMIC/keep.demo.test.yaml" ] && kept=yes || kept=no
ok 'nothing running drops a certificate nothing routes to' "$([ "$kept" = no ] && echo yes || echo no)"
[ -f "$CAROOT/rootCA.pem" ] && made=yes || made=no
ok 'the authority is created with no projects running' "$made"

issue app.demo.test
grep -q 'BEGIN CERTIFICATE' "$DYNAMIC/app.demo.test.yaml" && has_cert=yes || has_cert=no
grep -q 'BEGIN PRIVATE KEY' "$DYNAMIC/app.demo.test.yaml" && has_key=yes || has_key=no
ok 'an issued file carries its own certificate' "$has_cert"
ok 'an issued file carries its own key' "$has_key"

usable "$DYNAMIC/app.demo.test.yaml" && fresh=yes || fresh=no
ok 'a certificate just issued is usable' "$fresh"

usable "$DYNAMIC/absent.demo.test.yaml" && missing=yes || missing=no
ok 'a certificate that is not there is not usable' "$([ "$missing" = no ] && echo yes || echo no)"

printf 'not a certificate\n' >"$DYNAMIC/broken.demo.test.yaml"
usable "$DYNAMIC/broken.demo.test.yaml" && broken=yes || broken=no
ok 'an unreadable certificate is not usable' "$([ "$broken" = no ] && echo yes || echo no)"

rm -rf "$CAROOT" "$DYNAMIC" /tmp/test-stub

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
