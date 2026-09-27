#!/usr/bin/env bash
# Create or update the ChirpStack application and device profiles in
# configuration/device-profiles/lora-basics-modem.json.
#
# Idempotent. Everything is matched on name, so running it twice changes
# nothing and running it after editing the JSON pushes the edit. The profile
# IDs are left to ChirpStack to generate, and a profile keeps its ID across an
# update, so devices already bound to it do not have to be touched.
#
# Needs curl and jq, and an API key in CHIRPSTACK_API_KEY. See
# docs/rest-api.md for where to get one and how to reach the API, which
# publishes no host port.
#
#   CHIRPSTACK_API=http://127.0.0.1:8090 \
#   CHIRPSTACK_API_KEY="$TOKEN" \
#   tools/apply-device-profiles.sh
#
# --dry-run prints what it would do and writes nothing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFS="${DEFS:-$HERE/configuration/device-profiles/lora-basics-modem.json}"
API="${CHIRPSTACK_API:-http://127.0.0.1:8090}"
TENANT="${CHIRPSTACK_TENANT:-ChirpStack}"
DRY_RUN=false

# Overridable so the API can be reached from somewhere it has no direct route
# to, by pointing CURL at a wrapper. The host in this deployment answers that
# with "administratively prohibited" to every TCP forward, so the only way in is
# to run curl on the far side:
#
#   printf '#!/bin/sh\nexec ssh nas curl "$@"\n' > my-curl && chmod +x my-curl
#   CURL=./my-curl CHIRPSTACK_API=http://172.29.0.8:8090 tools/apply-device-profiles.sh
CURL="${CURL:-curl}"

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

for tool in curl jq; do
    command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

if [ -z "${CHIRPSTACK_API_KEY:-}" ]; then
    echo "CHIRPSTACK_API_KEY is not set. See docs/rest-api.md." >&2
    exit 1
fi

api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "$method" -H "Authorization: Bearer $CHIRPSTACK_API_KEY"
                -H "Content-Type: application/json" "$API$path")
    [ -n "$body" ] && args+=(--data-binary "$body")
    "$CURL" "${args[@]}"
}

# ChirpStack reports a failure as a JSON body carrying a gRPC code, and some of
# these come back on HTTP 200, so the payload has to be checked rather than the
# status line. Reads the body once and passes it through unchanged, otherwise
# the caller cannot read the id out of a successful response.
fail_on_error() {
    local body
    body="$(cat)"
    if jq -e 'has("code")' >/dev/null 2>&1 <<<"$body"; then
        echo "API error on $1: $(jq -r '.message' <<<"$body")" >&2
        return 1
    fi
    printf '%s' "$body"
}

echo "applying $(basename "$DEFS") via $API (tenant: $TENANT)"

# --- tenant ------------------------------------------------------------------
# The tenant always exists: ChirpStack seeds one on first start. Look it up
# rather than creating it, because a second tenant is a different problem and
# should not be papered over by a script.
TENANT_ID="$(api GET "/api/tenants?limit=100" \
    | jq -er --arg n "$TENANT" '.result[] | select(.name == $n) | .id')" \
    || { echo "no tenant named '$TENANT'" >&2; exit 1; }
echo "tenant $TENANT_ID"

# --- application -------------------------------------------------------------
# Listing applications needs a tenantId, unlike every other list endpoint.
# The tenant also has to be in the body of a create or update: the API parses it
# with Uuid::from_str and answers "invalid length: found 0" when it is missing.
# `// []` throughout: "not found" is the normal case here, and it must not print
# a jq parse error before the script creates the thing that is missing.
APP_ID="$(api GET "/api/applications?tenantId=$TENANT_ID&limit=100" \
    | jq -er --arg n "$(jq -r '.application.name' "$DEFS")" \
        '(.result // [])[] | select(.name == $n) | .id')" || APP_ID=""

APP_BODY="$(jq --arg t "$TENANT_ID" '.application + {tenantId: $t}' "$DEFS")"

if [ -n "$APP_ID" ]; then
    if $DRY_RUN; then
        echo "would update application $APP_ID"
    else
        api PUT "/api/applications/$APP_ID" \
            "$(jq -n --argjson a "$APP_BODY" '{application: $a}')" \
            | fail_on_error "PUT application" >/dev/null
        echo "updated application $APP_ID"
    fi
else
    if $DRY_RUN; then
        echo "would create application $(jq -r '.application.name' "$DEFS")"
        APP_ID="(dry-run)"
    else
        APP_ID="$(api POST "/api/applications" \
            "$(jq -n --argjson a "$APP_BODY" '{application: $a}')" \
            | fail_on_error "POST application" \
            | jq -er '.id')"
        echo "created application $APP_ID"
    fi
fi

# --- device profiles ---------------------------------------------------------
# The JSON names a codec file instead of inlining it, so the script is still
# able to read one. ChirpStack generates profile IDs itself and a PUT keeps the
# existing one, which is what keeps bound devices intact.
count="$(jq -r '.deviceProfiles | length' "$DEFS")"
for ((i = 0; i < count; i++)); do
    profile="$(jq --argjson i "$i" '.deviceProfiles[$i]' "$DEFS")"
    name="$(jq -r '.name' <<<"$profile")"
    codec_file="$(jq -r '.codecScript' <<<"$profile")"
    codec_path="$HERE/configuration/device-profiles/$codec_file"

    if [ ! -f "$codec_path" ]; then
        echo "codec file not found: $codec_path" >&2
        exit 1
    fi

    body="$(jq -n \
        --argjson p "$(jq --rawfile c "$codec_path" \
            'del(.codecScript) | .payloadCodecScript = $c' <<<"$profile")" \
        --arg t "$TENANT_ID" \
        '{deviceProfile: ($p + {tenantId: $t})}')"

    # Looked up through the tenant's profile list, not
    # /api/applications/$APP_ID/device-profiles: that one is the list of
    # profiles the application already has devices on, so it comes back empty
    # for a fresh profile and every run would create another one.
    id="$(api GET "/api/device-profiles?tenantId=$TENANT_ID&limit=100" \
        | jq -er --arg n "$name" '(.result // [])[] | select(.name == $n) | .id')" || id=""

    if [ -n "$id" ]; then
        verb="update"
        method="PUT"
        path="/api/device-profiles/$id"
    else
        verb="create"
        method="POST"
        path="/api/device-profiles"
    fi

    if $DRY_RUN; then
        echo "would $verb device profile '$name'"
    else
        api "$method" "$path" "$body" | fail_on_error "$verb $name" >/dev/null
        echo "$verb device profile '$name'"
    fi
done

# Not `[[ ... ]] && echo`: under `set -e` a false test as the last statement
# would become the script's exit status and report failure after succeeding.
if $DRY_RUN; then
    echo "dry run, nothing written"
fi
