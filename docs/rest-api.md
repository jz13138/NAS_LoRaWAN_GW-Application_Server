# ChirpStack REST API and device profiles

How to reach the management API, authenticate to it, and keep the application
and device profiles in version control instead of only in the web UI.

## `--insecure` is not what it looks like

`chirpstack-rest-api` is started as:

```yaml
command: --server chirpstack:8080 --bind 0.0.0.0:8090 --insecure
```

`--insecure` means "plaintext connection to the ChirpStack gRPC server". It is
the upstream side only. The four flags the binary accepts are `server`, `bind`,
`insecure` and `cors`, and none of them touches authentication.

The server adds no credentials of its own. It does not read an API key from the
environment, and it does not generate one. What it does is pass the caller's
`Authorization` header straight through to ChirpStack:

```
client ──Bearer <token>──▶ rest-api :8090 ──same header──▶ chirpstack :8080
```

So the API is **authenticated**, and the token belongs to whoever makes the
call. A request with no header comes back as:

```json
{"code": 16, "message": "no authorization provided", "details": []}
```

which is easy to misread as "this endpoint is open". It is the opposite: the
header is missing, and the token would have been checked had there been one.

That makes the nginx basic auth in [nginx-integration.md](nginx-integration.md)
a second layer rather than the only one, which is the better place to be. Keep
it.

## The paths are `/api/...`, not `/api/v1/...`

ChirpStack 4.19 serves the REST API under `/api`. The endpoints are:

| Method | Path |
|--------|------|
| `GET` | `/api/tenants?limit=100` |
| `POST` | `/api/applications` |
| `GET` | `/api/applications?tenantId=<uuid>&limit=100` |
| `POST` | `/api/device-profiles` |
| `GET` | `/api/device-profiles?tenantId=<uuid>&limit=100` |
| `PUT` | `/api/device-profiles/<uuid>` |
| `DELETE` | `/api/device-profiles/<uuid>` |

Two things cost time here. `/api/tenants` returns `totalCount` but an empty
`result` unless a `limit` is given. And `GET /api/applications` is the only list
endpoint that insists on a `tenantId`, answering `invalid length: found 0`
without one.

That same error comes back from a `POST` that leaves `tenantId` out of the
body. The application and the device profile both take their tenant as a field,
not from the URL:

```sh
jq '.application + {tenantId: $t}' ...
```

## Minting a key

An API key is a JWT signed with the `api.secret` from
`configuration/chirpstack/chirpstack.toml`, with four claims and no expiry:

```json
{"aud":"chirpstack","iss":"chirpstack","sub":"<api-key-uuid>","typ":"key"}
```

`typ: "key"` is what makes ChirpStack treat it as an API key rather than a login
session, and `sub` is the row id in the `api_key` table. Both halves are
needed: the token is worthless without the row, and the row is meaningless
without the token.

An API key also has no `exp`, so it does not expire on its own. Deleting the row
revokes it immediately, which is the only off switch. Treat it as a permanent
credential and keep it out of the repo: `.env` is gitignored, the API section of
`chirpstack.toml` is not.

```sh
# 1. a UUID for the key, and the row that makes it real
KEY_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')

docker compose exec -T postgres psql -U chirpstack -d chirpstack \
  -c "insert into api_key (id, created_at, name, is_admin, tenant_id, is_read_only)
      values ('$KEY_ID', now(), 'automation', true, null, false)"

# 2. sign the claims. HS256 over the raw bytes of the secret string, not its
#    base64-decoded contents. auth/claims.rs in the ChirpStack source is the
#    reference if this ever stops working.
SECRET=$(sed -n 's/^  secret="\(.*\)"$/\1/p' configuration/chirpstack/chirpstack.toml)

python3 - "$KEY_ID" "$SECRET" <<'PY' > /tmp/chirpstack-api-key
import base64, hashlib, hmac, json, sys
key_id, secret = sys.argv[1], sys.argv[2].encode()
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=")
header = {"alg": "HS256", "typ": "JWT"}
claims = {"aud": "chirpstack", "iss": "chirpstack", "sub": key_id, "typ": "key"}
signing = b64(json.dumps(header, separators=(",", ":")).encode()) + b"." \
        + b64(json.dumps(claims, separators=(",", ":")).encode())
print((signing + "." + b64(hmac.new(secret, signing, hashlib.sha256).digest())).decode())
PY
```

Set `tenant_id` to the tenant uuid for a key scoped to one tenant, or leave it
null for a global admin key. Leave `is_read_only` true for anything that only
reports.

## Reaching it

The API publishes no host port, and on this host sshd refuses every TCP forward
with `administratively prohibited`. So there is no `ssh -L` shortcut. Two
options that work:

Point at the container's address on the compose network, and run `curl` on the
NAS:

```sh
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  lorawan-chirpstack-rest-api-1
```

Or publish the port on the loopback interface and forward that:

```yaml
ports:
  - "127.0.0.1:8090:8090"
```

Loopback is not reachable over ssh either, so this only helps from the NAS
itself. It does make `curl` from a shell on the box straightforward, which is
worth the two lines if this API is going to be used by hand.

## Applying the device profiles

The definitions live in
`configuration/device-profiles/lora-basics-modem.json` with the payload codec
next to them in `lbm-codec.js`. `tools/apply-device-profiles.sh` reads both and
creates or updates what is missing or stale, matching on name:

```sh
export CHIRPSTACK_API=http://172.29.0.8:8090
export CHIRPSTACK_API_KEY=$(cat /tmp/chirpstack-api-key)

tools/apply-device-profiles.sh --dry-run   # show the plan
tools/apply-device-profiles.sh             # apply it
```

Running it twice changes nothing. ChirpStack generates the profile ids and a
`PUT` keeps the existing one, so devices already bound to a profile are not
disturbed by a later edit to the JSON. That is the reason to prefer the script
over the UI: the UI has no such guarantee about what it does to a profile.

If the API is only reachable by running `curl` on the NAS, point the script at a
wrapper:

```sh
printf '#!/bin/sh\nexec ssh nas curl "$@"\n' > my-curl && chmod +x my-curl
CURL=./my-curl tools/apply-device-profiles.sh
```

## What the profiles assume

The two profiles are for the LoRa Basics Modem, one Class A and one Class C.
They carry `macVersion: LORAWAN_1_0_4` and `regParamsRevision: RP002_1_0_3`
because that is what LBM implements, which is not what the ChirpStack UI
defaults to. The reasoning for each field is in the `_comment` block in the
JSON, so it stays with the values it explains.

`appLayerParams` is left with its server-side TS003/TS004/TS005 versions at
`NOT_IMPLEMENTED`. Those fPorts are LBM's own (199 device management, 200
multicast, 201 fragmentation, 202 ALC sync) and the modem handles them itself,
so the server does not need to agree with them. If a ChirpStack-side
implementation is ever switched on, the fPorts have to be set to match or the
traffic will be misread.

The codec decodes the 4-byte big-endian counter that the stock
`main_periodical_uplink` example puts on fPort 101 every 60 s and on fPort 102
when the user button is pressed, labels the modem's own service ports, and
passes everything else through as hex. LBM is a stack library, so its
application layer decides the real format; that example is the only payload
format that can be asserted from the source. `lbm-codec.js` says so at the top.
