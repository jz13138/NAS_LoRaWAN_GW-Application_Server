# Gateway path: SX1302 -> NAS -> gateway bridge

How an uplink travels from the concentrator into ChirpStack, and how a downlink
travels back. Derived from `docker-compose.yml`, `docker/Dockerfile`,
`docker/entrypoint.sh`, `sx1302_hal/packet_forwarder/global_conf.json.sx1250.EU868.USB`
and `sx1302_hal/tools/reset_lgw.sh`.

This is the opposite view of [interface.md](interface.md): that file covers what
the host accepts from the network, this one covers the USB side that never
touches TCP/IP at all.

```
╔════════════════════════════════════════════════════════════════════════════╗
║ GATEWAY PATH   SX1302 ↔ NAS ↔ ttyACM0 / ttyACM1 ↔ gateway bridge           ║
║                                                                            ║
║ STEP 1   hardware and USB enumeration                                      ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

 ┌───────────────┐                  ┌────────────────────────────────────┐
 │ GPS receiver  │                  │ SX1302 CoreCell concentrator       │
 │ NMEA + PPS    │                  │ SX1302 + 2x SX1250 + STM32         │
 │ own USB cable │                  │ USB-SPI bridge                     │
 └───────────────┘                  └────────────────────────────────────┘
         │  USB  CDC-ACM                               │  USB  CDC-ACM
         ▼                                             ▼
   /dev/ttyACM1                                  /dev/ttyACM0
     time only                                   SPI + payload
         │                                             │
         └─────────────────────────────────────────────┴
                                ▼
 ┌────────────────────────────────────────────────────────────┐
 │ NAS host  ·  USB bus  ·  cdc_acm driver  ·  ttyACM nodes   │
 └────────────────────────────────────────────────────────────┘

  The device numbers come from USB enumeration order, not from the hardware.
  A re-plug or a different boot order can swap ttyACM0 and ttyACM1; check with
  ls /dev/ttyACM* /dev/serial/by-id/ and set SX1302_COM_PATH / SX1302_GPS_PATH.

╔══════════════════════════════════════════════════════════════════════════╗
║ STEP 2   host → container, docker device pass-through                    ║
║                                                                          ║
║   devices:                                                               ║
║     - "/dev/ttyACM0:/dev/ttyACM0"      SX1302_COM_PATH                   ║
║     - "/dev/ttyACM1:/dev/ttyACM1"      SX1302_GPS_PATH                   ║
║   volumes:                                                               ║
║     - /sys/class/gpio:/sys/class/gpio  legacy GPIO, reset only           ║
║                                                                          ║
║   the container opens the same host device node, it is not a copy        ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

                                      │
                                      ▼

╔══════════════════════════════════════════════════════════════════════════╗
║ STEP 3   inside the sx1302-hal-packet-forwarder container                ║
║                                                                          ║
║   /usr/local/bin/entrypoint.sh                                           ║
║     cp $SX1302_CONFIG  →  /tmp/global_conf.json   (writable copy)        ║
║     set_key rewrites the five values below in that copy                  ║
║     exec /opt/sx1302_hal/lora_pkt_fwd -c /tmp/global_conf.json           ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

  global_conf.json key      env override              value written by entrypoint
  ──────────────────────────────────────────────────────────────────────────
com_path                   SX1302_COM_PATH           /dev/ttyACM0
gps_tty_path               SX1302_GPS_PATH           /dev/ttyACM1
server_address             SX1302_SERVER_ADDRESS     chirpstack-gateway-bridge
serv_port_up               SX1302_SERV_PORT          1700
serv_port_down             SX1302_SERV_PORT          1700

╔══════════════════════════════════════════════════════════════════════════╗
║ STEP 4   reset and power, before any packet is forwarded                 ║
║                                                                          ║
║   lora_pkt_fwd calls ./reset_lgw.sh start                                ║
║         ↓ writes /sys/class/gpio/gpioN/value                             ║
║                                                                          ║
║   GPIO 18  SX1302 power enable, LDO on          1                        ║
║   GPIO 23  SX1302 reset                         1 then 0                 ║
║   GPIO 22  SX1261 reset, LBT and spectral scan  0 then 1                 ║
║   GPIO 13  AD5338R ADC reset, CN490 only        0 then 1                 ║
║                                                                          ║
║   the script always exits 0, so a permission fault is silent             ║
║   and the concentrator simply never powers up                            ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════════════╗
║ STEP 5   the two traffic directions                                      ║
║                                                                          ║
║   UP    ttyACM0  read/write  →  SX1302 registers and packet memory       ║
║         lora_pkt_fwd  ── UDP 1700 ──▶  chirpstack-gateway-bridge         ║
║         PUSH_DATA carries received packets plus gateway status           ║
║         PULL_DATA is the 10 s keepalive timer                            ║
║                                                                          ║
║   DOWN  chirpstack-gateway-bridge  ── UDP 1700 ──  lora_pkt_fwd          ║
║         PULL_DATA response carries the transmit queue                    ║
║         ttyACM0 write  →  SX1302 starts a radio transmission             ║
║                                                                          ║
║   GPS   ttyACM1  ── NMEA ──  lora_pkt_fwd                                ║
║         GPS epoch is attached to every uplink timestamp                  ║
║         without it ChirpStack rejects packets on a moving gateway        ║
║                                                                          ║
║   MQTT  gateway-bridge  ── 1883 ──  mosquitto  ──  chirpstack            ║
║         eu868/gateway/<gw-id>/event/up  →  ChirpStack packet router      ║
║         postgres 5432 and redis 6379, compose network only               ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════════════╗
║ THE WHOLE CHAIN, ONE LINE                                                  ║
║                                                                            ║
║   SX1302  ⇄  USB  ⇄  /dev/ttyACM0  ⇄  lora_pkt_fwd  ⇄  UDP:1700            ║
║         ⇄  gateway-bridge  ⇄  MQTT:1883  ⇄  mosquitto                      ║
║         ⇄  chirpstack  ⇄  postgres / redis                                 ║
║                                                                            ║
║   GPS rx  ⇄  USB  ⇄  /dev/ttyACM1  ⇄  lora_pkt_fwd  (timestamps only)      ║
║                                                                            ║
║   reset   ⇄  /sys/class/gpio  ⇄  GPIO 18 / 23  (power and reset)           ║
║                                                                            ║
║   there is no TCP on the gateway path, only USB and UDP                    ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
```

