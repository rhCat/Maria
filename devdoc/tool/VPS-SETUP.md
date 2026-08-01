# Maria on a VPS — shared-node deployment

Status 2026-08-01. Companion to [`GOVERNANCE.md`](GOVERNANCE.md),
[`docker-compose.maria.yml`](docker-compose.maria.yml) and
[`setup_maria.sh`](setup_maria.sh) (the native, non-container variant).

**Topology: one govd, many agents.** A single govd runs on the VPS as a fleet
node. Every agent — on that box or elsewhere — authenticates to it as its own
**named principal** with its own key and its own capability scope, and all of
them write to **one shared ledger**. The board shows one node; agents are
distinguished by the `principal` column on run rows.

This is the direction `governance-pm` drives at (`M3-T03-retire-peragent`). The
older shape — a per-agent govd, one node per agent, separate ledgers — is what
that milestone retires.

```
            ┌──────────── VPS ────────────┐
 agent A ──►│                             │
 agent B ──►│  govd  (fleet node "maria")  │──► one ledger, rows tagged
 agent C ──►│  chip: skillChip + MO        │    principal=A|B|C
            └──────────────────────────────┘
```

---

## 0. Prerequisites

- Docker with compose v2
- **Tailscale**, joined. Not optional: govd is published on the node's tailnet
  IP only. On a VPS, binding it to the public interface would expose the
  governance server to the internet.
- A **GHCR PAT** with `read:packages` — `ghcr.io/rhcat/cyberware-body` is private
- An **MO token** — the chip is read live from the private `skillchipMO` repo,
  never baked into an image

## 1. The govd node

```bash
NODE=maria BIND_IP=$(tailscale ip -4 | head -1) bash deploy-node.sh
```

Creates `~/.cyberware/maria/etc/` (`monitor.token`, `mo.token`, and the
`principals.json` it expects you to supply) and publishes govd on
`BIND_IP:5773` only. Run `host-firewall.sh` too — it sets `default deny
incoming` and leaves only Tailscale.

Confirm the chip actually serves the gate's skill. Hermes claims against
`hermes:toolgate`, and an **unverified skill is a fail-closed deny**:

```bash
curl -fsS http://<tailnet-ip>:5773/health | python3 -m json.tool | grep -E 'skills|chip_sha'
```

A stale chip is a real failure mode, not a hypothetical — this node shipped
with 242 skills and no `hermes:toolgate` until it re-fetched. Restarting the
container re-runs `chipfetch`.

## 2. Turn on the identity scheme

The ed25519 seam needs a **config key**, not just code. Without it every
`subject`-based principal resolves to nobody:

> a config key on its own registers nothing … setting `auth_verifier: "ed25519"`
> would fail closed on every claim: correct, but silently unusable.
> — `govd.install_builtin_verifier`

```bash
python3 -c "import json,os;p=os.path.expanduser('~/.cyberware/maria/run/govd.json');d=json.load(open(p));d['auth_verifier']='ed25519';json.dump(d,open(p,'w'),indent=2)"
```

`GOVD_AUTH_VERIFIER` in the environment also works and takes precedence, but
does not survive a redeploy.

Verify the image is new enough — the verifier *code* shipped in cyberware #234,
but #235 is what made the config key install it. Importing `ed25519_auth`
successfully only proves #234:

```bash
docker exec cyberware python3 -c "from infra.govern import govd; print('#235 present:', hasattr(govd,'install_builtin_verifier'))"
```

**Switching a node to `ed25519` stops its `token_sha` principals resolving.**
The verifier is per-node and an unknown scheme fails closed rather than falling
back to the secret path. Check nothing else authenticates to this govd first.

## 3. An identity per agent

Repeat per agent. The name is free-form; `<node>-<role>` matches fleet
convention (`maria-agent`, `maria-chief`).

```bash
mkdir -p ~/.cyberware/maria/etc && openssl rand -hex 32 > ~/.cyberware/maria/etc/agent-ed25519.key && chmod 600 ~/.cyberware/maria/etc/agent-ed25519.key
```

The subject is a truncated sha256 of the raw public key — no cyberware
checkout needed, which matters because a node's clone is often older than the
image:

```bash
cd ~/.cyberware/maria/etc && python3 -c "import hashlib;from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey as K;from cryptography.hazmat.primitives import serialization as s;pub=K.from_private_bytes(bytes.fromhex(open('agent-ed25519.key').read().strip())).public_key().public_bytes(s.Encoding.Raw,s.PublicFormat.Raw);open('agent-ed25519.pub','w').write(pub.hex()+chr(10));print('subject: ed25519:'+hashlib.sha256(pub).hexdigest()[:16])"
```

Register it. **Edit `~/.cyberware/maria/etc/principals.json`, not the copy under
`run/`** — `deploy-node.sh` does `install "$CFG/principals.json"
"$RUN/principals.json"` on every deploy, so edits to `run/` are silently
overwritten:

```json
{
  "maria-agent": { "subject": "ed25519:…", "rate": 60, "burst": 10,
                   "acl": { "skills": ["*"], "max_tier": "verified" } },
  "maria-chief": { "subject": "ed25519:…", "rate": 30, "burst": 5,
                   "acl": { "skills": ["general:fs","general:search"],
                            "perks": { "general:fs": ["read"] },
                            "max_tier": "core", "secrets": false } }
}
```

