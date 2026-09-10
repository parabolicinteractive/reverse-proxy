# reverse-proxy

Local development front door. Routes every `*.test` hostname to the right container,
and answers DNS for those hostnames so no hosts-file entry is needed.

Shared local infrastructure. Any containerized project joins this stack, wherever
that project's repository lives. This one owns ports 80 and 443 and the shared network;
the projects that attach to it own nothing here.

| Service | Does |
|---|---|
| `traefik` | Owns ports 80 and 443. Routes by Host header to any container that opts in. Dashboard on 8080. |
| `tls` | Issues a certificate per `.test` hostname Traefik routes, one file per hostname, and renews them before they expire. |
| `dns` | dnsmasq. Answers `*.test` with 127.0.0.1, forwards everything else upstream. |
| `pgbouncer` | Postgres front door on 127.0.0.1:6432. Routes by database name to whichever container serves it. |
| `pgbouncer-gen` | Watches Docker events and rewrites pgbouncer's routing table from container labels. |

DNS runs in a container, so no local dnsmasq installation is required and port 53
needs no elevated permission on the host.

## Run

```bash
docker volume create reverse-proxy-certs   # once per machine
docker compose up -d
```

That volume holds the certificate authority this machine trusts. It is declared
external so `docker compose down -v` cannot remove it; Compose refuses to start
and names the volume if it is missing.

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

See [Windows and WSL 2](#windows-and-wsl-2) below, which carries the whole
path in order rather than half of it here and half further down.

## HTTPS

Every site answers on both `http://` and `https://`. Nothing redirects, so a
bookmark, a script or a container talking to another over plain HTTP keeps
working.

HTTPS is worth having locally because a `.test` name over plain HTTP is not a
secure context. Clipboard access, service workers, `getUserMedia` and
`crypto.subtle` all refuse to run there, while the same code works on
`localhost`, which browsers exempt. Secure cookies and OAuth callbacks are the
other half.

The `tls` service reads the Traefik labels off running containers and issues a
certificate for each `.test` name it finds, one file per hostname, into a
volume Traefik watches. Adding a project needs nothing: start it, and
`app.myproject.test.yaml` appears within a few seconds. Stop it and the file
goes away.

```bash
docker compose exec tls ls /dynamic
```

Each file holds its certificate rather than pointing at one, so a file is
self-contained and replacing it is a single atomic rename. A path would work
too: Traefik's file provider reads referenced certificates into the
configuration before comparing it, so a renewal in place is noticed either
way, as long as the file sits inside the watched directory.

The certificate is signed by an authority generated on this machine, so this
machine has to be told to trust it. Run once:

```bash
./bin/trust
```

The script shows what it is about to trust, asks before doing anything, and
needs an administrator password. Chrome, Safari, Edge and curl follow the
system trust store afterwards.

### Firefox

Firefox keeps its own trust store, but recent versions read the operating
system's as well, so it usually picks the authority up with nothing further
to do. If it does not, write the authority out and import it by hand:

```bash
docker compose cp tls:/certs/rootCA.pem ./rootCA.pem
```

It goes under Settings > Privacy & Security > Certificates > View Certificates
> Authorities > Import, with "Trust this CA to identify websites" ticked.
Delete the copy afterwards.

### Windows

See [Windows and WSL 2](#windows-and-wsl-2) below. `bin/trust` handles both
sides from a WSL terminal.

### The authority

It lives in a Docker volume rather than the working tree, so its key is not
somewhere an archive, a backup or a file sync would pick it up, and it cannot
be committed by accident. Only the `tls` service mounts that volume, so the
key is not on any other container's filesystem. That is worth stating
precisely: it is not isolation. Traefik holds the Docker socket, and anything
holding that socket can reach the whole daemon and read the volume through
it. Treat the key as available to whoever can drive Docker on this machine.

It is never shared between developers. mkcert supports no name constraints, so
an authority a machine trusts can vouch for any domain, not only `.test`. A
shared one would hand anybody who got a copy of the key the ability to
intercept HTTPS to anywhere, on every machine that trusted it. One per
developer costs nothing and avoids that entirely.

To start over, which means trusting the new one afterwards:

```bash
docker compose down -v
docker volume rm reverse-proxy-certs
```

## Windows and WSL 2

Everything in order, once per machine. Steps 1 and 2 give `.test` names over
plain HTTP. Steps 3 and 4 add HTTPS, and are worth skipping until something
needs them.

Run the stack from a WSL terminal throughout. Docker Desktop's WSL 2
integration puts `docker` there, and a project cloned into the WSL filesystem
gets file-change events, which one under `C:\` does not.

**1. Start the stack.**

```bash
docker volume create reverse-proxy-certs
docker compose up -d
```

**2. Point Windows at the resolver.** PowerShell as Administrator:

```powershell
Add-DnsClientNrptRule -Namespace ".test" -NameServers "127.0.0.1"
```

The Name Resolution Policy Table scopes the change to `.test`. List rules with
`Get-DnsClientNrptRule` and remove them with `Remove-DnsClientNrptRule`. Where
NRPT is unavailable, set 127.0.0.1 as the machine's primary DNS server; the
container forwards anything it is not authoritative for, so other names still
resolve, and all DNS then depends on the container running.

**3. Trust the authority**, from the WSL terminal:

```bash
./bin/trust
```

It installs into the distribution's trust store, then prints the single
PowerShell command that installs it on the Windows side, with the path already
converted. Both halves matter: your browser is a Windows program reading the
Windows store, while curl and the test suite read the distribution's.

**4. Two answers nobody has yet.**

@note Unverified: nobody has run this stack on Windows, so the two checks below
have no confirmed answer and whoever runs them first will find out. Please
record what you see; confirmed answers replace this note.

Whether WSL resolves `.test` once the NRPT rule is set, since WSL's DNS path
has changed across releases:

```bash
getent hosts anything.test
```

That should answer 127.0.0.1. If it comes back empty, add a
`127.0.0.1 <site>.test` line to `/etc/hosts` inside the distribution for each
site needed. A Windows browser is unaffected either way.

Whether WSL trusts the authority after step 3:

```bash
curl -sI https://<site>.test | head -1
```

If that fails on the certificate, copy the `rootCA.crt` that `bin/trust` left
in this directory into `/usr/local/share/ca-certificates/` and run
`sudo update-ca-certificates`. The extension has to be `.crt` or the tool skips
the file without a word.

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

HTTPS needs no labels of its own. A router that names no entrypoint is attached to
every entrypoint, so the site answers on both schemes and the `tls` service picks its
hostname up within a few seconds.

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
