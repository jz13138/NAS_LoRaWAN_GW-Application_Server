# External TCP/IP interface

Everything the stack accepts from outside the host, and everything it opens
outbound. Derived from `docker-compose.yml` and the published-ports table in
`README.md`.

For the other half of the picture, the USB side that carries packets from the
concentrator into the stack, see [gateway-path.md](gateway-path.md).

```
┌───────────────────────────────────────┐
│  LAN / Internet  ·  external clients   │
└──┬────────────────────────────────────┘
   ▼
╔══╪══════════════════════════════════════════════════════════════╗
║  NAS HOST  ·  docker compose  ·  ports bind 0.0.0.0             ║
║  │                                                               ║
║  │      ┌────────────────────────┬────────────────────────┐     ║
║  ├─────▶│ TCP  :8080             │ chirpstack             │     ║
║  │      │ Web UI + gRPC API     │ api.secret = default   │     ║
║  │      └────────────────────────┴────────────────────────┘     ║
║  │      ┌────────────────────────┬────────────────────────┐     ║
║  ├─────▶│ TCP  :8090             │ chirpstack-rest-api    │     ║
║  │      │ REST API              │ --insecure, no auth    │     ║
║  │      └────────────────────────┴────────────────────────┘     ║
║  │      ┌────────────────────────┬────────────────────────┐     ║
║  ├─────▶│ TCP  :1883             │ mosquitto              │     ║
║  │      │ MQTT broker           │ allow_anonymous true   │     ║
║  │      └────────────────────────┴────────────────────────┘     ║
║  │      ┌────────────────────────┬────────────────────────┐     ║
║  ├─────▶│ TCP  :3001             │ gateway-bridge         │     ║
║  │      │ Basic Station         │ empty tls_cert / key   │     ║
║  │      └────────────────────────┴────────────────────────┘     ║
║  │      ┌────────────────────────┬────────────────────────┐     ║
║  ├─────▶│ UDP  :1700             │ gateway-bridge         │     ║
║  │      │ Semtech UDP fwd       │ from SX1302 gateways   │     ║
║  │      └────────────────────────┴────────────────────────┘     ║
║  │                                                               ║
║  └───────────────────────────────────────────────────────────────║
╚════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════╗
║  NOT published — reachable only on the compose network         ║
║  │                                                               ║
║  ├──▶┌────────────────┐  ┌──────────────┐  ┌────────────────┐  ║
║  │   │ postgres       │  │ redis        │  │ sx1302 forwarder│  ║
║  │   │ 5432/tcp       │  │ 6379/tcp     │  │ no inbound port │  ║
║  │   └────────────────┘  └──────────────┘  └───────┬────────┘  ║
║  │                                                  │           ║
║  └──────────────────────────────────────────────────┼───────────╯
║                                                     │ outbound UDP
║        ┌────────────────────────────────────────────▼──────────┐
║        │  SX1302 forwarder  ──UDP out──▶  gateway-bridge :1700  │
║        └─────────────────────────────────────────────────────────┘
╚════════════════════════════════════════════════════════════════╝
```

## Legend

| Symbol | Meaning |
|--------|---------|
| `▶` | inbound connection accepted from outside the host |
| `▼` | the single entry point into the host network stack |
| `│` | host network stack / compose network boundary |
| `─▶` | outbound traffic only, no listening socket |

## Published ports

| Port | Proto | Service | Purpose |
|------|-------|---------|---------|
| 8080 | TCP | chirpstack | Web UI and gRPC API |
| 8090 | TCP | chirpstack-rest-api | REST API (runs `--insecure`) |
| 1883 | TCP | mosquitto | MQTT broker (anonymous) |
| 3001 | TCP | chirpstack-gateway-bridge-basicstation | Semtech Basic Station backend, EU868 |
| 1700 | UDP | chirpstack-gateway-bridge | Semtech UDP protocol, used by the SX1302 forwarder |

`postgres` (5432) and `redis` (6379) are not published; they are reachable only
on the compose network. The forwarder service publishes no ports and makes
outbound UDP to `chirpstack-gateway-bridge:1700`, so the gateway needs no
inbound connectivity.

## Exposure warnings

All five published ports bind to `0.0.0.0` and are therefore reachable from any
routable interface on the host:

- `api.secret` is `you-must-replace-this` in `configuration/chirpstack/chirpstack.toml`.
- `chirpstack-rest-api` runs with `--insecure`, disabling authentication.
- `mosquitto.conf` sets `allow_anonymous true`, so any host that reaches 1883 can
  read all gateway traffic and inject downlinks.
- The Basic Station backend has empty `tls_cert`/`tls_key`, so it is plaintext.

Loopback-bind the management ports if the host has a routable interface:

```yaml
ports:
  - "127.0.0.1:8080:8080"
  - "127.0.0.1:8090:8090"
  - "127.0.0.1:1883:1883"
```
