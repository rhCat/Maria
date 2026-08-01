#!/usr/bin/env bash
# cyberware plan · skill=cws:cws-pm perk=run · value-free; the caller exports SNIP/RECORD_STORE/vars
set -uo pipefail
: "${SNIP:?SNIP must point at the perk snippet dir}" "${RECORD_STORE:?}"
mkdir -p "$RECORD_STORE"

step1() {   # cws_pm
  echo "[step 1] cws_pm"
  bash "$SNIP/cws_pm.sh" || exit $?
  test -f "${RECORD_STORE}/pm.json" || { echo "CONTRACT FAIL step 1: missing ${RECORD_STORE}/pm.json" >&2; exit 3; }
}

case "${1:-}" in
  --list) printf "1\tcws_pm\n" ;;
  --step) shift; "step${1:?step number}" ;;
  --all) step1 ;;
  *) echo "usage: $0 --list | --step <N> | --all" >&2; exit 2 ;;
esac
