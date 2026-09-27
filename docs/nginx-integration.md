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
| Both services carry the `nginx_proxy=true` label and `VIRTUAL_*` env | Auto-discovery. An empty `VIRTUAL_HOST` is ignored, so the stack still starts with no proxy in front. |
| The published `8080` and `8090` are gone | While they are published on `0.0.0.0` they stay reachable from the LAN, and everything nginx adds, TLS and auth, is bypassable. |
| The published `1883` is gone | Only `chirpstack` and the two bridges need the broker, and they reach it over the compose network. This was an anonymous MQTT broker on every interface. |
| `1700/udp` and `3001/tcp` stay published but bindable | Unused on a single-host setup, but needed the moment a gateway lives somewhere else. `SEMTECH_UDP_BIND` and `BASIC_STATION_BIND` let you pin them to one LAN address. |
| `pull_policy: build` on the forwarder | The image is built locally and exists in no registry. Without this a plain `docker compose up` tries to pull it and fails. |

`postgres` and `redis` are untouched, still private to the compose network.

## Prerequisites

1. **The shared network must exist.** Create it once:

   ```sh
   docker network create site1
   ```

   It is declared `external: true`, so compose will not create it for you. To run
   this stack standalone without a proxy, delete the `site1` block at the bottom
   of `docker-compose.yml` and the `networks:` key from the two services that
   have it.

2. **DNS.** Each hostname in `.env` needs an A record pointing at the reverse
   proxy. The acme-companient uses the HTTP-01 challenge, so the record has to
   resolve before the first `docker compose up`.

3. **Basic auth for the REST API**, see below. Do this before enabling the
   hostname, not after.

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

## Rollback

Nothing is destructive. To go back to direct access, remove the `networks:`
key and the `VIRTUAL_*` environment from the two services, restore the
`ports:` entries for 8080, 8090 and 1883, and delete `.env`. The `site1`
network itself can stay, other stacks are using it.
