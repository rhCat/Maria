# ─────────────────────────────── Maria ───────────────────────────────
# Shared-node deployment: one govd on this box, agents as named principals
# writing to one shared ledger. Paste into ~/.bashrc, or source this file.
#
#   first run:  maria-setup        (idempotent — safe to re-run)
#   daily:      maria / maria-up / maria-ledger / maria-doctor
#   add agent:  maria-agent-add maria-chief

export MARIA_REPO="${MARIA_REPO:-$HOME/maria}"          # repo root (contains devdoc/)
export MARIA_ETC="$HOME/.cyberware/maria/etc"           # source of truth (survives redeploy)
export MARIA_RUN="$HOME/.cyberware/maria/run"           # what govd actually mounts
export MARIA_GOVD_CTR="${MARIA_GOVD_CTR:-cyberware}"    # govd container name
export MARIA_CTR="${MARIA_CTR:-maria}"                  # agent container name
export MARIA_PRINCIPAL="${MARIA_PRINCIPAL:-maria-agent}"

# govd is published on the TAILNET ip only — 127.0.0.1 gives connection refused
# and looks exactly like the service being down.
_maria_ip()   { tailscale ip -4 2>/dev/null | head -1; }
_maria_govd() { echo "http://$(_maria_ip):5773"; }
_maria_tok()  { cat "$MARIA_ETC/monitor.token" 2>/dev/null; }
_maria_cf()   { printf '%s' "-f $MARIA_REPO/devdoc/tool/docker-compose.maria.yml -f $MARIA_REPO/devdoc/tool/docker-compose.override.yml"; }

# Credentials resolved at call time, never left in the environment.
# LOCAL_LLM_TOKEN / LITELLM_MASTER_KEY are throwaways: compose interpolates the
# WHOLE file even when only `maria` is brought up, so the llm-proxy vars must
# resolve to something or compose refuses the file and silently does nothing.
_maria_compose() {
  ( cd "$MARIA_REPO" 2>/dev/null || { echo "MARIA_REPO not found: $MARIA_REPO" >&2; return 1; }
    GOVD_BIND="$(_maria_ip)" \
    MARIA_GOVD_TOKEN="$(cat "$MARIA_ETC/monitor.token")" \
    MARIA_ED25519_KEY="$(tr -d '\n' < "$MARIA_ETC/agent-ed25519.key")" \
    LOCAL_LLM_TOKEN=unused LITELLM_MASTER_KEY=sk-unused \
    docker compose $(_maria_cf) "$@" )
}

# subject = "ed25519:" + sha256(raw_pub)[:16] — byte-identical to
# infra.cwp.sign.keyid, so this never needs a cyberware checkout (a node's
# clone is routinely older than its image).
_maria_subject() {
  python3 -c "
import hashlib,sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey as K
from cryptography.hazmat.primitives import serialization as s
pub=K.from_private_bytes(bytes.fromhex(open(sys.argv[1]).read().strip())).public_key().public_bytes(s.Encoding.Raw,s.PublicFormat.Raw)
if len(sys.argv)>2: open(sys.argv[2],'w').write(pub.hex()+chr(10))
print('ed25519:'+hashlib.sha256(pub).hexdigest()[:16])" "$@"
}

# ═════════════════════════ SETUP (first run) ═════════════════════════

# 1. Turn on the ed25519 identity scheme on this node.
#    A config key is required: the verifier CODE shipping is not enough.
#    "a config key on its own registers nothing … would fail closed on every
#     claim: correct, but silently unusable."  — govd.install_builtin_verifier
maria-setup-govd() {
  echo "── ed25519 identity scheme"
  docker exec "$MARIA_GOVD_CTR" python3 -c \
    'from infra.govern import govd;ok=hasattr(govd,"install_builtin_verifier");print("   image supports registration (#235):",ok);raise SystemExit(0 if ok else 1)' \
    || { echo "   !! image predates cyberware #235 — the config key will register NOTHING." >&2
         echo "      docker pull ghcr.io/rhcat/cyberware-body:latest && redeploy the node" >&2; return 1; }
  python3 - "$MARIA_RUN" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "govd.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d["auth_verifier"] = "ed25519"
json.dump(d, open(p, "w"), indent=2)
print("   auth_verifier=ed25519 ->", p)
PY
  echo "   NOTE: deploy-node.sh rewrites govd.json from scratch — re-run this after any node redeploy."
  echo "   (no restart here — the principal is written next; govd reloads once, after BOTH)"
}

