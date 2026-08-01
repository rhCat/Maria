#!/usr/bin/env bash
# setup_maria.sh — install Maria NATIVELY on a Linux host (no container).
#
# This is the deployment agent/govern_gate.py was written for: the security
# switches are injected by a root-owned systemd unit from
# /etc/maria/governance.conf, and the H4 marker is a root-owned file the agent
# account cannot write. The containerised deployment
# (docker-compose.maria.yml) is the adaptation of this, not the other way round.
#
# WHAT THIS DOES NOT GIVE YOU. The container puts Maria on an `internal: true`
# network with no route off the host — no internet, no LAN, no tailnet — and a
# proxy as the sole egress, so the real inference credential never enters the
# agent's environment. A native process has none of that: it can reach whatever
# the host can, and the provider key sits in its environment. H1/H2/H4 and
# fail-closed all still hold, but they govern PERMISSION, not reach. If you
# need containment, harden the unit (see HARDENING at the foot of this file) or
# use the container.
#
# Idempotent: safe to re-run. Every step is guarded.
#
#   sudo GOVD_URL=http://127.0.0.1:5773 bash setup_maria.sh
#
# Env (all optional):
#   MARIA_USER    unprivileged account to run as        (default: maria)
#   MARIA_HOME    agent state dir                       (default: /var/lib/maria)
#   INSTALL_DIR   root-owned code tree                  (default: /opt/maria)
#   REPO / BRANCH source                                (default: rhCat/Maria, dev)
#   GOVD_URL      governance endpoint                   (default: http://127.0.0.1:5773)
#   CYBERWARE_SRC clone used to derive the ed25519 subject (default: ~/cyberware)
set -euo pipefail

MARIA_USER="${MARIA_USER:-maria}"
MARIA_HOME="${MARIA_HOME:-/var/lib/maria}"
INSTALL_DIR="${INSTALL_DIR:-/opt/maria}"
REPO="${REPO:-https://github.com/rhCat/Maria.git}"
BRANCH="${BRANCH:-dev}"
GOVD_URL="${GOVD_URL:-http://127.0.0.1:5773}"
CYBERWARE_SRC="${CYBERWARE_SRC:-$HOME/cyberware}"
ETC=/etc/maria
KEY="$ETC/agent-ed25519.key"
CONF="$ETC/governance.conf"
MARKER="$ETC/governed"

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- 1. account
say "1/10  unprivileged account: $MARIA_USER"
if id "$MARIA_USER" >/dev/null 2>&1; then
    echo "  exists"
else
    useradd -r -m -d "$MARIA_HOME" -s /usr/sbin/nologin "$MARIA_USER"
    echo "  created"
fi
install -d -o "$MARIA_USER" -g "$MARIA_USER" -m 0750 "$MARIA_HOME"

# ------------------------------------------------------------ 2. build deps
say "2/10  build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl python3 python3-venv python3-dev \
    gcc g++ make cmake libffi-dev libolm-dev ca-certificates

# ----------------------------------------------------------------- 3. clone
say "3/10  source tree: $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
    git -C "$INSTALL_DIR" checkout --quiet "$BRANCH"
    git -C "$INSTALL_DIR" reset --hard --quiet "origin/$BRANCH"
    echo "  updated to origin/$BRANCH"
else
    git clone --quiet -b "$BRANCH" "$REPO" "$INSTALL_DIR"
    echo "  cloned $BRANCH"
fi

# ------------------------------------------------------------------- 4. venv
say "4/10  venv (uv sync --frozen)"
# The uv installer drops into the invoking user's ~/.local/bin, which is NOT on
# sudo's PATH. Resolve it explicitly rather than trusting PATH.
UV="$(command -v uv || true)"
[ -n "$UV" ] || for c in /root/.local/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv"; do
    [ -x "$c" ] && UV="$c" && break
