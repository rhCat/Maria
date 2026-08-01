#!/usr/bin/env bash
# setup_maria_node.sh — SETUP-SOP.md, executable.
#
# Brings Maria up as a principal on a SHARED govd node. Idempotent.
#
#   bash setup_maria_node.sh                       # ed25519 (preferred)
#   AUTH_SCHEME=token bash setup_maria_node.sh     # static bearer (workaround)
#
# The ordering below is not stylistic. MariaSetup.tla proves that every
# precondition for a claim to authenticate names a LOADED value, and that
# Reload is the only action moving disk state into the serving process. So the
# single reload happens AFTER both writes. Reloading between them leaves govd
# serving a snapshot that predates the second — TLC returns exactly that trace
# as a counterexample to DiskCorrectImpliesAuth.
set -uo pipefail

NODE="${NODE:-maria}"
PRINCIPAL="${PRINCIPAL:-maria-agent}"
REPO="${REPO:-/opt/maria}"
GOVD_CTR="${GOVD_CTR:-cyberware}"
AGENT_CTR="${AGENT_CTR:-maria}"
AUTH_SCHEME="${AUTH_SCHEME:-ed25519}"
ETC="$HOME/.cyberware/$NODE/etc"
RUN="$HOME/.cyberware/$NODE/run"

