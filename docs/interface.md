# External TCP/IP interface

Everything that crosses the host boundary. Derived from `docker-compose.yml` and
the published-ports table in `README.md`.

For the USB side that carries packets from the concentrator into the stack, see
[gateway-path.md](gateway-path.md). For how the HTTP ports sit behind the
reverse proxy, see [nginx-integration.md](nginx-integration.md).

```
╔════════════════════════════════════════════════════════════════════════════╗
║ EXTERNAL TCP/IP INTERFACE                                                  ║
║                                                                            ║
║ STEP 1   ingress, two separate paths                                       ║
╚════════════════════════════════════════════════════════════════════════════╝

  ┌────────────────────────────────────────────────────────────┐
  │ nginx-web  192.168.54.254:443  ·  TLS terminates here      │
  │ nginx-letsencrypt  ·  docker-gen  ·  vhosts auto-generated │
  └────────────────────────────────────────────────────────────┘
                           │  Internet, LAN or VPN
                           ▼

╔════════════════════════════════════════════════════════════════════════════╗
║ STEP 2   proxied over the site1 docker network, no host port               ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
   ┌────────────────────────┬────────────────────────────────┐
   │ 8080  HTTP             │ chirpstack                     │
   │ UI and gRPC            │ no host port, TLS at the proxy │
   └────────────────────────┴────────────────────────────────┘
   │
   ┌──────────────────────────┬──────────────────────────────────┐
   │ 8090  HTTP               │ chirpstack-rest-api              │
   │ REST API                 │ forwards Authorization header    │
   └──────────────────────────┴──────────────────────────────────┘

╔════════════════════════════════════════════════════════════════════════════╗
║ STEP 3   still published on the host, pin them in .env if unused           ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
   ┌────────────────────────┬────────────────────────────────┐
   ├────▶ 1700  UDP         │ gateway-bridge                 │
   │ remote gateways only   │ SEMTECH_UDP_BIND               │
   └────────────────────────┴────────────────────────────────┘
   │
   ┌────────────────────────┬────────────────────────────────┐
   ├────▶ 3001  TCP         │ gateway-bridge                 │
   │ Basic Station node     │ BASIC_STATION_BIND             │
   └────────────────────────┴────────────────────────────────┘

╔════════════════════════════════════════════════════════════════════════════╗
║ STEP 4   never leaves the host, compose network only                       ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
   ┌─────────────┬─────────────┐
   │ mosquitto   │ postgres    │
   │ 1883  MQTT  │ 5432  SQL   │
   └─────────────┴─────────────┘
   │
   ┌─────────────┬─────────────────────┐
   │ redis       │ sx1302 forwarder    │
   │ 6379  cache │ no inbound port     │
   └─────────────┴─────────────────────┘

╔════════════════════════════════════════════════════════════════════════════╗
║ WHAT THIS ADDS UP TO                                                       ║
║                                                                            ║
║   inbound from a browser   ▶  nginx :443 ▶ site1 ▶ chirpstack :8080        ║
║   inbound from an API      ▶  nginx :443 ▶ site1 ▶ rest-api :8090          ║
║   inbound from a gateway   ▶  host :1700/udp, not proxied                  ║
║   outbound from a gateway  ▶  ttyACM0 ▶ bridge :1700 ▶ MQTT ▶ chirpstack   ║
║                                                                            ║
║   nothing in this stack speaks MQTT or UDP to the internet                 ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
```

## Legend

| Symbol | Meaning |
|--------|---------|
| `▶` | inbound connection accepted from outside the host |
| `▼` | the single entry point into the host network stack |
| `│` | host network stack, or the `site1` docker network |
| `─▶` | outbound traffic only, no listening socket |

## Published ports

Only two ports are published on the host now:

| Port | Proto | Service | Purpose |
|------|-------|---------|---------|
| 1700 | UDP | chirpstack-gateway-bridge | Semtech UDP protocol, for gateways on other hosts |
| 3001 | TCP | chirpstack-gateway-bridge-basicstation | Semtech Basic Station backend, EU868 |

Both default to `0.0.0.0` and can be pinned per interface with
`SEMTECH_UDP_BIND` and `BASIC_STATION_BIND` in `.env`. Neither is needed for a
single-host gateway: the on-host SX1302 reaches the bridge over the compose
network, and the Basic Station backend is unused without a separate node.

## Proxied, not published

`chirpstack` (8080) and `chirpstack-rest-api` (8090) publish no host port. They
join the external `site1` network, are discovered by `docker-gen`, and are
reached through `nginx-web` on 443 with TLS terminated there. See
[nginx-integration.md](nginx-integration.md).

## Never published

| Port | Proto | Service |
|------|-------|---------|
| 1883 | TCP | mosquitto, the MQTT broker |
| 5432 | TCP | postgres |
| 6379 | TCP | redis |
| none | | sx1302 forwarder, outbound UDP to the bridge only |

All four are reachable only on the compose network. The broker is anonymous,
which is acceptable on a private bridge network with nothing published. See the
recipe at the bottom of `configuration/mosquitto/config/mosquitto.conf` if you
need LAN access to it.

## Exposure warnings

- `api.secret` in `configuration/chirpstack/chirpstack.toml` is still
  `you-must-replace-this`. It signs UI sessions and API tokens, so anyone who
  can reach the UI through the proxy can mint an admin token. Generate one with
  `openssl rand -base64 32`. The reverse proxy does not fix this.
- `chirpstack-rest-api` adds no credentials of its own, it forwards whatever
  `Authorization` header the caller sends. `--insecure` is about the plaintext
  hop to `chirpstack:8080`, not about authentication, so the API is only as open
  as its tokens. There are none by default, which makes it unusable rather than
  open. See [rest-api.md](rest-api.md).
- The Basic Station backend has empty `tls_cert` and `tls_key`, so it is
  plaintext. Unused on a single-host setup; do not expose it as is.
- If the host has a routable interface, 1700 and 3001 are still open on every
  interfa