# nginx reverse proxy integration

How this stack sits behind an nginx-proxy setup, and what was changed to make
that safe. The target is the jrcs fork of `nginx-proxy`: `nginx-web` +
`nginx-gen` + `nginx-letsencrypt` on the official `nginx:latest` image, with
auto-discovery driven by the docker socket.

Assumption: **a single on-premises gateway**. Nothing here needs to be reachable
from the internet except the web UI, and even that is only for convenience.

## What changed, and why

| Change | Reason |
|--------|--------|
| `chirpstack` and `chirpstack-rest-api` join the external `site1` network | `docker-gen` only emits an upstream for containers on a network it can reach. The template drops everything else as `(unreachable)`. |
| Both services set `VIRTUAL_HOST` and `LETSENCRYPT_HOST` | Auto-discovery. An empty `VIRTUAL_HOST` is ignored, so the stack still starts with no proxy in front. |
| The published `8080` and `8090` are gone | While they are published on `0.0.0.0` they stay reachable from the LAN, and everything nginx adds, TLS and auth, is bypassable. |
| The published `1883` is gone | Only `chirpstack` and the two bridges need the broker, and they reach it over the compose network. This was an anonymous MQTT broker on every interface. |
| `1700/udp` and `3001/tcp` stay published but bindable | Unused on a single-host setup, but needed the moment a gateway lives somewhere else. `SEMTECH_UDP_BIND` and `BASIC_STATION_BIND` let you pin them to one LAN address. |
| `pull_policy: build` on the forwarder | The image is built locally and exists in no registry. Without this a plain `docker compose up` tries to pull it and fails. |

`postgres` and `redis` are untouched, still private to the compose network.

## Do not label the app containers

`docker-gen` builds vhosts from the `VIRTUAL_HOST` environment variable alone.
It does not need a label, and adding the obvious-looking one breaks certificate
issuance:

```
com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy=true
```

`acme-companient` uses that same label to find *nginx itself*. Its
`get_nginx_proxy_container` calls `labeled_cid`, which returns the ID of **every**
container carrying the label, then asks the Docker API about all of them at once.
With the label on an application container that lookup 404s, and the companion
logs

```
Error: nginx-proxy container <id> <id> <id> isn't running.
```

and sleeps for an hour. The vhost still appears, over plain HTTP, with no
certificate. That label belongs on `nginx-web` alone.

## Prerequisites

1. **The shared network must exist.** Create it once:

   ```sh
   docker network create site1
   ```

   It is declared `external: true`, so compose will not create it for you. To run
   this stack standalone without a proxy, delete the `site1` block at the bottom
   of `docker-compose.yml` and the `networks:` key from the two services that
   have it.

2. **DNS.** Each hostname in `.env` needs to resolve to the reverse proxy, over
   **both** A and AAAA. Let's Encrypt validates HTTP-01 against both records,
   and an IPv4 client that falls back to the A record will reach whatever is
   listening there instead. If the A record points somewhere else, IPv4 clients
   silently get the wrong site and the certificate can fail to issue:

   ```sh
   python3 -c "import socket;print(sorted({a[4][0] for a in socket.getaddrinfo('lorawan.example.com',None,socket.AF_INET)}))"
   ```

   Keep hostnames one label below the parent domain. A wildcard certificate for
   `*.example.com` covers `lorawan.example.com` but not
   `api.lorawan.example.com`, and acme-companient with no DNS provider
   credentials can only issue per-hostname certificates over HTTP-01.

3. **Basic auth for the REST API**, see below. Do this before enabling the
   hostname, not after.

## Coexisting with other stacks

Several applications can share one nginx-proxy by joining the same `site1`
network and taking their own hostname. Two things to watch:

- Moving an application to a subdomain is not only a `VIRTUAL_HOST` change. If
  something else is *configured* to call it, that reference has to move too. A
  Nextcloud Collabora integration, for example, keeps the Collabora URL in
  `oc_appconfig` and needs the new hostname in Nextcloud's `trusted_domains`,
  because the editor is loaded in a cross-origin iframe. Changing only the proxy
  vhost breaks the integration with no error on the proxy side.
- Take the certificate before cutting over. Add the new hostname, confirm it
  serves and the certificate is valid, then remove the old `VIRTUAL_HOST`.
  Doing it the other way round means a working service is down for the duration
  of the ACME issuance.

`VIRTUAL_HOST` accepts comma-separated values, so a zero-downtime cutover is
one env change and two recreates. This exact sequence moved a Collabora
instance from an apex to a subdomain without dropping a request:

```sh
# phase 1: both names at once, docker-gen builds both vhosts,
# acme-companion issues one SAN cert covering both
VIRTUAL_HOST="old.example.com,new.example.com"
docker compose up -d <service>   # verify the new URL serves + cert valid

# phase 2: move every configured reference to the new name first
# (Nextcloud: oc_appconfig wopi_url and public_wopi_url)

# phase 3: drop the old name, recreate, verify the old URL 503s
VIRTUAL_HOST="new.example.com"
docker compose up -d <service>
```

`LETSENCRYPT_HOST` takes the same comma-separated form.

## Configure

```sh
cp .env.example .env
$EDITOR .env
```

```sh
# one-time
docker network create site1

docker compose up -d --build
```

Within a minute `docker-gen` regenerates `conf.d/default.conf` and
acme-companient issues the certificate. Check it landed:

```sh
curl -I https://chirp.example.com
curl -I https://api.chirp.example.com    # expect 401 until htpasswd is set
```

`docker-gen` only rewrites `default.conf`, which is safe to edit by hand, but
`conf.d/proxy.conf` and `vhost.d/*` are yours and are never touched.

## The REST API needs a password file

