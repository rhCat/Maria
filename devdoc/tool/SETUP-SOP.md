# SOP — bringing Maria up on a shared govd node

Companion to [`MariaSetup.tla`](MariaSetup.tla) (the ordering contract, machine-checked),
[`setup_maria_node.sh`](setup_maria_node.sh) (this SOP, executable),
[`GOVERNANCE.md`](GOVERNANCE.md) and [`VPS-SETUP.md`](VPS-SETUP.md).

**Topology.** One govd on the node; each agent authenticates as its own named
principal with its own key; all write to one shared ledger. The fleet board
shows the *node* — agents appear as the `principal` column on run rows, never as
board entries.

---

## The one rule this SOP exists to enforce

> **govd reads its configuration once, at process start.**
> Correct files on disk are not a working agent.

`MariaSetup.tla` states this and TLAPS proves it (28/28 obligations). Every
precondition for a claim to authenticate names a **loaded** value:

```
Authenticates ==
    /\ agentSubject   # NoSubject
    /\ loadedVerifier = "ed25519"
    /\ agentSubject  \in loadedRegistry
```

`Reload` is the only action that copies disk state into the process. So the
ordering is forced, and it is the step most easily skipped:

```
   write auth_verifier ─┐
                        ├─→ RELOAD ─→ agent can authenticate
   register principal ──┘
```

Reload between the two writes leaves the process serving a snapshot that
predates the second one. TLC refutes `DiskCorrectImpliesAuth` in three steps and
returns that trace — a state where the disk is fully correct and the agent still
gets 401. That counterexample is not hypothetical; it is the outage this SOP was
written after.

---

## Preconditions

| | check | fails as |
|---|---|---|
| P1 | govd container running, chip serves `hermes:toolgate` | 401, empty ledger |
| P2 | image has cyberware **#235** (`install_builtin_verifier`) | 401, empty ledger |
| P3 | agent key exists, 64 hex, mode 0600, owned by the agent uid | agent cannot mint |
| P4 | subject declared under the **`principals`** key, not top level | 401, empty ledger |
| P5 | govd reloaded **after** P1–P4 | 401, empty ledger |

All five fail identically from inside the container. Do not diagnose by symptom.

---

## Procedure

**1. Chip.** Confirm the node serves the gate's skill. The gate claims against
`hermes:toolgate`; an unverified skill is a fail-closed deny.

```
curl -fsS http://<tailnet-ip>:5773/health | grep -o '"skills": [0-9]*'
```

If absent, restart the govd container — its CMD re-runs `chipfetch`.

**2. Identity scheme.** Set `auth_verifier` in the govd config. The verifier
*code* shipping is not enough — a config key is what registers it.
**Do not restart yet.**

**3. Agent identity.** Mint `openssl rand -hex 32`. Derive the subject as
`"ed25519:" + sha256(raw_pub)[:16]` — byte-identical to `infra.cwp.sign.keyid`,
so it never needs a cyberware checkout, which matters because a node's clone is
routinely older than its image.

**4. Register.** Write the subject under the **`principals`** key.
`load_principals()` returns `json[...]["principals"]`; a top-level entry is
silently ignored — registered, never resolved. Write to both `etc/` (source of
truth) and `run/` (what govd mounts), because `deploy-node.sh` copies `etc/`
over `run/` on every node redeploy.

**5. Reload — once, here.** This is step P5 and the whole point of the ordering.

**6. Container.** Build and start with the override. `/run/maria` is tmpfs, so
the credential is re-injected from the launch environment on **every** start —
a recreate without `MARIA_GOVD_TOKEN` comes up with no credential at all.

**7. Provider.** `hermes setup model` inside the container (`hermes login` was
removed). Persists on the state volume, so later recreates do not need it again.

---

## Verification gates — in this order

```
docker exec maria ls -l /etc/maria/governed        # root root  (H4 marker)
docker logs maria 2>&1 | grep assert-governed      # gate ON, fail-closed
bash check-maria-registration.sh                   # verdict: REGISTERED
```

Then one real tool call, and read the **ledger** — not the agent's error text:

| ledger after a turn | meaning | act on |
|---|---|---|
| row with your principal | working | — |
| rows, all `reject` | **authorisation** | ACL too narrow, `expires_at`, `revoked` |
| **no rows at all** | **wiring** | P1, P2, P4 or P5 |

A 401 is refused *before* any run is recorded, which is why the wiring case
leaves no trace. A 403 means authentication **succeeded** and policy refused —
that is progress, not a failure.

The agent's own diagnosis is unreliable here: a 401 surfaces to the model as a
tool-authorization problem, and it will suggest reconfiguring tools or profiles.
Those are two layers above the actual fault.

---

## Known defect — ed25519 does not authenticate

On a node where **every** precondition above verifies, ed25519 claims still
return 401 while `token_sha` authenticates and evaluates normally. Same registry,
same process, same request; only the scheme differs.

Evidence gathered: subject matches the agent's keyid byte-for-byte; clocks
identical across host and both containers; signature and TTL accepted by a
`Verifier` constructed manually in the same image; `auth_verifier` and the
registry both present on disk 18 minutes before the process started; the shipped
`resolve_principal` byte-identical to the reference.

Conclusion: `_VERIFIERS` in the *serving* process does not contain `"ed25519"`,
so `subject_of` returns `None` before any subject comparison. Neither
`install()` nor `register_verifier()` logs, so this is invisible from outside —
which is precisely why the spec models loaded state separately.

**Workaround** until fixed: register the principal with `token_sha`, clear
`auth_verifier`, and set `HERMES_GOVERN_AUTH_SCHEME=token`. This is a real
downgrade — a static bearer crosses the wire and is replayable within its
lifetime — so treat it as temporary, not as the destination.

---

## Traps

- **Services bind the tailnet IP, not loopback.** govd `:5773`, per-agent govd
  `:5774`, fleetdash `:8787`. `127.0.0.1` gives connection refused and reads
  exactly like the service being down.
- **A failed credential lookup is a silent no-op deploy.** compose refuses the
  whole file and leaves running containers untouched. Verify `Created` moved.
- **compose interpolates the entire file** even when starting one service, so
  unrelated services' required variables must still resolve.
- **The agent-principal and monitor tokens are different things.** One makes
  claims, the other reads the ledger. Never substitute one for the other.
- **`deploy-node.sh` rewrites `govd.json` from scratch**, dropping
  `auth_verifier`. Re-run step 2 and step 5 after any node redeploy.
- **A fix in git is not a fix in the running image.** Gate changes need a
  rebuild, not a restart.
