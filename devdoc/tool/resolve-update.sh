#!/usr/bin/env bash
# resolve-update.sh — post-update recovery + verification for the governed Maria deployment.
#
# Written after the 2026-08-03 incident: a cyberware govd repull + maria recreate broke
# every tool call with fail-closed blocks. Five distinct faults, each presenting IDENTICALLY
# as "agent healthy, every tool call denied":
#
#   F1  catalog fetch failed: Errno -3        govd container dropped off maria_cage (recreated by repull)
#   F2  govd HTTP 401 / missing/invalid Auth  token_sha in principals.json != sha256(token maria sends)
#   F3  rejected by govd: acl_destructive_unlisted  ACL missing hermes:toolgate perks
#   F4  compose refuses: required variable    env file missing one of the 4 :? vars (whole-file interpolation)
#   F5  gate URL = maria-govd:5773            recreate ran WITHOUT the override -> reverted to base defaults
#
# RULES the session proved:
#   * Verify CONTENT, not exit codes. `docker ps` green, "Up X hours", "healthy" —
#     none of them ever caught F1-F5. The container env and the ledger are the truth.
#   * govd reads its config ONCE at process start. Correct files on disk are not a
#     working agent. After any registry/verifier write: docker restart <govd> (P5).
#   * docker exec does NOT forward stdin without -i. Use `docker exec -i ... python3 -`.
#   * The credential lives in /run/maria tmpfs, re-injected on EVERY start from the
#     launch env — a recreate without MARIA_GOVD_TOKEN comes up with no credential.
#   * Never inline $(cat token) in a command line (secret masking mangles it on copy).
#     Everything below computes tokens inside python heredocs.
#
# USAGE:
#   bash resolve-update.sh           # read-only diagnostic ladder (safe)
#   bash resolve-update.sh --fix     # apply fixes (idempotent) then re-verify
#   bash resolve-update.sh --verify  # ledger check only (make ONE tool call first)
#
# Env overrides: REPO NODE PRINCIPAL GOVD_CTR AGENT_CTR GOVD_URL GOVD_HOST TOKEN_FILE

set -uo pipefail

REPO="${REPO:-/opt/maria}"
NODE="${NODE:-maria}"
PRINCIPAL="${PRINCIPAL:-maria-agent}"
GOVD_CTR="${GOVD_CTR:-cyberware}"
AGENT_CTR="${AGENT_CTR:-maria}"
GOVD_URL="${GOVD_URL:-http://cyberware:5773}"
GOVD_HOST="${GOVD_HOST:-$(tailscale ip -4 2>/dev/null | head -1)}"
ETC="$HOME/.cyberware/$NODE/etc"
RUN="$HOME/.cyberware/$NODE/run"
TOKEN_FILE="${TOKEN_FILE:-$ETC/govd-agent.token}"
MONITOR="$ETC/monitor.token"
COMPOSE_ENV="$HOME/.compose.env"
OVR="$REPO/devdoc/tool/docker-compose.override.yml"

PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------- checks ----
check_override() {   # F5
  [ -f "$OVR" ] || { bad "F5  override missing: $OVR — recreate without it reverts to base defaults (maria-govd)"; return; }
  grep -q "cyberware:5773" "$OVR" 2>/dev/null && ok "F5  override points at $GOVD_URL" \
    || bad "F5  override URL wrong — maria must talk to the govd that has the principal"
  grep -q 'AUTH_SCHEME: "token"' "$OVR" 2>/dev/null && ok "F5  override pins token scheme" \
    || bad "F5  override scheme is not token (ed25519 hits the known-defect 401)"
}

check_cage_dns() {   # F1
  docker exec "$AGENT_CTR" sh -c 'getent hosts cyberware' >/dev/null 2>&1 \
    && ok "F1  cage DNS resolves cyberware" \
    || bad "F1  cyberware unresolvable from $AGENT_CTR — fix: docker network connect maria_cage $GOVD_CTR (lost on govd repull)"
}

