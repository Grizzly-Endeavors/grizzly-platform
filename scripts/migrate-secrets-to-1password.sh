#!/usr/bin/env bash
# Copy every OpenBao KV secret into the 1Password `grizzly-platform` vault and
# verify each field byte-for-byte against its source.
#
# Idempotent: an item that already exists is replaced, so re-running converges
# rather than duplicating. Replacement (delete + create) rather than edit keeps
# the field set exactly in sync — an edit would leave behind fields that have
# since been removed from OpenBao.
#
# Item naming mirrors the OpenBao path so remoteRef keys stay a 1:1 map:
#   secret/grizzly-platform/<domain>/<name>  ->  <domain>-<name>
#   secret/lab-apps/<app>/<name>             ->  lab-apps-<app>-<name>
# Field labels are preserved verbatim.
#
# Never prints a secret value — output is path, item, field name, and verdict.
#
# Usage:
#   OP_SERVICE_ACCOUNT_TOKEN=<write-scoped token> scripts/migrate-secrets-to-1password.sh
#
# Cost note: a first pass is roughly one write per item; a re-run is two
# (delete + create). 1Password meters writes hourly, so a full re-run of a
# large vault can approach that ceiling.

set -uo pipefail

: "${OP_SERVICE_ACCOUNT_TOKEN:?set OP_SERVICE_ACCOUNT_TOKEN to a token with write_items on the vault}"
export VAULT_ADDR="${VAULT_ADDR:-https://10.0.0.200:8200}"
OP_VAULT="${OP_VAULT:-grizzly-platform}"

created=0
updated=0
failed=0
mismatched=0
verified=0

# Recursively emit every leaf secret path under a KV v2 prefix.
walk() {
  local prefix="${1}"
  local listing keys_raw key
  listing="$(bao kv list -format=json "${prefix}" 2>/dev/null)" || return 0
  keys_raw="$(printf '%s' "${listing}" | jq -r '.[]')" || return 0
  [[ -z "${keys_raw}" ]] && return 0
  local keys=()
  mapfile -t keys <<<"${keys_raw}"
  for key in "${keys[@]}"; do
    if [[ "${key}" == */ ]]; then
      walk "${prefix}${key}"
    else
      printf '%s\n' "${prefix}${key}"
    fi
  done
}

item_name() {
  sed -e 's|^secret/grizzly-platform/||' -e 's|^secret/lab-apps/|lab-apps-|' -e 's|/|-|g' <<<"${1}"
}

paths_raw="$( { walk "secret/grizzly-platform/"; walk "secret/lab-apps/"; } )"
if [[ -z "${paths_raw}" ]]; then
  printf 'FAIL  no secrets found under secret/grizzly-platform/ or secret/lab-apps/\n'
  exit 1
fi
paths=()
mapfile -t paths <<<"${paths_raw}"

for path in "${paths[@]}"; do
  [[ -z "${path}" ]] && continue
  item="$(item_name "${path}")"

  bao_json="$(bao kv get -format=json "${path}" 2>/dev/null | jq -c '.data.data')"
  if [[ -z "${bao_json}" || "${bao_json}" == "null" ]]; then
    printf 'FAIL  %s -> could not read from OpenBao\n' "${path}"
    ((failed++))
    continue
  fi

  tmpl="$(jq -n --arg t "${item}" --argjson d "${bao_json}" \
    '{title:$t, category:"SECURE_NOTE",
      fields:($d|to_entries|map({type:"CONCEALED", label:.key, value:.value}))}')"

  # Replacing an item is delete-then-create, which is not atomic: between the
  # two calls the item does not exist. A failure there — most likely the hourly
  # write limit — would leave the vault short an item, so treat it as fatal and
  # stop rather than continuing to delete items we may also fail to recreate.
  deleted=0
  if op item get "${item}" --vault "${OP_VAULT}" >/dev/null 2>&1; then
    if ! op item delete "${item}" --vault "${OP_VAULT}" >/dev/null 2>&1; then
      printf 'FAIL  %s -> delete failed, item left as-is (likely hourly write limit)\n' "${path}"
      ((failed++))
      continue
    fi
    deleted=1
    action=updated
  else
    action=created
  fi

  # Process substitution keeps the rendered template (which holds plaintext
  # secrets) off disk.
  if ! op item create --template <(printf '%s' "${tmpl}") --vault "${OP_VAULT}" >/dev/null 2>&1; then
    if [[ "${deleted}" -eq 1 ]]; then
      printf 'FATAL %s -> item %s was deleted and could not be recreated.\n' "${path}" "${item}"
      printf '      The vault is missing this item. OpenBao still holds the value;\n'
      printf '      re-run once the hourly write window resets to restore it.\n'
      exit 1
    fi
    printf 'FAIL  %s -> op item create failed\n' "${path}"
    ((failed++))
    continue
  fi

  case "${action}" in
    created) ((created++)) ;;
    updated) ((updated++)) ;;
    *) ;;
  esac

  op_raw="$(op item get "${item}" --vault "${OP_VAULT}" --reveal --format json 2>/dev/null)"
  op_json="$(printf '%s' "${op_raw}" \
    | jq -c '[.fields[]?|select(.label!=null and .value!=null)|{key:.label,value:.value}]|from_entries')"
  if [[ -z "${op_json}" ]]; then
    printf 'FAIL  %s -> could not read back item %s\n' "${path}" "${item}"
    ((failed++))
    continue
  fi

  diff_keys="$(jq -rn --argjson a "${bao_json}" --argjson b "${op_json}" \
    '[($a|keys[])|select(($a[.]) != ($b[.]?))]|join(",")')"
  nfields="$(jq -rn --argjson a "${bao_json}" '$a|length')"
  if [[ -n "${diff_keys}" ]]; then
    printf 'MISMATCH  %s -> item %s fields differ: %s\n' "${path}" "${item}" "${diff_keys}"
    ((mismatched++))
  else
    printf 'ok  %s -> %s (%s fields)\n' "${path}" "${item}" "${nfields}"
    ((verified += nfields))
  fi
done

printf '\ncreated=%s updated=%s failed=%s mismatched=%s fields_verified=%s\n' \
  "${created}" "${updated}" "${failed}" "${mismatched}" "${verified}"

[[ "${failed}" -eq 0 && "${mismatched}" -eq 0 ]]