say(){ printf '\n══ %s\n' "$*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
ip4(){ tailscale ip -4 2>/dev/null | head -1; }

[ -d "$REPO/devdoc/tool" ] || die "REPO=$REPO has no devdoc/tool (set REPO=)"
docker inspect "$GOVD_CTR" >/dev/null 2>&1 || die "no govd container '$GOVD_CTR'"
mkdir -p "$ETC" "$RUN"

# ── P1: chip serves the gate's skill ─────────────────────────────────
say "P1  chip serves hermes:toolgate"
SKILLS=$(curl -fsS "http://$(ip4):5773/health" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("chip",{}).get("skills",0))' 2>/dev/null || echo 0)
echo "    skills served: $SKILLS"
[ "$SKILLS" -gt 0 ] || die "govd unreachable at $(ip4):5773 (it binds the TAILNET ip, not loopback)"

# ── P2: image can REGISTER a verifier (cyberware #235) ───────────────
if [ "$AUTH_SCHEME" = "ed25519" ]; then
  say "P2  image registers verifiers (cyberware #235)"
  docker exec "$GOVD_CTR" python3 -c \
    'from infra.govern import govd; raise SystemExit(0 if hasattr(govd,"install_builtin_verifier") else 1)' \
    || die "image predates #235: the config key would register NOTHING. docker pull ghcr.io/rhcat/cyberware-body:latest"
  echo "    ok"
fi

# ── step 2: identity scheme on disk. NO RELOAD HERE. ─────────────────
say "step 2  auth_verifier (no reload yet — see MariaSetup.tla)"
python3 - "$RUN" "$AUTH_SCHEME" <<'PY'
import json, os, sys
run, scheme = sys.argv[1], sys.argv[2]
p = os.path.join(run, "govd.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d["auth_verifier"] = "ed25519" if scheme == "ed25519" else ""
json.dump(d, open(p, "w"), indent=2)
print(f"    auth_verifier={d['auth_verifier']!r} -> {p}")
PY
echo "    NOTE deploy-node.sh rewrites govd.json from scratch; re-run after any node redeploy"

# ── P3: agent identity ───────────────────────────────────────────────
say "P3  agent identity"
KEY="$ETC/agent-ed25519.key"
TOKF="$ETC/govd-agent.token"
if [ "$AUTH_SCHEME" = "ed25519" ]; then
  [ -s "$KEY" ] || { openssl rand -hex 32 > "$KEY"; echo "    minted $KEY"; }
  chmod 600 "$KEY"
  SUBJECT=$(python3 - "$KEY" "$ETC/agent-ed25519.pub" <<'PY'
import hashlib, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey as K
from cryptography.hazmat.primitives import serialization as s
# "ed25519:" + sha256(raw_pub)[:16] -- byte-identical to infra.cwp.sign.keyid,
# so this never needs a cyberware checkout (a node's clone is often older).
pub = K.from_private_bytes(bytes.fromhex(open(sys.argv[1]).read().strip())
      ).public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
open(sys.argv[2], "w").write(pub.hex() + "\n")
print("ed25519:" + hashlib.sha256(pub).hexdigest()[:16])
PY
  ) || die "could not derive the subject"
  chmod 600 "$ETC/agent-ed25519.pub"
  echo "    subject: $SUBJECT"
else
  [ -s "$TOKF" ] || { openssl rand -hex 24 > "$TOKF"; echo "    minted $TOKF"; }
  chmod 600 "$TOKF"
  echo "    static bearer at $TOKF"
fi

# ── P4: register under the "principals" KEY ──────────────────────────
say "P4  register '$PRINCIPAL'"
python3 - "$PRINCIPAL" "$AUTH_SCHEME" "${SUBJECT:-}" "$TOKF" "$ETC" "$RUN" <<'PY'
import json, os, sys, hashlib
name, scheme, subject, tokf, etc, run = sys.argv[1:7]
if scheme == "ed25519":
    ident = {"subject": subject}
else:
    ident = {"token_sha": hashlib.sha256(open(tokf).read().strip().encode()).hexdigest()}
entry = {**ident, "rate": 60, "burst": 10,
         "acl": {"skills": ["*"], "max_tier": "verified"}}
for p in (os.path.join(etc, "principals.json"), os.path.join(run, "principals.json")):
    d = json.load(open(p)) if os.path.exists(p) else {}
    # load_principals() returns json[...]["principals"] -- a TOP-LEVEL entry is
    # silently ignored: registered, never resolved.
    d.setdefault("principals", {})[name] = entry
    for junk in [k for k in list(d) if k != "principals"]:
        d.pop(junk); print(f"    pruned stray top-level key: {junk}")
    json.dump(d, open(p, "w"), indent=2)
    print(f"    {name} -> principals[] in {p}")
PY

# ── P5: THE reload. After both writes, exactly once. ─────────────────
say "P5  reload govd (the ordering step)"
docker restart "$GOVD_CTR" >/dev/null && sleep 6 && echo "    reloaded"
docker exec "$GOVD_CTR" python3 -c \
  'from infra.govern import govd;c=govd.load_config();print("    loaded verifier:",repr(c.get("auth_verifier")));print("    loaded principals:",list((c.get("principals") or {}).keys()))'

# ── step 6: the agent container ──────────────────────────────────────
say "step 6  compose override + container"
OVR="$REPO/devdoc/tool/docker-compose.override.yml"
{
  echo "services:"
  echo "  maria:"
  echo "    depends_on: !reset []"
  echo "    networks: [cage, uplink]"
  echo "    environment:"
  echo '      CUSTOM_BASE_URL: ""'
  echo '      CUSTOM_API_KEY: ""'
  echo "      HERMES_GOVERN_URL: \"http://$GOVD_CTR:5773\""
  if [ "$AUTH_SCHEME" = "ed25519" ]; then
    echo '      HERMES_GOVERN_AUTH_SCHEME: "ed25519"'
    echo '      HERMES_GOVERN_KEY_FILE: "/run/maria/agent-ed25519.key"'
  else
    echo '      HERMES_GOVERN_AUTH_SCHEME: "token"'
    echo '      HERMES_GOVERN_TOKEN_FILE: "/run/maria/govd.token"'
  fi
  echo "    stdin_open: true"
  echo "    tty: true"
} > "$OVR" 2>/dev/null || { sudo tee "$OVR" >/dev/null; } < /dev/null
echo "    wrote $OVR"

docker network connect maria_cage "$GOVD_CTR" 2>/dev/null
# /run/maria is tmpfs: the credential is re-injected on EVERY start, so these
# env vars are required on every launch, not just the first.
CRED_TOKEN=$([ "$AUTH_SCHEME" = "ed25519" ] && cat "$ETC/monitor.token" 2>/dev/null || cat "$TOKF")
( cd "$REPO" && GOVD_BIND="$(ip4)" \
    MARIA_GOVD_TOKEN="$CRED_TOKEN" \
    MARIA_ED25519_KEY="$(tr -d '\n' < "$KEY" 2>/dev/null || echo unused)" \
    LOCAL_LLM_TOKEN=unused LITELLM_MASTER_KEY=sk-unused \
    docker compose -f devdoc/tool/docker-compose.maria.yml -f "$OVR" up -d --force-recreate maria ) \
  || die "compose refused the file (an empty credential leaves everything untouched)"

docker ps -a --filter "name=^${AGENT_CTR}$" --format '    {{.Names}} {{.Status}} {{.Image}}' | grep . \
  || die "no container — compose no-op'd"

# ── gates ────────────────────────────────────────────────────────────
say "gates"
docker exec "$AGENT_CTR" ls -l /etc/maria/governed 2>/dev/null | sed 's/^/    marker: /' \
  || echo "    !! H4 marker missing — the image predates it, rebuild"
docker logs "$AGENT_CTR" 2>&1 | grep -o '\[assert-governed\].*' | head -1 | sed 's/^/    /'
docker exec "$AGENT_CTR" env | grep HERMES_GOVERN | sed 's/^/    /'

cat <<EOF

══ next
    docker exec -it -u hermes $AGENT_CTR /opt/hermes/bin/hermes setup model
    docker exec -it -u hermes $AGENT_CTR /opt/hermes/bin/hermes --tui

Then make ONE tool call and read the LEDGER, not the agent's error text:
    row with '$PRINCIPAL'  -> working
    rows, all reject       -> AUTHORISATION (acl / expires_at / revoked)
    no rows at all         -> WIRING (P1, P2, P4 or P5)

A 401 is refused before any run is recorded, which is why the wiring case
leaves no trace. A 403 means auth SUCCEEDED and policy refused — progress.

KNOWN DEFECT: on some images ed25519 returns 401 with every precondition
verified, while token_sha authenticates normally. If that happens, re-run with
AUTH_SCHEME=token. See SETUP-SOP.md.
EOF
