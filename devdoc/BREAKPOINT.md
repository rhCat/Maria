# BREAKPOINT — 2026-07-26

Where the work stopped and how to pick it up. Spans two repos: **Maria** (this one) and **cyberware**
(`/Volumes/prod/hunyuan/cyberware`, `github.com/rhCat/cyberware`).

Everything below was measured against the live fleet, not inferred.

---

## The through-line

The session started from one observation — *"the fleet monitor shows pending with no values"* — and the
answer turned out to be structural rather than cosmetic: **Maria's tool calls are governed but not
executed by cyberware.** `govd` blesses; Hermes' own handler runs the tool; `exod` is never reached. So the
ledger records that permission was granted and cannot record that the action happened.

Full write-up: [`docs/design/cyberware-governance-flow.md`](../docs/design/cyberware-governance-flow.md).

---

## Shipped

### cyberware — merged to `main`, 5 commits unreleased since `v1.8.0`

| PR | what |
|---|---|
| #232 | **auth verifier seam** — `resolve_principal(bearer, registry, verifier)`, pluggable `bearer → subject` resolver; default `token_sha` unchanged |
| #233 | **fleetdash approve button** + `POST /approve`, mutation-verified Playwright E2E |
| #234 | **Ed25519 verifier** — offline, issuer-free identity; DSSE assertion, replay-guarded |
| #235 | **wiring fix** — a config key registers nothing; `serve()` now installs the named verifier |

### Maria — `feat/ed25519-assertions`, pushed, **no PR open**

- `305090a48` — the 403/409 transport fix (see *Bugs found*, below)
- `1f37aa5e0` / `9abd40657` — the two harnesses
- `aeee24b29` — mints short-lived Ed25519 assertions instead of a static bearer
- `0f863a060` — the governance-flow design doc

### Deployed and proven

Maria now authenticates with a **fresh Ed25519 assertion per claim**, verified offline by the node:

```
real key       -> allow,  chain records principal=agent-1
undeclared key -> 401
subject         ed25519:6808fe357b837cfb   (= sha256(pubkey)[:16], verified)
```

A full 5-turn LLM-driven round passed 4/4 under this identity — reads allowed, write and exec pushed back,
Maria correctly reporting both refusals. Session `20260726_035707_659f78`.

---

## Where it stopped

**The last thing standing is `v1.9.0`.** You said tag once a round was demonstrated. It has been.
5 commits are unreleased; the body image was built by manual `workflow_dispatch`, so `:latest` is currently
ahead of the newest tag.

**And Maria's branch has no PR.** Four commits sitting pushed.

---

## Blocked — needs a decision or a machine I can't reach

1. **Transmutation cannot see new code.** The alembic worker re-serves a cached clone and stamps it with the
   *requested* commit hash. A job for `2e34921d` returned evidence identical to the 6-day-old
   `cyberware-dev-24fbe05`, missing files provably in the newer tree. **Never trust `metadata.commit_hash`** —
   verify by counting functions for a file that exists only in the new commit. Cache invalidation
   (`/rescan`, `/prune-repos`, `/cleanup`) takes **no parameters** — fleet-wide, so not fired to unblock one
   repo. The surgical fix is clearing that repo's cached clone on the DGX.
2. **cibatio renders no judgment.** Reports `provider: local:ornith` against the dead
   `100.101.222.80:4000` despite `INTEL_MODEL` being set; emits a zero-byte event stream. `INTEL_*` is not
   reaching the engine. Live intel path is `http://100.74.54.74:8081/v1`, model `laguna-s-2.1-nvfp4`.
3. **`/run-conservation-stack` exits 4 instantly**, blocking putrefactio's walked-ledger channel. Log is on
   the DGX at `/warehouse/tooling/logs/runs/`, unreadable from here. Workaround: `ALLOW_DEGRADED=1`, which
   only costs the resource books.
4. **`selfmod` is approvable.** Per-call human approval resolves it to `allow`; only root-ownership of
   `/opt/hermes` stopped the write. "Never ACL-loosened" means no *standing* grant — it does not make the
   perk unreachable. **Undecided: should a human be able to approve it at all?** Currently reported by the
   harness, deliberately not asserted either way.
5. **No approval channel for a caged agent.** Every `resolve_gateway_approval` caller is a chat-platform
   adapter or a TTY; the cage reaches neither. 45 push_backs on `maria-dev-mac`, 9 approvals — **all
   synthetic, from a test harness**. The human gate has never once been answered by a person.

