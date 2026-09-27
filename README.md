# NAS LoRaWAN Gateway + Application Server

ChirpStack v4 application server with the Semtech SX1302 HAL packet forwarder
containerised for USB-attached concentrators.

## Layout

```
docker-compose.yml            full stack definition
docker/Dockerfile             builds the SX1302 HAL from source
docker/entrypoint.sh          patches device paths, starts the forwarder
configuration/                ChirpStack, gateway-bridge, mosquitto, postgres
sx1302_hal/                   vendored Semtech SX1302 HAL 2.1.0 sources
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
| 8080 | TCP | chirpstack | Web UI and gRPC API |
| 8090 | TCP | chirpstack-rest-api | REST API (runs `--insecure`) |
| 1883 | TCP | mosquitto | MQTT broker (anonymous) |
| 1700 | UDP | chirpstack-gateway-bridge | Semtech UDP protocol, used by the SX1302 forwarder |
| 3001 | TCP | chirpstack-gateway-bridge-basicstation | Semtech Basic Station backend, EU868 |

`postgres` (5432) and `redis` (6379) are not published; they are reachable only
on the compose network.

The forwarder service publishes no ports. It makes outbound UDP to
`chirpstack-gateway-bridge:1700`, so the gateway needs no inbound connectivity.

## Gateway paths into ChirpStack

Two independent paths feed the same ChirpStack instance over MQTT:

- **SX1302 HAL** (`lora_pkt_fwd`) speaks the legacy Semtech UDP protocol to port
  1700. This is the concentrator described above.
- **Basic Station** (port 3001) is for separate Basic Station nodes such as LoRa
  Basics Modem. `lora_pkt_fwd` does not speak Basic Station, so this service is
  unused unless such a node is deployed. Its backend is configured for EU868
  (863-870 MHz) in
  `configuration/chirpstack-gateway-bridge/chirpstack-gateway-bridge-basicstation-eu868.toml`.

## Gateway settings

`configuration/chirpstack/chirpstack.toml` enables 15 regions, each backed by a
`region_*.toml` file. Narrow this to `eu868` to reduce startup work.

The forwarder ships with `global_conf.json.sx1250.EU868.USB` and
`gateway_ID` `AA555A0000000000`. Change the gateway ID to the EUI64 returned by
`util_chip_id` (or `test_loragw_reg`) and register the same ID in ChirpStack.
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

Change these before exposing the host beyond a trusted LAN:

- `configuration/chirpstack/chirpstack.toml` `api.secret` is
  `you-must-replace-this`. Generate one with `openssl rand -base64 32`. It signs
  UI sessions and API tokens.
- `chirpstack-rest-api` runs with `--insecure`, disabling authentication, and is
  published on 8090.
- `configuration/mosquitto/config/mosquitto.conf` sets `allow_anonymous true`,
  so any host that can reach 1883 can read all gateway traffic and inject
  downlinks.
- The Basic Station backend has empty `tls_cert`/`tls_key`, so it is plaintext.

Loopback-bind the management ports if the host has a routable interface:

```yaml
ports:
  - "127.0.0.1:8080:8080"
  - "127.0.0.1:8090:8090"
  - "127.0.0.1:1883:1883"
```

## Upstream

- SX1302 HAL 2.1.0, `sx1302_hal/` (Semtech, Apache-2.0 / GPL-2.0)
- ChirpStack 4 configuration layout from
  `chirpstack/chirpstack-docker` (`configuration/`)
