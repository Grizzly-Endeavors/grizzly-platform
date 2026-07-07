#!/usr/bin/env bash
# Upsert the ansible-iac AppRole credentials into the encrypted Ansible
# vault at ansible/inventory/group_vars/all/vault.yml:
#
#   vault_openbao_approle_role_id      — AppRole role_id (stable)
#   vault_openbao_approle_secret_id    — AppRole secret_id (sensitive,
#                                        rotate via --rotate or by
#                                        re-running this script)
#
# These are the credentials Ansible playbooks present to OpenBao's
# approle auth method to fetch platform secrets. The AppRole itself is
# created by bootstrap-openbao.yml; this script just fetches role_id
# and mints a fresh secret_id, then writes both into the vault.
#
# Authenticates to OpenBao using the root token pulled from Infisical
# (the same universal-auth identity that auto-unseal uses). Requires
# `infisical` CLI logged in and `bao` CLI installed locally.
#
# Usage:
#   scripts/set-openbao-approle-secrets.sh          → mint new secret_id
#   scripts/set-openbao-approle-secrets.sh --rotate → same; explicit intent
#
# Idempotent: role_id is stable (overwritten with the same value), and
# a fresh secret_id is generated each run so you can rotate by just
# re-running. The previous secret_id is NOT revoked automatically —
# run `bao list auth/approle/role/ansible-iac/secret-id` and
# `bao delete auth/approle/role/ansible-iac/secret-id-accessor/<id>`
# if you need to invalidate old ones.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
VAULT_FILE="${REPO_ROOT}/ansible/inventory/group_vars/all/vault.yml"
VAULT_PASS="${REPO_ROOT}/.vault_pass"
INFISICAL_JSON="${REPO_ROOT}/.infisical.json"

