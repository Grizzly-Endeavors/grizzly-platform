#!/usr/bin/env bash
# Register a data source in Metabase from credentials held in 1Password.
#
# Why this exists: a Metabase data source is normally added by typing a
# password into a browser form, which leaves no record of what is connected
# and invites pasting an app's *owner* credential in a hurry. This script adds
# a connection using only the read-only `metabase_ro` accounts provisioned by
# ansible/playbooks/setup-metabase-stores.yml, and never prints the password.
#
# Reaches Metabase by port-forwarding its ClusterIP Service, which bypasses the
# Authentik forward-auth gate on the public hostname — an X-API-Key request
# through that gate would be answered by the outpost's sign-in redirect, not by
# Metabase.
#
# Usage:
#   scripts/metabase-add-database.sh postgres grizzly_gameservers
#   scripts/metabase-add-database.sh clickhouse langfuse
#
# Auth: reads the Metabase API key from 1Password (platform-metabase/api_key),
# or from MB_API_KEY if it is already set. Mint the key once in the UI under
# Admin -> Settings -> Authentication -> API keys, in the Administrators group.
#
# Idempotent: a data source whose name already exists is left alone. To rotate
# a stored password, delete the connection in the UI and re-run.

set -euo pipefail

ENGINE="${1:-}"
DATABASE="${2:-}"

OP_TOKEN_FILE="${OP_TOKEN_FILE:-${HOME}/.config/op-tokens/operator}"
OP_VAULT="${OP_VAULT:-grizzly-platform}"
NAMESPACE="metabase"
SERVICE="svc/metabase"
LOCAL_PORT="${MB_LOCAL_PORT:-3456}"
STORE_HOST="10.0.0.200"

PF_PID=""
PAYLOAD_FILE=""

log() { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC2317  # invoked by trap, not by fallthrough
cleanup() {
  [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null
  [[ -n "${PAYLOAD_FILE}" ]] && rm -f "${PAYLOAD_FILE}"
  return 0
}
trap cleanup EXIT

usage() {
  cat >&2 <<'USAGE'
usage: metabase-add-database.sh <postgres|clickhouse> <database>

  postgres <db>    Adds the foundation Postgres database <db>, connected as
                   metabase_ro. The database must already be listed in
                   metabase_readonly_databases in setup-metabase-stores.yml
                   and the play re-run, or the connection will save and then
                   show no tables.

  clickhouse <db>  Adds the foundation ClickHouse database <db>, connected as
                   metabase_ro.
USAGE
  exit 2
}

[[ -n "${ENGINE}" && -n "${DATABASE}" ]] || usage
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v jq >/dev/null || die "jq not on PATH"

# --- credentials ------------------------------------------------------------

# Prints one 1Password field on stdout. The token is read into a variable first
# so a missing/unreadable token file fails here rather than silently producing
# an empty credential.
read_op_field() {
  local item="$1" field="$2" token
  [[ -r "${OP_TOKEN_FILE}" ]] || die "no 1Password service token at ${OP_TOKEN_FILE}"
  token="$(cat "${OP_TOKEN_FILE}")"
  OP_SERVICE_ACCOUNT_TOKEN="${token}" \
    op item get "${item}" --vault "${OP_VAULT}" --fields "${field}" --reveal 2>/dev/null
}

if [[ -z "${MB_API_KEY:-}" ]]; then
  command -v op >/dev/null || die "op not on PATH and MB_API_KEY is unset"
  MB_API_KEY="$(read_op_field platform-metabase api_key)"
fi
[[ -n "${MB_API_KEY}" ]] || die "Metabase API key is empty"

case "${ENGINE}" in
  postgres)
    DB_PORT=5432
    DB_PASS="$(read_op_field stores-metabase readonly_db_password)"
    ;;
  clickhouse)
    DB_PORT=8123
    DB_PASS="$(read_op_field stores-metabase clickhouse_password)"
    ;;
  *)
    usage
    ;;
esac
DB_USER="metabase_ro"
[[ -n "${DB_PASS}" ]] || die "credential for ${ENGINE} is empty in 1Password"

# --- reach metabase ---------------------------------------------------------

kubectl -n "${NAMESPACE}" get "${SERVICE}" >/dev/null 2>&1 \
  || die "${SERVICE} not found in namespace ${NAMESPACE} — is Metabase deployed?"

kubectl -n "${NAMESPACE}" port-forward "${SERVICE}" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!

MB="http://127.0.0.1:${LOCAL_PORT}"
READY=""
for _ in $(seq 1 30); do
  if curl -sf "${MB}/api/health" >/dev/null 2>&1; then
    READY=yes
    break
  fi
  sleep 1
done
[[ -n "${READY}" ]] || die "Metabase did not answer on ${MB} — check the pod is Ready"

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "${method}" "${MB}${path}" \
    -H "X-API-Key: ${MB_API_KEY}" \
    -H 'Content-Type: application/json' "$@"
}

CURRENT_USER="$(api GET /api/user/current)"
printf '%s' "${CURRENT_USER}" | jq -e '.id' >/dev/null \
  || die "API key rejected — mint a new one under Admin -> Settings -> Authentication"

# --- add the connection -----------------------------------------------------

EXISTING="$(api GET /api/database)"
if printf '%s' "${EXISTING}" | jq -e --arg n "${DATABASE}" '.data[]? | select(.name == $n)' >/dev/null; then
  log "data source '${DATABASE}' already exists — leaving it alone"
  exit 0
fi

# The password goes in through a file so it never appears in the process table.
PAYLOAD_FILE="$(mktemp)"
chmod 600 "${PAYLOAD_FILE}"

jq -n \
  --arg name "${DATABASE}" \
  --arg engine "${ENGINE}" \
  --arg host "${STORE_HOST}" \
  --arg dbname "${DATABASE}" \
  --arg user "${DB_USER}" \
  --arg pass "${DB_PASS}" \
  --argjson port "${DB_PORT}" \
  '{
     name: $name,
     engine: $engine,
     details: {
       host: $host,
       port: $port,
       dbname: $dbname,
       user: $user,
       password: $pass,
       ssl: false
     }
   }' > "${PAYLOAD_FILE}"

RESPONSE="$(api POST /api/database --data @"${PAYLOAD_FILE}")"
DB_ID="$(printf '%s' "${RESPONSE}" | jq -r '.id // empty')"
if [[ -z "${DB_ID}" ]]; then
  REASON="$(printf '%s' "${RESPONSE}" | jq -r '.message // .')"
  die "Metabase refused the connection: ${REASON}"
fi

log "added '${DATABASE}' as ${ENGINE} data source ${DB_ID}"

# Schema sync is asynchronous. Kick it now so the tables show up without
# waiting for the hourly scan — a connection that looks empty for an hour reads
# as a broken grant.
api POST "/api/database/${DB_ID}/sync_schema" >/dev/null
log "schema sync requested; tables appear once it finishes (seconds, not minutes)"
