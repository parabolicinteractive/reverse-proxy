# reverse-proxy

Local development front door. Routes every `*.test` hostname to the right container,
and answers DNS for those hostnames so no hosts-file entry is needed.

Chronicle infrastructure. Any containerized project joins this stack, wherever that
project's repository lives. This one owns port 80 and the shared network; the projects
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
            chronicle.postgres.expose: "true"
        networks:
            - default
            - reverse-proxy
networks:
    reverse-proxy:
        external: true
```

It then appears on `127.0.0.1:6432`, selectable by its compose project name.
Stop the project and it disappears again. Nothing in this repository is edited
to add one, which is what keeps it free of the names of the projects it serves.

The credentials come from the container's own `POSTGRES_DB`, `POSTGRES_USER`
and `POSTGRES_PASSWORD`, and the container name is the upstream host. Set
`chronicle.postgres.name` to choose a different selectable name.

A client connects with any username and any password: the routing table
carries the real credentials, and the security boundary is the published port,
bound to loopback exactly as the resolver is.

This works because a Postgres client sends the database name in its startup
packet, which is the only routing information available before a connection
exists. Traefik routes HTTP by Host header; this routes Postgres by the one
field the protocol offers. It is also why a hostname alone cannot do the job:
TCP hostname matching needs TLS SNI, and Postgres negotiates TLS through its
own pre-handshake, so no proxy ever sees a server name.

Several projects can therefore each run Postgres on 5432 inside their own
network, at the same time, without publishing a port or agreeing on one.

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
