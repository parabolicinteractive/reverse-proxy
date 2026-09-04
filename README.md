# reverse-proxy

Local development front door. Routes every `*.test` hostname to the right container,
and answers DNS for those hostnames so no hosts-file entry is needed.

Shared local infrastructure. Any containerized project joins this stack, wherever
that project's repository lives. This one owns port 80 and the shared network; the projects
that attach to it own nothing here.

| Service | Does |
|---|---|
| `traefik` | Owns port 80. Routes by Host header to any container that opts in. Dashboard on 8080. |
| `dns` | dnsmasq. Answers `*.test` with 127.0.0.1, forwards everything else upstream. |
| `pgbouncer` | Postgres front door on 127.0.0.1:6432. Routes by database name to whichever container serves it. |
| `pgbouncer-gen` | Watches Docker events and rewrites pgbouncer's routing table from container labels. |

DNS runs in a container, so no local dnsmasq installation is required and port 53
needs no elevated permission on the host.

## Run

```bash
docker compose up -d
```

This stack creates the shared `reverse-proxy` network. Start it before any site that
declares that network as external.

Dashboard: <http://localhost:8080>

## Host setup

The operating system needs to be told to ask this resolver for `.test` names. Run
once per machine.

### macOS

```bash
sudo mkdir -p /etc/resolver
sudo sh -c 'echo "nameserver 127.0.0.1" > /etc/resolver/test'
```

`/etc/resolver/<tld>` scopes the change to that TLD. Other DNS is unaffected.

Verify with `dscacheutil -q host -a name anything.test`, which answers 127.0.0.1.
Use `dscacheutil` rather than `dig`, which bypasses `/etc/resolver`.

### Linux (systemd-resolved)

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/test.conf >/dev/null <<'CONF'
[Resolve]
DNS=127.0.0.1
Domains=~test
CONF
sudo systemctl restart systemd-resolved
```

`Domains=~test` is a routing-only domain, so only `.test` lookups reach this
resolver.

systemd-resolved binds its stub listener on 127.0.0.53, leaving 127.0.0.1:53 free. On
a distribution where port 53 collides, change the published port in
`docker-compose.yaml` and point `DNS=` at it.

### Windows

PowerShell as Administrator:

```powershell
Add-DnsClientNrptRule -Namespace ".test" -NameServers "127.0.0.1"
```

The Name Resolution Policy Table scopes the change to `.test`. List rules with
`Get-DnsClientNrptRule` and remove them with `Remove-DnsClientNrptRule`.

Where NRPT is unavailable, set 127.0.0.1 as the machine's primary DNS server. The
container forwards anything it is not authoritative for, so other names still
resolve, and all DNS depends on the container running.

@note Unverified: whether `.test` names resolve from inside a WSL 2 terminal once
the NRPT rule is set on the Windows side. WSL's DNS path has changed across
releases. Check with `getent hosts anything.test` from WSL before assuming a site
is broken there. If it fails, a `127.0.0.1 <site>.test` line in WSL's `/etc/hosts`
is the fix, and the confirmed answer replaces this note.

## Adding a site

Join the network and enable Traefik in the project's compose file, or in a local
`docker-compose.override.yaml` where the repository should stay unchanged:

```yaml
services:
    app:
        labels:
            traefik.enable: "true"
            traefik.http.routers.myapp.rule: Host(`myapp.test`)
            # Required when the container exposes more than one port
            traefik.http.services.myapp.loadbalancer.server.port: "8080"
        networks:
            - reverse-proxy
networks:
    reverse-proxy:
        external: true
```

Traefik reaches the container over the shared network, so the site needs no published
ports.

## Adding a database

A Postgres container joins by declaring one label and the shared network:

```yaml
services:
    db:
        labels:
            reverse-proxy.postgres.expose: "true"
        networks:
            - default
            - reverse-proxy
networks:
    reverse-proxy:
        external: true
```

It appears on `127.0.0.1:6432`, selected by its compose project name, and
disappears when the project stops. Set `reverse-proxy.postgres.name` to choose a
different name. Credentials come from the container's `POSTGRES_DB`,
`POSTGRES_USER` and `POSTGRES_PASSWORD`; the container name is the host.

A client connects with any username and password, since the routing table
carries the real credentials.

Routing is by database name, which is what a Postgres client sends in its
startup packet. A hostname cannot be used: TCP hostname matching needs TLS
SNI, and Postgres negotiates TLS through its own pre-handshake, so no proxy
sees a server name.

Several projects can each run Postgres on 5432 inside their own network at the
same time, none publishing a port.

## Naming

Hostnames end in `.test`, which RFC 6761 section 6.2 reserves for this purpose and
forbids registries from selling. Per-project prefixes keep hostnames readable and
identical on every machine. The convention is `<service>.<project>.test`, which is
also what Traefik derives from a container's compose labels when it enables routing
without declaring a rule.

Avoid `.local`, `.dev`, `.localhost`, and any two-letter TLD. The reasons are
recorded in `dnsmasq/dnsmasq.conf`. `.localhost` is the tempting one, because it needs
no host setup: browsers and curl resolve subdomains of it, while the system resolver
does not, so ping, Python, Node and Go fail on a hostname that opens fine in a
browser.