`chirpstack-rest-api` runs with `--insecure`, which disables authentication
entirely. In front of a public hostname that is an unauthenticated device and
tenant management API. nginx basic auth is the only thing in the way.

```sh
# htpasswd/ is mounted read-only inside the container, so generate on the host
docker run --rm httpd:2.4-alpine htpasswd -nbB myuser 'a good password' \
  > nginx-data/htpasswd/chirp.example.com
```

The template picks that file up automatically for any matching `server_name`.
One file per hostname, and the per-path variant is
`htpasswd/<host>_<sha1 of path>`, which you do not need for a single path.

Verify with `curl -I`, expecting `401` without credentials.

## gRPC and the UI share port 8080

`chirpstack` serves the web UI and the gRPC API on the same port, but nginx has
to treat them differently: the UI is plain HTTP/1.1 through `proxy_pass`, while
native gRPC clients need `grpc_pass`, which speaks HTTP/2 upstream.

`VIRTUAL_PORT=8080` with `VIRTUAL_PROTO=http` covers the UI, which is all the
browser needs. Anything using a real gRPC client, `grpcurl` or the ChirpStack
CLI, needs a second location with `proto: grpc`. This template supports
`VIRTUAL_HOST_MULTIPORTS`, which takes precedence over `VIRTUAL_HOST` and lets
one container declare several paths:

```yaml
    environment:
      - VIRTUAL_HOST_MULTIPORTS=|
        chirp.example.com:
          /:
            port: 8080
            proto: http
          /<grpc-prefix>:
            port: 8080
            proto: grpc
```

Work out `<grpc-prefix>` from the browser network tab while the UI is making API
calls, or with a `grpcurl` call, rather than assuming it. If the split proves
awkward, drop a file at `nginx-data/vhost.d/chirp.example.com_location_override`
and write the two `location` blocks by hand. `_location` without the
`_override` suffix is the lighter option: it is included *inside* the generated
location, so you can add directives without replacing the block.

Keep ChirpStack on its own hostname rather than a subpath of another vhost. The
UI is a single page app with absolute asset paths and does not survive being
mounted below a prefix.

## What nginx cannot do here

**Raw TCP and UDP.** `nginx -V` shows `--with-stream` is compiled in, but
`conf.d` is included from inside `http{}`, so a `stream {}` block cannot live
there and `/etc/nginx/nginx.conf` is not mounted. Proxying 1883 or 1700 as
their native protocols would mean mounting a complete custom `nginx.conf`.
The `ipv6-proxy` HAProxy sidecar in host network is the cheaper route if that
ever becomes necessary.

**MQTT from a browser.** If you need it, mosquitto speaks WebSockets natively.
Add a second listener and front it as a path:

```
listener 9001
protocol websockets
allow_anonymous true
```

with `VIRTUAL_PATH=/mqtt` and `VIRTUAL_PORT=9001`. Do not do this with
`allow_anonymous true` on a public hostname. See the recipe at the bottom of
`configuration/mosquitto/config/mosquitto.conf`.

**`NETWORK_ACCESS=internal`.** The template emits
`include /etc/nginx/network_internal.conf;` and the official `nginx:latest`
image does not ship that file. A missing `include` is a hard config error and
nginx will not reload. If you want IP-based restriction, create the file
yourself in `nginx-data/conf.d/network_internal.conf`:

```
allow 192.168.0.0/16;
allow 10.0.0.0/8;
deny all;
```

## Before you expose anything

- **`api.secret` is still the default `you-must-replace-this`** in
  `configuration/chirpstack/chirpstack.toml`. It signs UI sessions and API
  tokens, so anyone who can reach the UI can mint an admin token. This is not a
  reverse proxy problem and the proxy does not fix it:

  ```sh
  openssl rand -base64 32
  ```

- The Basic Station backend still has empty `tls_cert` and `tls_key`. It is
  plaintext and unused on a single-host setup. If you ever expose 3001, put it
  behind a hostname with a certificate.

## Troubleshooting

**A vhost 502s after its container was recreated.** When a container gets a new
IP on `site1`, `docker-gen` rewrites `default.conf` — but it sometimes decides
the result is unchanged and skips the reload signal to nginx, which keeps
dialing the dead address:

```
connect() failed (111: Connection refused) while connecting to upstream,
upstream: "http://172.29.16.6:80/..."
```

Compare the IP in the error with the container's current address
(`docker inspect <name> --format ...`). If they differ, force the reload:

```sh
docker exec nginx-web nginx -t    # always test first; see below
docker exec nginx-web nginx -s reload
```

**Always `nginx -t` before `nginx -s reload`.** A failed reload leaves the old
config running with no warning in the access log, so every later change
silently never applies. The usual cause is a dangling certificate reference:
`acme-companion` deletes the `host.crt`-style symlinks for a hostname that no
longer has a vhost, but a hand-maintained file may still reference them, and
then *no* reload can succeed until the reference is removed or the symlinks are
recreated.

**Know which files are generated and which are yours.** `docker-gen` rewrites
only `conf.d/default.conf`. Everything else in the nginx project —
`conf.d/ipv6-vhosts.conf`, `conf.d/proxy.conf`, `vhost.d/*`, `htpasswd/*` — is
hand-maintained and never touched. That split cuts both ways: your files
survive every regeneration, but they also go stale without warning when a
hostname they reference disappears. After removing a vhost, grep the
hand-maintained files for its name.

## Rollback

Nothing is destructive. To go back to direct access, remove the `networks:`
key and the `VIRTUAL_*` environment from the two services, restore the
`ports:` entries for 8080, 8090 and 1883, and delete `.env`. The `site1`
network itself can stay, other stacks are using it.