# 2. Mint this agent's identity and register it as a principal.
maria-setup-identity() {
  mkdir -p "$MARIA_ETC" "$MARIA_RUN"
  local key="$MARIA_ETC/agent-ed25519.key"
  if [ -s "$key" ]; then echo "── key exists — reusing $key"
  else openssl rand -hex 32 > "$key" && chmod 600 "$key" && echo "── minted $key"; fi
  local subj; subj="$(_maria_subject "$key" "$MARIA_ETC/agent-ed25519.pub")" || return 1
  chmod 600 "$MARIA_ETC/agent-ed25519.pub"
  echo "   subject: $subj"
  # etc/ is the source of truth; run/ is what govd mounts. deploy-node.sh
  # copies etc/ OVER run/ each redeploy, so registering only in run/ is
  # silently reverted later.
  python3 - "$MARIA_PRINCIPAL" "$subj" "$MARIA_ETC" "$MARIA_RUN" <<'PY'
import json,os,sys
name,subj,etc,run=sys.argv[1:5]
entry={"subject":subj,"rate":60,"burst":10,"acl":{"skills":["*"],"max_tier":"verified"}}
for p in (os.path.join(etc,"principals.json"), os.path.join(run,"principals.json")):
    d=json.load(open(p)) if os.path.exists(p) else {}
    # govd reads load_principals() -> json[...]["principals"], NOT the top level.
    # A top-level entry is silently ignored: registered, never resolved.
    d.setdefault("principals",{})[name]=entry
    for junk in [k for k,v in list(d.items())
                 if k!="principals" and isinstance(v,dict)
                 and (v.get("subject") in (None,"PASTE_SUBJECT","PASTE_SUBJECT_HERE"))]:
        d.pop(junk); print("   pruned stray top-level entry:",junk)
    json.dump(d,open(p,"w"),indent=2)
    print("   registered",name,"-> principals[] in",p)
PY
  echo "   NOTE: switching this node to ed25519 stops any token_sha principals resolving."
  # govd loads principals ONCE at startup. Reload AFTER the registry is written,
  # or it runs on a snapshot that predates the principal and every assertion
  # resolves to nobody -> HTTP 401 on every claim.
  docker restart "$MARIA_GOVD_CTR" >/dev/null && sleep 5 && echo "   govd reloaded (registry + verifier)"
}

# 3. The compose override: Hermes' own provider config (no proxy), TUI/CLI
#    surface, and govd reachable from the internal cage.
maria-setup-override() {
  local f="$MARIA_REPO/devdoc/tool/docker-compose.override.yml"
  [ -d "$MARIA_REPO/devdoc/tool" ] || { echo "!! $MARIA_REPO/devdoc/tool missing — is MARIA_REPO right?" >&2; return 1; }
  cat > "$f" <<EOF
services:
  maria:
    depends_on: !reset []
    networks: [cage, uplink]
    environment:
      CUSTOM_BASE_URL: ""
      CUSTOM_API_KEY: ""
      HERMES_GOVERN_URL: "http://$MARIA_GOVD_CTR:5773"
    stdin_open: true
    tty: true
EOF
  echo "── wrote $f"
}

# Full first run. Every step is guarded, so re-running is safe.
maria-setup() {
  set -o pipefail
  echo "═══ Maria setup — node $(_maria_ip)"
  maria-setup-govd     || { echo "!! govd setup failed — stopping" >&2; return 1; }
  maria-setup-identity || return 1
  maria-setup-override || return 1
  echo "═══ build"; maria-build || return 1
  echo "═══ start"; maria-up    || return 1
  echo "═══ verify"; maria-doctor
  cat <<EOF

Next: sign in with Hermes' own provider flow, then open the surface —
    maria-login
    maria

Pin a per-model max_tokens BELOW the model's context ceiling. Over it returns
HTTP 400 and surfaces as a nonsensical "Context length exceeded (N tokens)".
EOF
}

# ═════════════════════════ ACCESS ════════════════════════════════════
# Always -u hermes (uid 10000). docker exec defaults to root, which creates
# root-owned files under /opt/data the agent cannot write, and tests with
# permissions the agent does not have.
maria()       { docker exec -it -u hermes "$MARIA_CTR" /opt/hermes/bin/hermes "${@:---tui}"; }
maria-chat()  { docker exec -it -u hermes "$MARIA_CTR" /opt/hermes/bin/hermes chat; }
maria-ask()   { docker exec -u hermes "$MARIA_CTR" /opt/hermes/bin/hermes -z "$*"; }
maria-sh()    { docker exec -it -u hermes "$MARIA_CTR" /bin/bash; }
maria-login() { docker exec -it -u hermes "$MARIA_CTR" /opt/hermes/bin/hermes login; }

