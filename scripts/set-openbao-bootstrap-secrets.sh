#!/usr/bin/env bash
# Upsert the two OpenBao bootstrap secrets into the encrypted Ansible vault
# at ansible/inventory/group_vars/all/vault.yml:
#
#   vault_infisical_openbao_client_id
#   vault_infisical_openbao_client_secret
#
# These are the universal-auth credentials for the Infisical machine identity
# that openbao-auto-unseal.service uses to fetch unseal keys at every boot.
# See docs/decisions/023-self-hosted-openbao-on-r730xd.md.
#
# Usage:
#   scripts/set-openbao-bootstrap-secrets.sh
#     → prompts for both values (client_secret is read without echo)
#
#   scripts/set-openbao-bootstrap-secrets.sh --from-env
#     → reads INFISICAL_OPENBAO_CLIENT_ID / _CLIENT_SECRET from the env
#       (useful when piping in from a password manager)
#
# The script is idempotent: running it again with new values replaces the
# old entries in place without duplicating keys.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
VAULT_FILE="${REPO_ROOT}/ansible/inventory/group_vars/all/vault.yml"
VAULT_PASS="${REPO_ROOT}/.vault_pass"

log()  { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------
[[ -r "${VAULT_FILE}"  ]] || die "${VAULT_FILE} not readable"
[[ -r "${VAULT_PASS}"  ]] || die "${VAULT_PASS} not found — need the vault password"
command -v ansible-vault >/dev/null || die "ansible-vault not on PATH"
command -v python3       >/dev/null || die "python3 not on PATH"

# --- collect inputs ----------------------------------------------------
if [[ "${1:-}" == "--from-env" ]]; then
    CLIENT_ID="${INFISICAL_OPENBAO_CLIENT_ID:?unset}"
    CLIENT_SECRET="${INFISICAL_OPENBAO_CLIENT_SECRET:?unset}"
else
    read -rp "Infisical OpenBao client_id: " CLIENT_ID
    [[ -n "${CLIENT_ID}" ]] || die "client_id cannot be empty"
    read -rsp "Infisical OpenBao client_secret: " CLIENT_SECRET; echo
    [[ -n "${CLIENT_SECRET}" ]] || die "client_secret cannot be empty"
fi

# --- decrypt to tmp ---------------------------------------------------
TMPDIR="$(mktemp -d)"
chmod 700 "${TMPDIR}"
trap 'rm -rf "${TMPDIR}"' EXIT
TMP_PLAIN="${TMPDIR}/vault.plain.yml"

log "decrypting vault.yml"
ansible-vault decrypt \
    --vault-password-file "${VAULT_PASS}" \
    --output "${TMP_PLAIN}" \
    "${VAULT_FILE}" >/dev/null
chmod 600 "${TMP_PLAIN}"

# --- upsert the two keys ----------------------------------------------
# We deliberately don't round-trip the YAML through a parser: PyYAML would
# strip comments and re-order keys. Instead, replace in place with sed if
# the key exists; append to EOF if it doesn't. Values are written via
# python to handle quoting + special chars safely.
log "upserting OpenBao bootstrap keys"
CID="${CLIENT_ID}" CSEC="${CLIENT_SECRET}" FILE="${TMP_PLAIN}" python3 - <<'PY'
import os, re, sys, yaml
path  = os.environ["FILE"]
cid   = os.environ["CID"]
csec  = os.environ["CSEC"]

with open(path) as f:
    text = f.read()

def quote(s: str) -> str:
    # Double-quote + escape backslashes and double-quotes; YAML-safe.
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

updates = {
    "vault_infisical_openbao_client_id":     quote(cid),
    "vault_infisical_openbao_client_secret": quote(csec),
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
    text += "\n# OpenBao bootstrap — Infisical universal-auth machine identity\n"
    text += "\n".join(appended) + "\n"

# Validate YAML before writing back.
try:
    yaml.safe_load(text)
except yaml.YAMLError as e:
    sys.stderr.write(f"refusing to write: YAML parse failed after upsert: {e}\n")
    sys.exit(2)

with open(path, "w") as f:
    f.write(text)
PY

# --- re-encrypt in place ----------------------------------------------
# ansible.cfg already defines vault_password_file = .vault_pass, so
# passing --vault-password-file on the CLI would create a second identity
# with the same name ("default,default") and encrypt would refuse with
# "Specify the vault-id to encrypt with --encrypt-vault-id". Pin it.
log "re-encrypting vault.yml"
ansible-vault encrypt \
    --vault-password-file "${VAULT_PASS}" \
    --encrypt-vault-id default \
    --output "${VAULT_FILE}" \
    "${TMP_PLAIN}" >/dev/null

# --- verify -----------------------------------------------------------
log "verifying round-trip"
VERIFY="$(ansible-vault view --vault-password-file "${VAULT_PASS}" "${VAULT_FILE}" \
    | grep -E '^vault_infisical_openbao_client_(id|secret):' || true)"

VERIFY_COUNT="$(printf '%s\n' "${VERIFY}" | wc -l)"
[[ "${VERIFY_COUNT}" == "2" ]] \
    || die "expected 2 keys in vault after upsert, got: ${VERIFY}"

log "done — both keys present in ${VAULT_FILE}"
log "next: update openbao_infisical_project_id in ansible/inventory/group_vars/all/vars.yml,"
log "      then run: ansible-playbook -i ansible/inventory/r730xd.yml \\"
log "                  ansible/playbooks/deploy-openbao.yml \\"
log "                  --vault-password-file .vault_pass -v"
