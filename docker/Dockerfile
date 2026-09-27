FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY sx1302_hal/ /src/
RUN make -j"$(nproc)" packet_forwarder


FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="SX1302 HAL packet forwarder" \
      org.opencontainers.image.description="Semtech SX1302 HAL lora_pkt_fwd for USB/SPI LoRa concentrators"

WORKDIR /opt/sx1302_hal

COPY --from=builder /src/packet_forwarder/lora_pkt_fwd /opt/sx1302_hal/lora_pkt_fwd
COPY sx1302_hal/tools/reset_lgw.sh /opt/sx1302_hal/reset_lgw.sh
COPY sx1302_hal/packet_forwarder/global_conf.json.sx1250.EU868.USB /opt/sx1302_hal/global_conf.json
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 0755 /opt/sx1302_hal/lora_pkt_fwd \
              /opt/sx1302_hal/reset_lgw.sh \
              /usr/local/bin/entrypoint.sh

ENV SX1302_CONFIG=/opt/sx1302_hal/global_conf.json \
    SX1302_COM_PATH=/dev/ttyACM0 \
    SX1302_GPS_PATH=/dev/ttyACM1 \
    SX1302_SERVER_ADDRESS=chirpstack-gateway-bridge \
    SX1302_SERV_PORT=1700 \
    SX1302_GATEWAY_ID=""

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