## The five steps

| Step | Where | What happens |
|------|-------|--------------|
| 1 | hardware | The SX1302 CoreCell and the GPS receiver each enumerate as their own CDC-ACM device. The STM32 on the CoreCell bridges the internal SPI bus to USB. |
| 2 | host to container | `devices:` maps the two host nodes into the forwarder container unchanged. `/sys/class/gpio` is bind-mounted for the reset script. |
| 3 | entrypoint | `entrypoint.sh` copies `global_conf.json` to `/tmp`, rewrites the five path and address keys from the environment, then `exec`s `lora_pkt_fwd`. |
| 4 | reset | `lora_pkt_fwd` calls `./reset_lgw.sh start`, which powers and resets the concentrator through GPIO before any packet is forwarded. |
| 5 | traffic | `lora_pkt_fwd` speaks the Semtech UDP protocol to the gateway bridge, which republishes everything over MQTT for ChirpStack. |

## Device node mapping

| Host node | Inside the container | `global_conf.json` key | Carries |
|-----------|----------------------|------------------------|---------|
| `/dev/ttyACM0` | `/dev/ttyACM0` | `com_path` | SPI register reads and writes, TX packets, RX packets |
| `/dev/ttyACM1` | `/dev/ttyACM1` | `gps_tty_path` | NMEA sentences, GPS epoch for packet timestamps |
| `/sys/class/gpio` | same path | not in the config file | power enable and reset, GPIO 18 / 23 / 22 / 13 |

The ACM numbers are assigned by USB enumeration order, not by the hardware. A
re-plug or a different boot order can swap them, which shows up as a gateway that
never appears in ChirpStack. Use `/dev/serial/by-id/` or set `SX1302_COM_PATH`
and `SX1302_GPS_PATH` to pin them.

## No TCP anywhere on this path

The concentrator side is USB CDC-ACM and the uplink is UDP 1700. Nothing in this
chain is TCP, and none of it is reachable from outside the host except the
bridge's published UDP 1700, which exists for other gateways rather than for
this one.

## Failure modes worth knowing

- `reset_lgw.sh` always exits 0. A missing or read-only `/sys/class/gpio/export`
  is silent, the concentrator is never powered, and the forwarder just retries.
  The entrypoint warns on this case, but nothing else does.
- On hosts that only expose the newer `gpiochip` interface and have no legacy
  `/sys/class/gpio`, the reset script cannot work and must be adapted.
- `gateway_ID` is `AA555A0000000000` in the baked-in config. It has to match the
  ID registered in ChirpStack, otherwise every `PUSH_DATA` is discarded as an
  unknown gateway. Take the real value from `util_chip_id` or
  `test_loragw_reg`.
- Without GPS time on `ttyACM1`, a moving gateway produces uplocks ChirpStack
  rejects, even though the radio path itself is fine.
- `server_address` is `localhost` in the shipped `global_conf.json` and is
  rewritten to `chirpstack-gateway-bridge` by the entrypoint. Running
  `lora_pkt_fwd` outside the entrypoint leaves it pointing at the container
  itself.
