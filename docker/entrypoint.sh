#!/bin/sh
set -e

SRC_CONFIG="${SX1302_CONFIG:-/opt/sx1302_hal/global_conf.json}"
CONFIG=/tmp/global_conf.json

cp "$SRC_CONFIG" "$CONFIG"

set_key() {
    key="$1"
    value="$2"
    line="$(grep -m 1 "\"$key\"" "$CONFIG" || true)"
    if [ -z "$line" ]; then
        echo "entrypoint: key '$key' not found in $CONFIG" >&2
        return
    fi
    case "$line" in
        *': "'*) replacement="\"$key\": \"$value\"" ;;
        *) replacement="\"$key\": $value" ;;
    esac
    sed -i "s|\"$key\"[[:space:]]*:[[:space:]]*[^,]*|$replacement|" "$CONFIG"
}

set_key com_path "${SX1302_COM_PATH:-/dev/ttyACM0}"
set_key gps_tty_path "${SX1302_GPS_PATH:-/dev/ttyACM1}"
set_key server_address "${SX1302_SERVER_ADDRESS:-chirpstack-gateway-bridge}"
set_key serv_port_up "${SX1302_SERV_PORT:-1700}"
set_key serv_port_down "${SX1302_SERV_PORT:-1700}"

# The shipped gateway_ID is a placeholder. The real EUI64 is printed by the HAL
# at startup as "concentrator EUI: 0x...", and it has to match the gateway
# registered in ChirpStack or every PUSH_DATA is dropped as unknown.
if [ -n "${SX1302_GATEWAY_ID:-}" ]; then
    set_key gateway_ID "$SX1302_GATEWAY_ID"
fi

for dev in "${SX1302_COM_PATH:-/dev/ttyACM0}" "${SX1302_GPS_PATH:-/dev/ttyACM1}"; do
    if [ ! -e "$dev" ]; then
        echo "entrypoint: $dev is missing" >&2
    fi
done

if [ -e /sys/class/gpio ] && [ ! -w /sys/class/gpio/export ]; then
    echo "entrypoint: /sys/class/gpio is not writable, the SX1302 will not be reset or powered up." >&2
    echo "entrypoint: mount the host GPIO sysfs read-write or run the container privileged." >&2
fi

exec /opt/sx1302_hal/lora_pkt_fwd -c "$CONFIG" "$@"