done
if [ -z "$UV" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    UV=/root/.local/bin/uv
fi
echo "  uv: $UV"
# UV_PYTHON pins the system interpreter so uv does not fetch a managed Python
# and leave the venv pointing somewhere else — same reason Dockerfile.maria
# sets it inline.
( cd "$INSTALL_DIR" && UV_PYTHON=/usr/bin/python3 "$UV" sync --frozen )

# -------------------------------------------------- 5. lock the code tree (H2)
say "5/10  lock the code tree (H2 / read-only deployment)"
chown -R root:root "$INSTALL_DIR"
chmod -R a+rX,go-w "$INSTALL_DIR"
echo "  $INSTALL_DIR is root-owned, not writable by $MARIA_USER"

# ------------------------------------------------------- 6. the H4 marker
say "6/10  H4 governed marker"
install -d -o root -g root -m 0755 "$ETC"
printf '%s\n' 'This deployment is governed. See agent/govern_gate.py (H4).' > "$MARKER"
chown root:root "$MARKER"; chmod 0644 "$MARKER"
echo "  $MARKER  (root-owned 0644; forces governed + fail-closed)"

# ------------------------------------------------- 7. governance env (H1)
say "7/10  governance environment"
if [ -f "$CONF" ]; then
    echo "  $CONF exists — left untouched"
else
    cat > "$CONF" <<EOF
# Read by the systemd unit and injected into the agent's environment.
# agent/govern_gate.py freezes these at import from the ENVIRONMENT ONLY —
# there is deliberately no config.yaml fallback, so a write_file to the
# agent-writable config cannot disable the gate governing that write.
HERMES_GOVERN_ENABLED=true
HERMES_GOVERN_FAIL_OPEN=false
HERMES_GOVERN_URL=$GOVD_URL
HERMES_GOVERN_AUTH_SCHEME=ed25519
HERMES_GOVERN_KEY_FILE=$KEY
EOF
    echo "  wrote $CONF"
fi
chown root:root "$CONF"; chmod 0600 "$CONF"

# ------------------------------------------------------- 8. agent identity
say "8/10  agent ed25519 identity"
if [ -s "$KEY" ]; then
    echo "  key exists — reusing"
else
    openssl rand -hex 32 > "$KEY"
    echo "  minted"
fi
chown "$MARIA_USER:$MARIA_USER" "$KEY"; chmod 0600 "$KEY"

SUBJECT=""
if [ -d "$CYBERWARE_SRC/infra" ]; then
    SUBJECT="$(cd "$CYBERWARE_SRC" && python3 - "$KEY" <<'PY' || true
import sys
sys.path.insert(0, ".")
from infra.govern import ed25519_auth as e
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey as K
from cryptography.hazmat.primitives import serialization as s
h = open(sys.argv[1]).read().strip()
pub = K.from_private_bytes(bytes.fromhex(h)).public_key().public_bytes(
    s.Encoding.Raw, s.PublicFormat.Raw)
print(e.subject_for(pub))
PY
)"
fi
if [ -n "$SUBJECT" ]; then
    echo "  subject: $SUBJECT"
else
    echo "  !! could not derive the subject (no cyberware clone at $CYBERWARE_SRC)"
    echo "     derive it there and register it manually — see MANUAL below."
fi

# -------------------------------------------------------- 9. systemd service
say "9/10  systemd service"
HERMES="$INSTALL_DIR/.venv/bin/hermes"
[ -x "$HERMES" ] || { echo "  ERROR: $HERMES missing — step 4 did not complete" >&2; exit 1; }
"$HERMES" gateway install --system --run-as-user "$MARIA_USER" --no-start-now

# The generated unit emits Environment= directives only. A drop-in wires in the
# root-owned governance file without editing the unit, so it survives a
# reinstall of the service.
UNIT="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '/hermes.*gateway/{print $1; exit}')"
UNIT="${UNIT:-hermes-gateway.service}"
DROPIN="/etc/systemd/system/${UNIT}.d"
install -d -m 0755 "$DROPIN"
printf '[Service]\nEnvironmentFile=%s\n' "$CONF" > "$DROPIN/10-governance.conf"
chmod 0644 "$DROPIN/10-governance.conf"
systemctl daemon-reload
echo "  unit: $UNIT   drop-in: $DROPIN/10-governance.conf"

# ------------------------------------------------------------- 10. verify
say "10/10 verify AS THE AGENT ACCOUNT"
# Run as $MARIA_USER, never root: root's permissions would mask exactly the
# failure this is checking for.
sudo -u "$MARIA_USER" "$INSTALL_DIR/.venv/bin/python3" - <<PY
import sys
sys.path.insert(0, "$INSTALL_DIR")
from agent import govern_gate as g
ok = g.is_enabled() and g._marker_present() and not g._fail_open()
print(f"  enabled={g.is_enabled()}  marker={g._marker_present()}  fail_open={g._fail_open()}")
print("  " + ("OK — governed, fail-closed" if ok else "!! NOT in the expected posture"))
sys.exit(0 if ok else 1)
PY

cat <<EOF

== MANUAL steps this script cannot do for you

1. REGISTER THE PRINCIPAL on the govd node, or every tool call is denied.
   Add to that node's principals.json:
       "maria": {"subject": "${SUBJECT:-<derive it>}", "rate": 60, "burst": 10}
   then restart govd so it reloads the registry.

2. CONFIGURE THE PROVIDER. Set the model/endpoint in the agent's config, and
   pin a per-model max_tokens BELOW the model's context ceiling — a request
   over it returns HTTP 400 and surfaces as a nonsensical
   "Context length exceeded (N tokens)" that names nothing useful.

3. CONFIRM THE CHIP SERVES hermes:toolgate. The gate claims against that skill
   and an unverified skill is a fail-closed DENY:
       curl -fsS $GOVD_URL/health | grep -o '"skills": [0-9]*'

   1 and 3 fail identically — agent healthy, every call denied. Check the
   node's ledger: claims arriving and being rejected means 1; no claims
   arriving at all means the gate never verified, i.e. 3.

== Start it
   systemctl start ${UNIT:-hermes-gateway}
   journalctl -u ${UNIT:-hermes-gateway} -f

== HARDENING (optional) — claw back some of what the container's cage gave you
   Add to $DROPIN/20-sandbox.conf:
       [Service]
       NoNewPrivileges=yes
       ProtectSystem=strict
       ProtectHome=yes
       PrivateTmp=yes
       ReadWritePaths=$MARIA_HOME
       IPAddressDeny=any
       IPAddressAllow=<your provider + govd only>
EOF
