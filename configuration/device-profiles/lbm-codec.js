// Payload codec for the LoRa Basics Modem (LBM).
//
// ChirpStack v4 JavaScript codec, TS013: a QuickJS runtime with `decodeUplink`
// and `encodeDownlink` taking one object and returning one object. The v3
// `Decode(fPort, bytes)` / `Encode(fPort, data)` signature does not work here.
//
// LBM is a stack library, not a product, so it has no single payload format. The
// application on top of it picks the fPort and the bytes. The ports below come
// from the modem itself and from the stock `main_periodical_uplink` example, so
// they are what a default LBM build emits:
//
//   101  periodical uplink, PERIODICAL_UPLINK_DELAY_S (60 s by default)
//   102  same counter, sent when the example's user button is pressed
//
// Both are produced by send_uplink_counter_on_port(), a 4-byte big-endian
// counter. Ports 199 to 202 are the modem's own service traffic, which
// ChirpStack consumes before the codec runs; they are listed here so that a copy
// still makes sense if one ever does arrive. Everything else is passed through
// as hex, because guessing at a format the profile cannot know would turn real
// data into a plausible-looking lie.
//
// If your firmware sends something else, replace decodeUplink and leave the
// service-port labels alone.

const COUNTER_PORTS = [101, 102];

const SERVICE_PORTS = {
  192: "GNSS/NAV position (LoRa Edge)",
  197: "WiFi scan (LoRa Edge)",
  199: "device management",
  200: "remote multicast setup (TS005)",
  201: "fragmentation (TS004)",
  202: "ALC sync (TS003)",
};

function toHex(bytes) {
  return bytes.map((b) => b.toString(16).padStart(2, "0")).join("");
}

function decodeCounter(bytes) {
  // Big-endian per the example, but read it as an unsigned 32-bit value so a
  // counter that has wrapped past 2^31 does not come out negative.
  return (
    bytes[0] * 0x1000000 +
    (bytes[1] << 16) +
    (bytes[2] << 8) +
    bytes[3]
  );
}

function decodeUplink(input) {
  const bytes = input.bytes || [];
  const errors = [];
  const warnings = [];

  if (COUNTER_PORTS.indexOf(input.fPort) >= 0) {
    if (bytes.length !== 4) {
      warnings.push(
        "fPort " + input.fPort + " carries a 4-byte counter, got " + bytes.length
      );
      return { data: { uplinkCounter: null, raw: toHex(bytes) }, warnings: warnings };
    }
    return { data: { uplinkCounter: decodeCounter(bytes) }, warnings: warnings };
  }

  if (SERVICE_PORTS[input.fPort] !== undefined) {
    // The modem handles these itself. If one shows up here it was forwarded
    // anyway, so keep the bytes rather than dropping them.
    return {
      data: { service: SERVICE_PORTS[input.fPort], raw: toHex(bytes) },
      warnings: warnings,
    };
  }

  warnings.push("no decoder for fPort " + input.fPort + ", raw bytes passed through");
  return { data: { raw: toHex(bytes) }, warnings: warnings };
}

function encodeDownlink(input) {
  // The stock example only traces what it receives (SMTC_MODEM_EVENT_DOWNDATA)
  // and never answers, so there is no downlink format to encode against. Bytes
  // are forwarded unchanged and the port is honoured, which is what an
  // application written for your own firmware will need.
  const data = input.data || {};
  const bytes = [];

  if (Array.isArray(data.bytes)) {
    bytes.push.apply(bytes, data.bytes);
  } else if (data.raw !== undefined) {
    const raw = String(data.raw);
    if (!/^[0-9a-fA-F]*$/.test(raw) || raw.length % 2 !== 0) {
      return { errors: ["raw must be an even number of hex digits"] };
    }
    for (let i = 0; i < raw.length; i += 2) {
      bytes.push(parseInt(raw.substr(i, 2), 16));
    }
  } else {
    return { errors: ["expected data.bytes (array) or data.raw (hex string)"] };
  }

  return {
    fPort: data.fPort,
    bytes: bytes,
    warnings: [
      "the stock LBM example prints downlinks and does not act on them",
    ],
  };
}