# ═════════════════════════ LIFECYCLE ═════════════════════════════════
maria-build() { _maria_compose build maria; }
maria-up() {
  docker network connect maria_cage "$MARIA_GOVD_CTR" 2>/dev/null
  _maria_compose up -d maria || return 1
  # Compose that refuses the file leaves everything untouched and looks like a
  # successful deploy. Verify the container exists rather than trusting exit 0.
  docker ps -a --filter "name=^${MARIA_CTR}$" --format '   {{.Names}} {{.Status}} {{.Image}}' \
    | grep . || { echo "   !! no container — compose refused the file (empty credential?)"; return 1; }
}
maria-down()    { _maria_compose stop maria; }
maria-restart() { _maria_compose restart maria; }
maria-rebuild() { maria-build && _maria_compose up -d --force-recreate maria; }
maria-logs()    { docker logs -f --tail "${1:-80}" "$MARIA_CTR"; }

# ═════════════════════════ HEALTH ════════════════════════════════════
maria-health() {
  python3 - "$(_maria_govd)" "$MARIA_GOVD_CTR" "$MARIA_CTR" <<'PY'
import json, sys, subprocess, urllib.request
govd, gctr, actr = sys.argv[1], sys.argv[2], sys.argv[3]
print("-- govd", govd)
try:
    d = json.loads(urllib.request.urlopen(govd + "/health", timeout=8).read())
    c = d.get("chip", {})
    print("   ok  skills={}  chip_sha={}".format(c.get("skills"), str(d.get("chip_sha"))[:16]))
except Exception as e:
    print("   UNREACHABLE:", type(e).__name__, e)
print("-- identity")
try:
    out = subprocess.run(["docker","exec",gctr,"python3","-c",
        "from infra.govern import govd;c=govd.load_config();"
        "print('   auth_verifier:',repr(c.get('auth_verifier')));"
        "print('   principals:',list(c.get('principals',{}).keys()))"],
        capture_output=True, text=True, timeout=30)
    print(out.stdout.rstrip() or ("   " + out.stderr.strip()[:120]))
except Exception as e:
    print("   govd container unavailable:", e)
print("-- agent")
r = subprocess.run(["docker","ps","--format","{{.Names}}"], capture_output=True, text=True)
if actr in r.stdout.split():
    for cmd in (["docker","exec",actr,"ls","-l","/etc/maria/governed"],
                ["docker","exec","-u","hermes",actr,"/opt/hermes/.venv/bin/python3","-c",
                 "import sys;sys.path.insert(0,'/opt/hermes');from agent import govern_gate as g;"
                 "print('   enabled={} marker={} fail_open={}'.format(g.is_enabled(),g._marker_present(),g._fail_open()))"]):
        o = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        print(("   marker: " + o.stdout.strip()) if "ls" in cmd else (o.stdout.rstrip() or "   " + o.stderr.strip()[:120]))
else:
    print("   container", actr, "not running")
PY
}

# ═══════ the ledger — the ONLY thing that separates the failure modes ═══════
maria-ledger() {
  python3 - "$(_maria_govd)" "$(_maria_tok)" "${1:-10}" <<'PY'
import json, sys, urllib.request
govd, tok, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    req = urllib.request.Request(govd + "/monitor/state", headers={"X-Govd-Monitor": tok})
    d = json.loads(urllib.request.urlopen(req, timeout=8).read())
except Exception as e:
    print("  ledger unreachable:", type(e).__name__, e); raise SystemExit(1)
# `principal` lives on decisions[], NOT runs[] -- runs[] has no such field, so
# reading it there silently shows None for every row.
rows = d.get("decisions") or []
print("runs={}  decisions={}  totals={}".format(len(d.get("runs") or []), len(rows), d.get("totals")))
for x in rows[-n:]:
    print("  {}  {:14} {:22} {:10} {}".format(
        x.get("ts"), str(x.get("principal")), str(x.get("skill")),
        str(x.get("perk")), x.get("decision")))
if not rows:
    print("  (empty -- no claim has ever reached this node)")
PY
}