`acl` is `{skills, perks, max_tier, secrets, expires_at?, revoked?}` —
canonical ids and tier labels only, never a token value. It is a **pure
restriction**: `acl_allows` only ever appends a hard, non-self-approvable
reject, and can never relax another gate. `acl_canonical` folds `pid` and
`token_sha` into the digest, so two principals with identical ACLs still get
distinct hashes — one agent's attestation cannot be replayed as another's.

Use `expires_at` and `revoked` from the start: with N agents on one node, an
unbounded key is N times the exposure, and revoking one should not mean
re-keying the fleet.

```bash
docker restart cyberware && docker exec cyberware python3 -c "from infra.govern import govd;c=govd.load_config();print('auth_verifier:',repr(c.get('auth_verifier')));print('principals:',list(c.get('principals',{}).keys()))"
```

## 4. The agent container

Inference goes through Hermes' own provider config rather than a proxy —
`config.yaml` is, per `runtime_provider.py`, "the single source of truth for
endpoint URLs", and it persists on the state volume.

```yaml
# devdoc/tool/docker-compose.override.yml
services:
  maria:
    depends_on: !reset []
    networks: [cage, uplink]
    environment:
      CUSTOM_BASE_URL: ""
      CUSTOM_API_KEY: ""
      HERMES_GOVERN_URL: "http://cyberware:5773"
    stdin_open: true
    tty: true
```

Then, from the **repo root** (the directory containing `devdoc/`, since the
build context is `../..` relative to the compose file):

```bash
docker compose -f devdoc/tool/docker-compose.maria.yml -f devdoc/tool/docker-compose.override.yml build maria
docker network connect maria_cage cyberware
GOVD_BIND=$(tailscale ip -4 | head -1) MARIA_GOVD_TOKEN=$(cat ~/.cyberware/maria/etc/monitor.token) MARIA_ED25519_KEY=$(cat ~/.cyberware/maria/etc/agent-ed25519.key | tr -d '\n') docker compose -f devdoc/tool/docker-compose.maria.yml -f devdoc/tool/docker-compose.override.yml up -d maria
```

`docker network connect` is required because `cage` is `internal: true` — no
route off the host — while govd is a standalone `deploy-node.sh` container.
Agents on **other** hosts reach the shared govd over the uplink instead, and
trade some of the cage's containment for it.

Sign in and open the surface. Both TUI and CLI construct the same
`run_agent.AIAgent` and funnel through the same gate, so this surface choice
costs nothing on governance:

```bash
docker exec -it maria /opt/hermes/bin/hermes login
docker exec -it maria /opt/hermes/bin/hermes --tui
```

Pin a per-model `max_tokens` **below** the model's context ceiling. A request
over it returns HTTP 400 and surfaces as a nonsensical
`Context length exceeded (N tokens)` naming nothing useful.

## 5. Verify, in order

```bash
docker exec maria ls -l /etc/maria/governed          # root root — H4 marker
docker logs maria 2>&1 | grep assert-governed        # gate ON, fail-closed
```

Then have the agent make one trivial tool call and read the node's ledger:

```bash
python3 -c "import urllib.request,os,json;tok=open(os.path.expanduser('~/.cyberware/maria/etc/monitor.token')).read().strip();d=json.loads(urllib.request.urlopen(urllib.request.Request('http://<tailnet-ip>:5773/monitor/state',headers={'X-Govd-Monitor':tok}),timeout=8).read());r=d.get('runs',[]);print('runs',len(r));[print(' ',x.get('ts'),x.get('principal'),x.get('skill'),x.get('decision')) for x in r[-5:]]"
```

## The failure mode that matters

**Five different faults all present as "agent healthy, every tool call
denied."** They are indistinguishable from inside the container and from the
agent's own logs. The node's ledger is the only thing that separates them:

| ledger shows | cause |
|---|---|
| rows, all `reject` | subject mismatch, ACL too narrow, or `expires_at`/`revoked` |
| **no rows at all** | gate never verified `hermes:toolgate` (stale chip), `auth_verifier` unset, image pre-#235, or the agent cannot reach govd |

Claims arriving and being rejected is an *authorisation* problem. No claims at
all is a *wiring* problem. Check which before changing anything — every one of
these was hit at least once during this deployment, and guessing costs more
than looking.

## Traps

- **Services bind the tailnet IP, not loopback.** govd `:5773`, a per-agent govd
  `:5774`, fleetdash `:8787`. `127.0.0.1` gives connection refused and looks
  exactly like the service being down. Hit the bind address.
- **A failed credential lookup is a silent no-op deploy.** If a `cat` in the
  launch line fails, the variable is empty, compose refuses the file with
  *"required variable … is missing a value"*, and the running containers are left
  untouched and healthy. Verify the container's `Created` timestamp moved.
- **`deploy-node.sh` overwrites `run/` from `etc/`** and rewrites `govd.json`
  from scratch. Edits made in `run/` — including `auth_verifier` — are lost on
  the next node redeploy.
- **An agent key is never created for you.** `deploy-node.sh` mints
  `monitor.token`, never an ed25519 key. That is a separate manual step.
- **The agent-principal and monitor tokens are different things.** One makes
  claims, the other reads the ledger. Never reuse one for the other.
- **A fix in git is not a fix in the running image.** Gate changes need a rebuild
  and redeploy.
- **`principal` is the ledger's join key.** Settle naming before you have rows
  worth auditing.

## Not yet executed end-to-end

The govd side (chip refresh, `auth_verifier`, principal registration, the
subject formula — verified byte-identical against `sign.keyid`) has been run on
a live node. The container launch and first-claim verification have not been
completed on a VPS at the time of writing.
