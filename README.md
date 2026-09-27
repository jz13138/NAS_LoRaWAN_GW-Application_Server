# NAS LoRaWAN Gateway + Application Server

ChirpStack v4 application server with the Semtech SX1302 HAL packet forwarder
containerised for USB-attached concentrators.

## Layout

```
docker-compose.yml            full stack definition
docker/Dockerfile             builds the SX1302 HAL from source
docker/entrypoint.sh          patches device paths, starts the forwarder
configuration/                ChirpStack, gateway-bridge, mosquitto, postgres
configuration/device-profiles/  application + device profiles, and the LBM codec
tools/apply-device-profiles.sh   applies the above through the REST API
sx1302_hal/                   vendored Semtech SX1302 HAL 2.1.0 sources
.env.example                  reverse proxy hostnames and port bindings
docs/interface.md             external TCP/IP interface, published ports
docs/gateway-path.md          SX1302 -> NAS -> ttyACM0/ACM1 -> gateway bridge
docs/nginx-integration.md     nginx reverse proxy integration
docs/rest-api.md              REST API, API keys, device profiles
```

`sx1302_hal/` is unmodified upstream code. The deployment files live outside it,
so the HAL can be refreshed by replacing that directory.

## Hardware mapping

| Host device | Function |
|-------------|----------|
| `/dev/ttyACM0` | SX1302 concentrator (STM32 USB-SPI bridge) |
| `/dev/ttyACM1` | GPS receiver (NMEA) |

Both are mapped into the forwarder container. The GPS path and concentrator path
are overridable with `SX1302_GPS_PATH` and `SX1302_COM_PATH`.

## Build and run

```bash
docker compose build
docker compose up -d
```

The SX1302 HAL is compiled inside the image, so no build toolchain is needed on
the host and the HAL is not installed on the target.

The stack will not start the forwarder successfully unless the `ttyACM*` devices
exist. To confirm the rest of the stack independently:

```bash
docker compose up -d postgres redis mosquitto chirpstack chirpstack-rest-api
docker compose up -d chirpstack-gateway-bridge chirpstack-gateway-bridge-basicstation
```

## Published ports

| Port | Proto | Service | Purpose |
|------|-------|---------|---------|
| 1700 | UDP | chirpstack-gateway-bridge | Semtech UDP protocol, for gateways on other hosts |
| 3001 | TCP | chirpstack-gateway-bridge-basicstation | Semtech Basic Station backend, EU868 |

Both default to `0.0.0.0` and are settable per interface with
`SEMTECH_UDP_BIND` and `BASIC_STATION_BIND` in `.env`. On a single-host setup
neither is needed: the on-host SX1302 reaches the bridge over the compose
network, and the Basic Station backend is unused.

