# cyberware v1.1 — pm report

*Snapshot: 2026-07-24.* Tracking pass (`DRY_RUN`): the plan classified, nothing fired. Progress is redeemed, not asserted — see §7.

## 1. Roll-up

**Status: ok** (tracking pass)

**Playbook:** 0 of 10 steps redeemed — `░░░░░░░░░░░░░░░░░░░░` 0%

**Program:** 0 of 10 DAG tasks redeemed — `░░░░░░░░░░░░░░░░░░░░` 0%

`0 redeemed · 9 blocked:deps · 1 dry`

Done-ledger: 0 pass entries (chain not re-verified here — see §7).

## 2. Milestones

| milestone | rung | closure | gate | status |
|---|---|---|---|---|
| **M0** — contained substrate | 0 | 0/2 | `MCG-M0-T02-image-built` | open |
| **M1** — per-agent govd (stand-in) | 1 | 0/3 | `MCG-M1-T01-peragent-node-health` | open |
| **M2** — central chip carries the gate | 2 | 0/4 | `MCG-M2-T01-central-serves-gate` | open |
| **M3** — central governance (one principal) | 3 | 0/7 | `MCG-M3-T02-govern-central, MCG-M3-T03-retire-peragent` | open |
| **M4** — one shared audit trail | 4 | 0/8 | `MCG-M4-T02-central-audit` | open |

_Closure is the transitive dependency cone of each milestone's gate task(s), redeemed against the done-ledger — the same roll-up `cws-observe/status` computes._

## 3. Ready to pull

| task | validator | title |
|---|---|---|
| `MCG-M0-T01-no-plaintext-secrets` | `general:sec` | compose carries no plaintext secret values |

## 4. Blocked

**Blocked on dependencies**

| task | validator | waiting on |
|---|---|---|
| `MCG-M0-T02-image-built` | `general:docker` | `MCG-M0-T01-no-plaintext-secrets` |
| `MCG-M1-T01-peragent-node-health` | `general:net` | `MCG-M0-T02-image-built` |
| `MCG-M2-T01-central-serves-gate` | `general:http` | `MCG-M1-T01-peragent-node-health` |
| `MCG-M2-T02-central-ledger-intact` | `cws:cws-ledgercheck` | `MCG-M2-T01-central-serves-gate` |
| `MCG-M3-T01-maria-principal` | `general:http` | `MCG-M2-T01-central-serves-gate` |
| `MCG-M3-T02-govern-central` | `hermes:toolgate` | `MCG-M3-T01-maria-principal` |
| `MCG-M3-T03-retire-peragent` | `cws:cws-deploy` | `MCG-M3-T02-govern-central` |
| `MCG-M4-T01-fleet-registered` | `general:http` | `MCG-M2-T01-central-serves-gate` |
| `MCG-M4-T02-central-audit` | `cws:cws-ledgercheck` | `MCG-M3-T02-govern-central`, `MCG-M4-T01-fleet-registered` |

**Blocked on validator**

_None._

## 5. What this run drove

_Tracking pass — nothing was driven. Re-run without `DRY_RUN` to drive the ready set in §3._

## 6. Honest status — what is not yet redeemed

- **9 steps blocked on dependencies** — upstream tasks must redeem first (§4).
- **Open milestones:** M0, M1, M2, M3, M4 — the spine still ahead (§2 has the closure ratios).
- **Chain caveat:** this report reads done-ledger `pass` entries without re-verifying the prev-hash chain; `cws-observe/status` re-verifies the chain — run it for the chain-trusted picture.

## 7. Verify it yourself

```sh
# the chain-verified milestone picture (re-verifies the done-ledger prev-hash chain)
python3 -m infra.tool.skilltest --skill cws-observe --perk status
# the cws-pm self-test (asserts pm.json)
python3 -m infra.tool.skilltest --skill cws-pm --perk run
# re-render this board without firing
PLAYBOOK=<playbook> SWARM_DIR=<swarm> DRY_RUN=1 RECORD_STORE=<dir> python3 cws_pm.py
```

`pm.json` is the machine-readable twin of this report — same data, asserted by the self-test.