# Five distinct faults all look like 'agent healthy, every call denied'.
# Rows-all-rejected is AUTHORISATION. No-rows-at-all is WIRING.
maria-doctor() {
  python3 - "$(_maria_govd)" "$MARIA_GOVD_CTR" "$MARIA_ETC" "$MARIA_RUN" <<'PY'
import json, os, sys, hashlib, subprocess, urllib.request
govd, gctr, etc, run = sys.argv[1:5]

print("=== 1. chip serves the gate's skill (hermes:toolgate)")
try:
    d = json.loads(urllib.request.urlopen(govd + "/health", timeout=8).read())
    print("   skills={}".format(d.get("chip", {}).get("skills")))
except Exception as e:
    print("   govd UNREACHABLE:", type(e).__name__, e)

def dex(code):
    o = subprocess.run(["docker","exec",gctr,"python3","-c",code], capture_output=True, text=True, timeout=30)
    return (o.stdout or o.stderr).strip()

print("=== 2. identity scheme wired")
print("  ", dex("from infra.govern import govd;c=govd.load_config();v=c.get('auth_verifier');"
                "print('auth_verifier=%r%s' % (v, '' if v else '   <-- UNSET: ed25519 subjects resolve to nobody'))"))
print("=== 3. image registers the verifier (cyberware #235)")
print("  ", dex("from infra.govern import govd;print('install_builtin_verifier:',hasattr(govd,'install_builtin_verifier'))"))

print("=== 4. our subject is declared")
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey as K
    from cryptography.hazmat.primitives import serialization as s
    kp = os.path.join(etc, "agent-ed25519.key")
    pub = K.from_private_bytes(bytes.fromhex(open(kp).read().strip())).public_key().public_bytes(
        s.Encoding.Raw, s.PublicFormat.Raw)
    mine = "ed25519:" + hashlib.sha256(pub).hexdigest()[:16]
    print("   key subject:", mine)
    rp = os.path.join(run, "principals.json")
    reg = json.load(open(rp)).get("principals", {})   # govd reads THIS, not top level
    for k, v in reg.items():
        print("   {:16} {}".format(k, v.get("subject") or ("token_sha (NOT ed25519)" if v.get("token_sha") else "?")))
    print("   MATCH:", any(v.get("subject") == mine for v in reg.values()), " <- principals[] in", rp)
    stray = [k for k in json.load(open(rp)) if k != "principals"]
    if stray: print("   !! stray TOP-LEVEL keys (ignored by govd):", stray)
except Exception as e:
    print("   FAILED:", type(e).__name__, e)
PY
  echo "=== 5. ledger"
  maria-ledger 5
}