`chirpstack` (8080), `chirpstack-rest-api` (8090), `mosquitto` (1883),
`postgres` (5432) and `redis` (6379) are not published. They are reachable
only on the compose network, and the first three through the reverse proxy.
See [Reverse proxy](#reverse-proxy) below.

The forwarder service publishes no ports. It makes outbound UDP to
`chirpstack-gateway-bridge:1700`, so the gateway needs no inbound connectivity.

## Reverse proxy

The web UI and the REST API are meant to be reached through an nginx-proxy
setup, not directly. `chirpstack` and `chirpstack-rest-api` join the external
`site1` network so `docker-gen` can discover them, and publish no host port, so
the proxy is the only way in.

```sh
docker network create site1      # once, shared with the nginx stack
cp .env.example .env             # hostnames, mail address, port bindings
docker compose up -d --build
```

Every hostname in `.env` needs a DNS A record pointing at the proxy before the
first start, because the certificate is issued over the HTTP-01 challenge.
Leaving `VIRTUAL_HOST` empty keeps a service off the proxy and the stack still
comes up.

`chirpstack-rest-api` forwards the caller's `Authorization` header to
ChirpStack and adds no credentials of its own, so it is only as open as its
tokens are. `--insecure` is about the plaintext hop to `chirpstack:8080`, not
about authentication. There are no tokens by default, which makes the API
unusable rather than open, so still put an `htpasswd` file in place before
enabling its hostname.

[docs/nginx-integration.md](docs/nginx-integration.md) has the details: the
htpasswd recipe, splitting gRPC from the UI on port 8080, why `NETWORK_ACCESS=internal`
breaks this particular image, and why 1883 and 1700 cannot be proxied at all.
Its Troubleshooting section covers the two failure modes found in production:
a stale upstream after a container recreate (502 with `Connection refused` to
an old IP), and a failed nginx reload from a dangling certificate reference.

## Gateway paths into ChirpStack

Two independent paths feed the same ChirpStack instance over MQTT:

- **SX1302 HAL** (`lora_pkt_fwd`) speaks the legacy Semtech UDP protocol to port
  1700. This is the concentrator described above.
- **Basic Station** (port 3001) is for separate Basic Station nodes such as LoRa
  Basics Modem. `lora_pkt_fwd` does not speak Basic Station, so this service is
  unused unless such a node is deployed. Its backend is configured for EU868
  (863-870 MHz) in
  `configuration/chirpstack-gateway-bridge/chirpstack-gateway-bridge-basicstation-eu868.toml`.

## Device profiles

Basic Station is a gateway protocol, so a device profile says nothing about it.
A profile describes the end device behind the gateway, and for the Basic Station
path that is the LoRa Basics Modem. `configuration/device-profiles/` holds one
application and two profiles, applied with:

```bash
tools/apply-device-profiles.sh
```

| Profile | Class | Use it for |
|---------|-------|------------|
| `LoRa Basics Modem EU868 Class A` | A | the default build, 60 s periodical uplink, lowest power |
| `LoRa Basics Modem EU868 Class C` | C | server-initiated downlinks, FUOTA, remote multicast |

Both are OTAA, EU868 on the `eu868` region config, and carry `macVersion`
1.0.4 and `regParamsRevision` RP002-1.0.3 because that is what LBM implements,
which is not what the ChirpStack UI defaults to. Class B is off in both: it has
to be compiled into the firmware and needs beacon synchronisation.

The two are not "regular" and "low power" firmware. LBM ships as a stack
library with a board port on top, so both builds share a MAC version, a set of
fPorts and a payload format, and one profile would serve either. What genuinely
needs a second profile is Class C, because it changes what the server may do.

`lbm-codec.js` decodes the 4-byte counter that the stock
`main_periodical_uplink` example sends on fPort 101 every 60 s and on fPort 102
on a button press, labels the modem's own service ports, and passes anything
else through as hex. LBM's application layer picks the real format, so replace
the decoder if your firmware sends something else.

The profiles are in the repo because the UI is not a good place to keep them: a
profile edited in the UI is not reviewable, and the UI does not promise to keep
a profile's ID stable, which is what keeps already-registered devices bound to
it. `tools/apply-device-profiles.sh` matches on name, so a run after a JSON edit
pushes the change and leaves the IDs alone.

[docs/rest-api.md](docs/rest-api.md) has the API key setup the script needs.

## Gateway settings

`configuration/chirpstack/chirpstack.toml` enables 15 regions, each backed by a
`region_*.toml` file. Narrow this to `eu868` to reduce startup work.

The forwarder ships with `global_conf.json.sx1250.EU868.USB` and a placeholder
`gateway_ID` of `AA555A0000000000`. Start the stack once and read the real EUI64
from the startup log:

```bash
docker compose logs sx1302-hal-packet-forwarder | grep "concentrator EUI"
```

Then put it in `.env` as `SX1302_GATEWAY_ID` and enter the same value when
creating the gateway in the ChirpStack UI. Until both match, ChirpStack logs
`Update gateway state: Object does not exist` and drops every uplink. The
placeholder can still be used, but then that exact string is the gateway ID.

To use a different band or concentrator type, edit the `global_conf.json`
baked into the image and rebuild.

The forwarder default `server_address` is `localhost`, which is wrong in a
container. The entrypoint rewrites it to `chirpstack-gateway-bridge` along with
the device paths, so `SX1302_SERVER_ADDRESS` and `SX1302_SERV_PORT` exist as
overrides.

## GPIO reset

`docker/entrypoint.sh` installs `tools/reset_lgw.sh` next to the binary because
`lora_pkt_fwd` invokes it as `./reset_lgw.sh start`. The script drives GPIOs
23, 18, 22 and 13 through `/sys/class/gpio` to power up and reset the SX1302,
which is why `/sys/class/gpio` is bind-mounted.

That script always exits 0 even when the GPIO writes fail, so a permission
problem is silent and the concentrator is simply never powered. The entrypoint
warns when `/sys/class/gpio/export` is not writable. If the host exposes GPIOs
only through the newer `gpiochip` interface and has no legacy
`/sys/class/gpio`, `reset_lgw.sh` will not work and must be adapted.

## Security

- `configuration/chirpstack/chirpstack.toml` `api.secret` is
  `you-must-replace-this`. Generate one with `openssl rand -base64 32`. It signs
  UI sessions and API tokens, so anyone who can reach the UI can mint an admin
  token. The reverse proxy does not fix this.
- `chirpstack-rest-api` adds no credentials of its own, it forwards the
  caller's `Authorization` header. It is not published, and it is proxied. Put an
  `htpasswd` file in place before giving it a hostname. See
  [docs/rest-api.md](docs/rest-api.md).
- An API key minted for `tools/apply-device-profiles.sh` is a JWT with **no
  expiry**, because that is what ChirpStack issues. It stays valid until the row
  is deleted from the `api_key` table, so it is a permanent credential. Keep it
  out of the repo and out of shell history, and prefer
  `is_read_only = true` for anything that only reports. The
  `api.secret` in `chirpstack.toml` can mint one for anyone, so treat that file
  as the real root of trust.
- `configuration/mosquitto/config/mosquitto.conf` sets `allow_anonymous true`.
  That is now confined to the compose network because 1883 is not published.
  If you republish it, follow the `password_file` recipe at the bottom of that
  file, otherwise anyone who can reach it reads all gateway traffic and injects
  downlinks.
- The Basic Station backend has empty `tls_cert`/`tls_key`, so it is plaintext.
  Unused on a single-host setup, but do not expose it as is.
- 1700/udp and 3001/tcp still bind `0.0.0.0` by default. Pin them with
  `SEMTECH_UDP_BIND` and `BASIC_STATION_BIND` in `.env` if no remote gateway
  needs them.

The management ports used to be published on `0.0.0.0` and could be
loopback-bound instead:

```yaml
ports:
  - "127.0.0.1:8080:8080"
  - "127.0.0.1:8090:8090"
  - "127.0.0.1:1883:1883"
```

That is no longer necessary. They are not published at all, which is strictly
safer than loopback-binding them. See [Reverse proxy](#reverse-proxy).

## Upstream

- SX1302 HAL 2.1.0, `sx1302_hal/` (Semtech, Apache-2.0 / GPL-2.0)
- ChirpStack 4 configuration layout from
  `chirpstack/chirpstack-docker` (`configuration/`)