check_catalog() {    # F1
  docker exec -i "$AGENT_CTR" python3 - <<'PY' >/dev/null 2>&1
import urllib.request, json
d = json.loads(urllib.request.urlopen("http://cyberware:5773/catalog", timeout=8).read())
assert any(s.get("skill") == "hermes:toolgate" for s in d.get("skills", [])), "toolgate absent"
PY
  [ $? -eq 0 ] && ok "F1  catalog fetch + hermes:toolgate present" \
    || bad "F1  catalog/toolgate — govd unreachable or chip stale (restart $GOVD_CTR re-runs chipfetch)"
}

check_govd_state() { # F2
  local out
  out=$(docker exec -i "$GOVD_CTR" python3 - <<'PY' 2>&1
from infra.govern import govd
c = govd.load_config()
print("verifier:", repr(c.get("auth_verifier")))
print("principals:", list((c.get("principals") or {}).keys()))
PY
)
  echo "$out" | grep -q "verifier: ''" && ok "F2  govd verifier is '' (token_sha scheme)" \
    || bad "F2  verifier not token-scheme: $(echo "$out" | grep verifier)"
  echo "$out" | grep -q "'$PRINCIPAL'" && ok "F2  govd serves $PRINCIPAL" \
    || bad "F2  $PRINCIPAL not loaded — registry on disk != serving process; rewrite + restart (P5)"
}

check_token_match() { # F2
  local expected registered
  expected=$(python3 -c "import hashlib;print(hashlib.sha256(open('$TOKEN_FILE').read().strip().encode()).hexdigest())" 2>/dev/null) \
    || { bad "F2  cannot read $TOKEN_FILE"; return; }
  registered=$(docker exec -i "$GOVD_CTR" python3 - "$PRINCIPAL" <<'PY' 2>/dev/null
import sys
from infra.govern import govd
c = govd.load_config()
p = (c.get("principals") or {}).get(sys.argv[1], {})
print(p.get("token_sha", "MISSING"))
PY
)
  [ "$registered" = "$expected" ] \
    && ok "F2  registered token_sha matches $TOKEN_FILE" \
    || bad "F2  token mismatch — registered=${registered:0:16}… expected=${expected:0:16}… (re-register via --fix)"
}

check_agent_token() { # F2
  docker exec -u hermes "$AGENT_CTR" sh -c 'test -r /run/maria/govd.token' 2>/dev/null \
    && ok "F2  agent (uid 10000) can read /run/maria/govd.token" \
    || bad "F2  agent cannot read the token — entrypoint must chown it to 10000"
}

check_acl() {         # F3
  docker exec -i "$GOVD_CTR" python3 - "$PRINCIPAL" <<'PY' >/dev/null 2>&1
import sys
from infra.govern import govd
c = govd.load_config()
p = (c.get("principals") or {}).get(sys.argv[1], {})
perks = (p.get("acl") or {}).get("perks") or {}
assert "exec" in perks.get("hermes:toolgate", []), "hermes:toolgate exec missing"
PY
  [ $? -eq 0 ] && ok "F3  ACL grants hermes:toolgate exec" \
    || bad "F3  ACL missing toolgate perks — fix: perks {hermes:toolgate: [read,write,exec,net,delegate,selfmod]}"
}

check_claim() {       # F2/F3 — the mutation test: govd's verdict on the exact bytes maria sends
  local tok code body
  tok=$(cat "$TOKEN_FILE")
  code=$(curl -s -o /tmp/claim.json -w '%{http_code}' -X POST "http://${GOVD_HOST}:5773/govern" \
    -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
    -d '{"skill":"hermes:toolgate","perk":"exec","var_keys":["TOOL","ARGS_DIGEST","TARGET"]}')
  body=$(cat /tmp/claim.json 2>/dev/null)
  if [ "$code" = "200" ]; then
    ok "F2/F3  direct claim ALLOWED (http 200)"
  else
    bad "F2/F3  direct claim http $code: ${body:0:200}"
  fi
}

diagnose() {
  echo "== post-update diagnostic ladder (read-only) =="
  echo "  node=$NODE  govd=$GOVD_CTR  agent=$AGENT_CTR  govd_host=$GOVD_HOST"
  check_override
  check_cage_dns
  check_catalog
  check_govd_state
  check_token_match
  check_agent_token
  check_acl
  check_claim
  echo "passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ]
}