---

## Next, in order

1. **Tag `v1.9.0`** — releases body/server/modelcheck properly.
2. **Open the Maria PR** for `feat/ed25519-assertions`.
3. **Phase 2 — put exod back in the path.** Vendor the ~59 stdlib WS lines from
   `cyberware/infra/govern/govd_client.py` (delegated frames only — never import the module, it carries
   `run_governed`, the cooperative path that executes snippets locally). Then route `terminal` →
   `hermes:toolgate/run`, whose destructive floor already exists and is never called. Needs a shared **cargo**
   work volume, which forces the work/self split: `auth.json` / `config.yaml` / `sessions/` must stay
   unreachable from any governed step.
4. **Person-principals + an `acl.approve` axis** — the unlock for a real `approved_by`. Fixes the fleetdash
   button, the local dash, and the unaudited reveal in one change.
5. **The OIDC overlay**, if org SSO is ever wanted: authenticate to Auth0 → receive a short-lived Ed25519
   **certificate** signed by an operator CA → verified offline against a pinned CA pubkey. SSH-CA / Sigstore
   shape. Moves the online dependency to enrolment, and degrades correctly — without it, the Ed25519 half is
   a complete working system.

---

## Bugs found (all fixed unless noted)

- **govd signals verdicts with non-2xx** — 403 reject, 409 push_back — and `urlopen` raises on both, so every
  destructive claim collapsed into a fail-closed `govd HTTP <code>`. **Maria had been read-only**, and the
  human approval gate was unreachable. The tests missed it by mocking `200` for a response the node never
  sends.
- **A config key registers nothing** — `auth_verifier: "ed25519"` with no `register_verifier` call meant every
  claim failed closed on a scheme that didn't exist. Both halves individually correct; no unit test could
  catch it.
- **`.strip()` on a binary key** — ~5% of random 32-byte keys begin or end with an ASCII whitespace byte and
  were silently truncated to 31 and rejected. Intermittent and key-dependent.
- **`mirror_dir` is `None` under `--no-mirror`** — crashed the approve handler.
- **Not a bug, but it looked like one:** the cooperative client verifies against the image's bundled
  `/app/skillChip` while govd blesses from the *composed* tree at
  `/app/.cyberware/skillChip-cloud/composed`. Different trees → bogus "drift". Pass `--registry`.

---

## Traps worth not rediscovering

- **`GOVD_AUTH_VERIFIER` must be an env var**, never `govd.json` — the body entrypoint **regenerates that
  file on every boot** and silently wipes it. `principals.json` survives.
- **`docker-compose.maria.yml` is untracked.** The deployment config edited all session is not under version
  control. Same for `Dockerfile.maria`, `docker/litellm/`, `scripts/verify-maria-cage.sh`.
- **Its documented launch line has two bugs**: the wrong token path (`maria/etc/monitor.token` is a
  *fleetdash monitor* token — the principal is `monitors/maria-govd-agent1.token`), and
  `LITELLM_MASTER_KEY` generated without the mandatory `sk-` prefix.
- **`/opt/data/config.yaml` is on a persistent volume** and holds the api key Maria actually sends — a fresh
  `LITELLM_MASTER_KEY` on rebuild desyncs her from the proxy.
- **The worker is `100.125.82.27:11080`**, not 8080 (that's an SPA). Submit jobs by **commit SHA**; a branch
  name fails with `Cannot resolve ref` even when pushed and public.
- **`gh` needed `--no-gpg-sign`** on every commit — `commit.gpgsign=true` with no agent silently drops the
  commit object.
- **`docker exec … python3 - "$ARG" <<'PY'`** runs nothing, prints nothing, and exits 0. Interpolate instead,
  and verify the file afterwards.

---

## The recurring failure mode

Seven times this session something reported success while achieving nothing: tests mocking `200` for a `409`;
an `allow` for an action never performed; cibatio `done 18/18, flagged 0` with a zero-byte event stream; a
`LIMIT` that judged the wrong 40 functions; a transmutation ground silently missing its target file; a
`docker exec` that ran nothing; a config write regenerated away on restart.

**Exit codes were honest about crashes and silent about doing nothing.** Every green result here was earned
by checking content — function counts per target file, chain rows, `run_values` row counts, a mutation that
must turn the suite red. Guard tests in particular are mutation-verified: disable the guard, watch it fail.
A guard test never seen failing is not yet evidence.