# ═════════════════════════ ADD AN AGENT ══════════════════════════════
#   maria-agent-add maria-chief
maria-agent-add() {
  local name="$1"; [ -n "$name" ] || { echo "usage: maria-agent-add <principal-name>" >&2; return 1; }
  local key="$MARIA_ETC/$name.key"
  [ -s "$key" ] || { openssl rand -hex 32 > "$key" && chmod 600 "$key" && echo "minted $key"; }
  local subj; subj="$(_maria_subject "$key" "$MARIA_ETC/$name.pub")" || return 1
  chmod 600 "$MARIA_ETC/$name.pub"; echo "subject: $subj"
  python3 - "$name" "$subj" "$MARIA_ETC" "$MARIA_RUN" <<'PY'
import json,os,sys
name,subj,etc,run=sys.argv[1:5]
entry={"subject":subj,"rate":30,"burst":5,
       "acl":{"skills":["general:fs","general:search"],"max_tier":"core","secrets":False}}
for p in (os.path.join(etc,"principals.json"), os.path.join(run,"principals.json")):
    d=json.load(open(p)) if os.path.exists(p) else {}
    d.setdefault("principals",{})[name]=entry   # nested — govd ignores top level
    json.dump(d,open(p,"w"),indent=2)
    print("registered",name,"-> principals[] in",p)
print("
ACL is a PURE RESTRICTION -- starts narrow. Widen skills/max_tier if needed.")
PY
  docker restart "$MARIA_GOVD_CTR" >/dev/null && echo "govd reloaded"
}

# fleetdash also binds the tailnet ip, not loopback.
maria-fleet() { echo "http://$(_maria_ip):8787"; }
# ─────────────────────────────────────────────────────────────────────

# ═════════════════════ STATE VOLUME: manage & backup ══════════════════
# /opt/data (HERMES_HOME) is ONE docker-managed volume holding everything the
# agent accumulates: memories, skills, sessions, cron, platforms, plans,
# state.db, kanban.db, projects.db, config.yaml (provider auth).
#
# It is deliberately NOT a host bind mount. A bind mount would put the agent's
# writes in your filesystem AND make everything in that directory reachable by
# the agent. Named volume = the agent's whole world is a blob with no host path.
# These helpers give you management without giving that up.
export MARIA_VOL="${MARIA_VOL:-maria_maria_state}"
export MARIA_BACKUP_DIR="${MARIA_BACKUP_DIR:-$HOME/maria-backups}"
export MARIA_BACKUP_KEEP="${MARIA_BACKUP_KEEP:-10}"

# Size + layout, without entering the agent container.
maria-vol() {
  echo "── volume: $MARIA_VOL"
  docker volume inspect "$MARIA_VOL" --format '   mountpoint: {{.Mountpoint}}   created: {{.CreatedAt}}' 2>/dev/null \
    || { echo "   no such volume"; return 1; }
  docker run --rm -v "$MARIA_VOL":/v:ro alpine sh -c '
    echo "   total: $(du -sh /v 2>/dev/null | cut -f1)"
    echo "   ── largest"
    du -sh /v/* 2>/dev/null | sort -rh | head -12 | sed "s|/v/|      |"'
}

# Browse/repair the volume with the agent STOPPED. Read-write on purpose —
# this is the management path, so treat it as such.
maria-vol-sh() {
  docker ps --format '{{.Names}}' | grep -qx "$MARIA_CTR" \
    && echo "!! $MARIA_CTR is running — stop it first (maria-down) or you may corrupt sqlite" >&2 \
    && return 1
  docker run --rm -it -v "$MARIA_VOL":/v alpine sh -c 'cd /v && exec sh'
}

# Consistent snapshot. Stops the agent by default: state.db/kanban.db/projects.db
# are sqlite with a live -wal, and a hot tar can capture a torn write.
#   maria-backup           # stop, snapshot, restart
#   HOT=1 maria-backup     # snapshot a running agent (may be inconsistent)
maria-backup() {
  mkdir -p "$MARIA_BACKUP_DIR"
  local stamp out was_up=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$MARIA_BACKUP_DIR/maria-state-$stamp.tar.gz"
  if [ "${HOT:-0}" != "1" ] && docker ps --format '{{.Names}}' | grep -qx "$MARIA_CTR"; then
    was_up=1; echo "── stopping $MARIA_CTR for a consistent snapshot"; docker stop "$MARIA_CTR" >/dev/null
  fi
  docker run --rm -v "$MARIA_VOL":/src:ro -v "$MARIA_BACKUP_DIR":/dst alpine \
    tar czf "/dst/$(basename "$out")" -C /src . 2>/dev/null
  local rc=$?
  [ "$was_up" = 1 ] && { echo "── restarting"; docker start "$MARIA_CTR" >/dev/null; }
  [ $rc -eq 0 ] || { echo "!! backup failed" >&2; return 1; }
  echo "── $out  ($(du -h "$out" | cut -f1))"
  # prune oldest beyond MARIA_BACKUP_KEEP
  ls -1t "$MARIA_BACKUP_DIR"/maria-state-*.tar.gz 2>/dev/null | tail -n +$((MARIA_BACKUP_KEEP+1)) \
    | while read -r f; do rm -f "$f" && echo "   pruned $(basename "$f")"; done
}

maria-backups() { ls -lht "$MARIA_BACKUP_DIR"/maria-state-*.tar.gz 2>/dev/null | awk '{print "  "$5, $6, $7, $8, $9}' || echo "  none"; }

# DESTRUCTIVE: replaces the volume's contents. Requires typing the word.
maria-restore() {
  local f="${1:-}"; [ -f "$f" ] || { echo "usage: maria-restore <backup.tar.gz>"; maria-backups; return 1; }
  echo "!! this REPLACES everything in $MARIA_VOL (memories, skills, sessions, auth)"
  printf "   type RESTORE to proceed: "; local a; read -r a
  [ "$a" = "RESTORE" ] || { echo "   aborted"; return 1; }
  docker ps --format '{{.Names}}' | grep -qx "$MARIA_CTR" && docker stop "$MARIA_CTR" >/dev/null
  docker run --rm -v "$MARIA_VOL":/dst -v "$(cd "$(dirname "$f")" && pwd)":/src:ro alpine \
    sh -c "rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf /src/$(basename "$f") -C /dst" \
    && echo "   restored from $f"
  docker start "$MARIA_CTR" >/dev/null 2>&1 && echo "   $MARIA_CTR restarted"
}