# ----------------------------------------------------------------- fixes ----
apply_fixes() {
  echo "== F1  cage network (idempotent) =="
  docker network connect maria_cage "$GOVD_CTR" 2>/dev/null \
    && echo "  attached $GOVD_CTR to maria_cage" || echo "  already attached or no such network"

  echo "== F2/F3  rewrite registry: token_sha + ACL perks =="
  python3 - "$PRINCIPAL" "$TOKEN_FILE" <<'PY'
import json, os, hashlib, sys
principal, tokf = sys.argv[1], sys.argv[2]
tok = open(tokf).read().strip()
sha = hashlib.sha256(tok.encode()).hexdigest()
entry = {
    "token_sha": sha, "rate": 60, "burst": 10,
    "acl": {
        "skills": ["*"],
        "perks": {"hermes:toolgate": ["read", "write", "exec", "net", "delegate", "selfmod"]},
        "max_tier": "community",
        "secrets": False,
    },
}
etc = os.path.expanduser("~/.cyberware/maria/etc")
run = os.path.expanduser("~/.cyberware/maria/run")
for p in (f"{etc}/principals.json", f"{run}/principals.json"):
    d = json.load(open(p))
    d.setdefault("principals", {})[principal] = entry
    json.dump(d, open(p, "w"), indent=2)
    print("  wrote", p, "token_sha", sha[:16], "…")
PY

  echo "== P5  reload govd (reads registry once at start) =="
  docker restart "$GOVD_CTR" && sleep 6

  echo "== F4  env file — all 4 :? vars (whole-file interpolation) =="
  python3 - "$TOKEN_FILE" <<'PY'
import os, sys
tok = open(sys.argv[1]).read().strip()
with open(os.path.expanduser("~/.compose.env"), "w") as f:
    f.write(f"MARIA_GOVD_TOKEN={tok}\n")
    f.write("MARIA_ED25519_KEY=unused\n")   # token scheme — ed25519 key not used
    f.write("LOCAL_LLM_TOKEN=unused\n")
    f.write("LITELLM_MASTER_KEY=sk-unused\n")
print("  wrote ~/.compose.env")
PY
  chmod 600 "$COMPOSE_ENV"

  echo "== F5  override (required config — recreate without it reverts to base defaults) =="
  sudo tee "$OVR" >/dev/null <<'EOF'
services:
  maria:
    depends_on: !reset []
    networks: [cage, uplink]
    environment:
      CUSTOM_BASE_URL: ""
      CUSTOM_API_KEY: ""
      HERMES_GOVERN_URL: "http://cyberware:5773"
      HERMES_GOVERN_AUTH_SCHEME: "token"
      HERMES_GOVERN_TOKEN_FILE: "/run/maria/govd.token"
    stdin_open: true
    tty: true
EOF

  echo "== recreate maria =="
  ( cd "$REPO" \
      && docker compose --env-file "$COMPOSE_ENV" \
           -f devdoc/tool/docker-compose.maria.yml \
           -f devdoc/tool/docker-compose.override.yml \
           up -d --force-recreate maria )

  echo "== re-verify =="
  diagnose
}

# --------------------------------------------------------------- ledger ----
verify_ledger() {
  python3 - "$GOVD_HOST" "$MONITOR" "$PRINCIPAL" <<'PY'
import urllib.request, json, sys
host, mtok, principal = sys.argv[1], sys.argv[2], sys.argv[3]
tok = open(mtok).read().strip()
d = json.loads(urllib.request.urlopen(urllib.request.Request(
    f"http://{host}:5773/monitor/state", headers={"X-Govd-Monitor": tok}), timeout=8).read())
runs = d.get("runs", [])
mine = [r for r in runs if r.get("principal") == principal]
print(f"runs: {len(runs)}   {principal}: {len(mine)}")
for r in mine[-5:]:
    print("  ", r.get("ts"), r.get("skill"), r.get("decision"))
if mine:
    print("RESULT:", "ALLOW — working" if any(r.get("decision") == "allow" for r in mine)
           else "REJECTS — auth OK, ACL too narrow (check expires_at/revoked/perks)")
else:
    print("RESULT: NO ROWS — wiring: run `bash resolve-update.sh` (no ledger trace means the claim never arrived)")
PY
}

case "${1:-}" in
  --fix)    apply_fixes ;;
  --verify) verify_ledger ;;
  *)        diagnose ;;
esac
