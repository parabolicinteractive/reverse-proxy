# reverse-proxy

Shared local DNS, HTTPS and routing for containerized projects anywhere on the
machine. This stack owns ports 80/443 and the `reverse-proxy` Docker network;
projects opt in through their own configuration.

Published ports bind to loopback. Sites and dashboards are accessible from
this machine; other devices use the project's own optional LAN access.

| Service | Does |
|---|---|
| `traefik` | Owns ports 80 and 443. Routes by Host header to any container that opts in. Dashboard on 8080. |
| `tls` | Issues and renews one certificate file per routed `.test` hostname. |
| `dns` | dnsmasq. Answers `*.test` with 127.0.0.1, forwards everything else upstream. |
| `pgbouncer` | Postgres front door on 127.0.0.1:6432. Routes by database name to whichever container serves it. |
| `pgbouncer-gen` | Watches Docker events and rewrites pgbouncer's routing table from container labels. |

No host dnsmasq installation is required.

## Quick start

```bash
docker volume create reverse-proxy-certs   # once per machine
docker compose up -d
```

Tell the machine to ask this stack for `.test` names, once. macOS:

```bash
sudo mkdir -p /etc/resolver
sudo sh -c 'echo "nameserver 127.0.0.1" > /etc/resolver/test'
```

Linux and Windows have their own commands under Host setup below.

Any project that joins the `reverse-proxy` network is now at
`http://<app>.test`. For `https://` as well, trust this machine's certificate
authority, once:

```bash
bin/trust
```

Start this stack before any project that uses it, and check
<http://localhost:8080> to see what Traefik is routing.

---

**Everything below is reference.** DNS on each platform, how HTTPS and the
authority work, the full Windows path, and how a project adds a site or a
database.

## Host setup

Configure the host to resolve `.test` through this stack, once per machine.
The external volume created in the quick start holds this machine's CA and
survives `docker compose down -v`; Compose refuses to start without it. This
stack creates the shared `reverse-proxy` network, so it starts first.

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

See [Windows and WSL 2](#windows-and-wsl-2) for DNS and trust setup.

## HTTPS

Sites serve HTTP and HTTPS without redirects. HTTPS enables secure cookies,
OAuth callbacks and secure-context browser APIs on `.test`, including service
workers, camera access and `crypto.subtle`. Browsers exempt `localhost`.

The `tls` service discovers routed `.test` names from container labels and
maintains one certificate file per hostname in Traefik's watched volume.
Files appear within seconds of starting a project and disappear when it stops.

```bash
docker compose exec tls ls /dynamic
```

Certificates and keys are inlined for atomic replacement. Referenced files can
also reload when changed inside the watched directory; inlining keeps each
configuration self-contained.

Trust this machine's CA once:

```bash
bin/trust
```

The script displays the CA and requests confirmation before installing it with
administrator privileges. Chrome, Safari, Edge and curl use the system trust store.

### Firefox

Recent Firefox versions can use the system trust store. If yours does not,
export the public CA for manual import:

```bash
docker compose cp tls:/certs/rootCA.pem ./rootCA.pem
```

It goes under Settings > Privacy & Security > Certificates > View Certificates
> Authorities > Import, with "Trust this CA to identify websites" ticked.
Delete the copy afterwards.

### Windows

See [Windows and WSL 2](#windows-and-wsl-2) for both trust stores.

### The authority

The CA key stays in a Docker volume outside the working tree. Only `tls`
mounts it, but this is not isolation: Docker socket access, including
Traefik's, can read the volume. Treat Docker access as access to the key.

Keep a separate CA per developer and never share its private key. mkcert CAs
have no name constraints; a compromised key can impersonate any domain on
every device that trusts it.

To reset the CA, remove the volume, then repeat startup and trust setup:

```bash
docker compose down -v
docker volume rm reverse-proxy-certs
```

## Windows and WSL 2

Steps 1 and 2 enable HTTP with `.test` names; step 3 adds HTTPS trust.
Run Docker commands in WSL using Docker Desktop's WSL 2 integration. Clone
projects into the WSL filesystem for reliable file-change events.

**1. Start the stack.**

```bash
docker volume create reverse-proxy-certs
docker compose up -d
```

**2. Point Windows at the resolver.** PowerShell as Administrator:

```powershell
Add-DnsClientNrptRule -Namespace ".test" -NameServers "127.0.0.1"
```

NRPT scopes this to `.test`. Manage rules with `Get-DnsClientNrptRule` and
`Remove-DnsClientNrptRule`. If NRPT is unavailable, using 127.0.0.1 as primary
DNS forwards other domains too, but makes all DNS depend on this container.

**3. Trust the authority**, from the WSL terminal:

```bash
bin/trust
```

The script installs into WSL's trust store and prints a PowerShell command
for Windows. Run that command too: Windows browsers and WSL tools use
separate stores.

**4. Verify WSL DNS and HTTPS.**

@note Unverified on Windows. Check whether WSL honors the NRPT rule:

```bash
getent hosts anything.test
```

Expect 127.0.0.1. If empty, add `127.0.0.1 <site>.test` to WSL's `/etc/hosts`
for each site. This does not affect Windows browsers.

Check certificate trust:

```bash
curl -sI https://<site>.test | head -1
```

If trust fails, copy the exported `rootCA.crt` to
`/usr/local/share/ca-certificates/` and run `sudo update-ca-certificates`.
The `.crt` extension is required.

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

Routers without explicit entrypoints receive HTTP and HTTPS. Certificate
issuance follows automatically within seconds.

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

Client credentials are ignored; pgbouncer uses the generated upstream credentials.
Its loopback binding is the access boundary. Never publish it on the LAN.

Database names select projects through one port. Each Postgres container can
keep its internal port 5432 without publishing it.

## Naming

Use `<service>.<project>.test`, the default derived from Compose labels when
no router rule is supplied. RFC 6761 section 6.2 reserves `.test`, preventing
collisions with registered domains.

Avoid `.local` (mDNS), `.dev` (public and HSTS-preloaded), two-letter TLDs
(country codes), and `.localhost` (inconsistent system resolver support).

## Scripts

A script a person types has no extension: `bin/trust`, `bin/test`. A script a
program invokes ends in `.sh`: `tls/watch.sh` and `tls/test.sh`, run inside
the image. This follows the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html#file-extensions).