log()  { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------
[[ -r "${VAULT_FILE}"     ]] || die "${VAULT_FILE} not readable"
[[ -r "${VAULT_PASS}"     ]] || die "${VAULT_PASS} not found"
[[ -r "${INFISICAL_JSON}" ]] || die "${INFISICAL_JSON} not found (project id)"
command -v ansible-vault >/dev/null || die "ansible-vault not on PATH"
command -v python3       >/dev/null || die "python3 not on PATH"
command -v infisical     >/dev/null || die "infisical CLI not on PATH"
command -v bao           >/dev/null || die "bao CLI not on PATH"
command -v jq            >/dev/null || die "jq not on PATH"

# --- fetch root token from Infisical ----------------------------------
PROJECT_ID="$(jq -r .workspaceId "${INFISICAL_JSON}")"
if [[ -z "${PROJECT_ID}" ]] || [[ "${PROJECT_ID}" == "null" ]]; then
    die "workspaceId missing in .infisical.json"
fi

log "fetching OpenBao root token from Infisical (project=${PROJECT_ID})"
ROOT_TOKEN="$(infisical secrets get OPENBAO_ROOT_TOKEN \
    --projectId="${PROJECT_ID}" --env=prod --plain --silent 2>/dev/null | tr -d '[:space:]')"
[[ -n "${ROOT_TOKEN}" ]] || die "could not fetch OPENBAO_ROOT_TOKEN from Infisical (run 'infisical login' first?)"

# --- talk to OpenBao --------------------------------------------------
# Address + CA are the canonical ones from the ADR. If you run this
# from off-LAN you'll hit the CIDR binding on the role anyway, so it's
# pointless to parameterize.
export VAULT_ADDR="https://10.0.0.200:8200"
export BAO_ADDR="${VAULT_ADDR}"
export VAULT_TOKEN="${ROOT_TOKEN}"
export BAO_TOKEN="${ROOT_TOKEN}"
# Trust the system CA bundle (the role installs the OpenBao CA there on
# the r730xd during deploy-openbao.yml, but the controller may not have
# imported it). Fall back to skip-verify only if the operator explicitly
# opts in — the risk is MITM on LAN, which we're not protecting against
# in any other way here either.
CA_PATH=""
for candidate in \
    "/etc/openbao/tls/ca.crt" \
    "/usr/local/share/ca-certificates/grizzly-platform-openbao-ca.crt" \
    "/usr/local/share/ca-certificates/lab-iac-openbao-ca.crt"; do
    if [[ -r "${candidate}" ]]; then
        CA_PATH="${candidate}"
        break
    fi
done
if [[ -n "${CA_PATH}" ]]; then
    export VAULT_CACERT="${CA_PATH}"
    export BAO_CACERT="${CA_PATH}"
    log "using CA bundle ${CA_PATH}"
else
    log "WARNING: no CA bundle found locally; set VAULT_CACERT or copy"
    log "         /etc/openbao/tls/ca.crt off r730xd"
fi

# --- fetch role_id + issue new secret_id ------------------------------
log "fetching ansible-iac role_id"
ROLE_ID="$(bao read -field=role_id auth/approle/role/ansible-iac/role-id)"
[[ -n "${ROLE_ID}" ]] || die "empty role_id — is bootstrap-openbao.yml run?"

log "issuing fresh secret_id"
SECRET_ID="$(bao write -f -field=secret_id auth/approle/role/ansible-iac/secret-id)"
[[ -n "${SECRET_ID}" ]] || die "empty secret_id from bao write"

# --- upsert into vault.yml --------------------------------------------
TMPDIR="$(mktemp -d)"
chmod 700 "${TMPDIR}"
trap 'rm -rf "${TMPDIR}"; unset VAULT_TOKEN BAO_TOKEN' EXIT
TMP_PLAIN="${TMPDIR}/vault.plain.yml"

log "decrypting vault.yml"
ansible-vault decrypt \
    --vault-password-file "${VAULT_PASS}" \
    --output "${TMP_PLAIN}" \
    "${VAULT_FILE}" >/dev/null
chmod 600 "${TMP_PLAIN}"

log "upserting AppRole keys"
RID="${ROLE_ID}" SID="${SECRET_ID}" FILE="${TMP_PLAIN}" python3 - <<'PY'
import os, re, sys, yaml
path = os.environ["FILE"]
rid  = os.environ["RID"]
sid  = os.environ["SID"]

with open(path) as f:
    text = f.read()

def quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

updates = {
    "vault_openbao_approle_role_id":   quote(rid),
    "vault_openbao_approle_secret_id": quote(sid),
}

appended = []
for key, val in updates.items():
    pattern = re.compile(rf"^{re.escape(key)}\s*:\s*.*$", re.MULTILINE)
    if pattern.search(text):
        text = pattern.sub(f"{key}: {val}", text)
    else:
        appended.append(f"{key}: {val}")

if appended:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n# OpenBao AppRole credentials for Ansible platform reads\n"
    text += "\n".join(appended) + "\n"

try:
    yaml.safe_load(text)
except yaml.YAMLError as e:
    sys.stderr.write(f"refusing to write: YAML parse failed after upsert: {e}\n")
    sys.exit(2)

with open(path, "w") as f:
    f.write(text)
PY

log "re-encrypting vault.yml"
ansible-vault encrypt \
    --vault-password-file "${VAULT_PASS}" \
    --encrypt-vault-id default \
    --output "${VAULT_FILE}" \
    "${TMP_PLAIN}" >/dev/null

log "verifying round-trip"
VERIFY="$(ansible-vault view --vault-password-file "${VAULT_PASS}" "${VAULT_FILE}" \
    | grep -E '^vault_openbao_approle_(role_id|secret_id):' || true)"
VERIFY_COUNT="$(printf '%s\n' "${VERIFY}" | wc -l)"
[[ "${VERIFY_COUNT}" == "2" ]] \
    || die "expected 2 keys in vault after upsert, got: ${VERIFY}"

log "done — role_id + secret_id present in ${VAULT_FILE}"
log "old secret_ids (if any) remain valid until explicitly revoked:"
log "  bao list -format=json auth/approle/role/ansible-iac/secret-id"
log "  bao delete auth/approle/role/ansible-iac/secret-id-accessor/<accessor>"
