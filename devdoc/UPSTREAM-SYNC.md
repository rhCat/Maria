# Upstream sync — the record, and what the next one should check

[`BRANCHING.md`](BRANCHING.md) says *how* to sync. This file records what actually happened when we did,
because the interesting part was not the merge mechanics — it was that upstream moved the floor our gate
stands on, and a green test suite would not have told us.

---

## Sync 1 — 2026-07-30 · upstream `v0.19.1`

The first sync since the fork diverged.

| | |
|---|---|
| range | `fb0ed8396` (2026-07-20) → `cc4cab2f5` (upstream `v0.19.1`, 2026-07-30) |
| commits | **3048** |
| conflicts | **2** — `agent/tool_executor.py`, `cli-config.yaml.example` |
| auto-merged | `model_tools.py`, `tools/approval.py` |
| merge commit | `df4e44870` |

`main` fast-forwarded cleanly (it is a pure ancestor of upstream, as intended — nothing Maria has ever
been committed there).

### What upstream changed under us

Upstream **refactored the block-decision logic out of both executors into one shared helper**,
`_run_agent_tool_execution_middleware`. Before, `execute_tool_calls_concurrent` and
`execute_tool_calls_sequential` each carried their own copy of the scope-block → plugin-block → guardrail
chain, which is why our gate had to be inserted **twice**. Now there is a single `_authorized_dispatch`
closure and both executors route through it.

So our two hooks collapsed into **one call site**, placed after the guardrail check and folded into the
existing block path alongside `plugin_block` and `guardrail_block`:

```python
if block_message is None and guardrail_decision is None:
    block_message = _apply_govern_gate(agent, function_name, final_args)
    if block_message is not None:
        block_error_type = "govern_block"
```

**This is a better position than the one we had**, in two independent ways:

1. **Tighter waist.** All **11** dispatch sites (1 in `concurrent`, 10 in `sequential`) funnel through
   `_authorized_dispatch`, and `execute_tool_calls_segmented` delegates to those two. One gate covers
   every path — where previously two hooks had to stay in sync by hand.
2. **A more honest claim.** It runs on **`final_args`** — *after* Relay rewrites and tool-request
   middleware — so `ARGS_DIGEST` now covers what will actually execute, rather than what the model first
   proposed. The old placement gated the pre-middleware args; a rewrite between gate and dispatch was
   ungoverned.

### `cli-config.yaml.example`

Both sides appended at EOF — a textbook tail conflict, no semantics. Upstream's command-helper block
continues the vault section, so it goes first; our `governance:` block stays a top-level section at the end.

### The additive invariant held

BRANCHING.md's rule — *our edits are additive hooks, zero deletions* — is what made a 3048-commit merge a
30-minute job instead of a negotiation. Post-merge delta on the conflicted file: **+71 lines, 0 upstream
lines removed.** Keep it that way.

---

## The trap worth not rediscovering

**`tests/test_govern_gate.py` passed 38/38 before a single conflict was resolved, and it would have passed
with the gate deleted entirely.** It covers the gate *module* — `is_enabled`, verdict parsing, the
fail-closed posture — and contains no reference to `tool_executor` at all.

That is exactly the shape of cyberware `#235` (*"a config key registers nothing"*): both halves correct in
isolation, nothing wiring them together, and no unit test positioned to notice. After a refactor that moves
the call site, **a green gate suite is evidence about the gate, not about whether it is reached.**

So the wiring was proven directly, against the real merged code — drive
`_run_agent_tool_execution_middleware` with `_apply_govern_gate` swapped for a probe:

```
deny  : gate_called=True   executed=False      <- the gate STOPS execution
allow : gate_called=True   executed=True       <- and lets it through
args  : gate saw ['content', 'path']           <- on the real args
```

Then **mutation-checked**: comment out the four-line gate call and that proof must go red. It does —
`execute() ran despite a deny`. A guard test never seen failing is not yet evidence.

The harness lives in the scratchpad, not the repo. **It should be a real test** — see *Next sync*.

---

## Next sync — the checklist

1. **`git fetch upstream && git checkout main && git merge --ff-only upstream/main`**, then merge `main`
   into `dev`. Never the other direction.
2. **Expect the conflict set to be small** and confined to the four upstream-owned files in BRANCHING.md's
   table. If it isn't, something drifted from the additive rule — find out what before resolving.
3. **Re-verify the waist.** Do not assume the gate call site survived a refactor intact. Confirm every
   dispatch path still funnels through whatever helper `_apply_govern_gate` sits in:
   ```sh
   grep -n "_run_agent_tool_execution_middleware(" agent/tool_executor.py   # every call site
   grep -n "^def execute_tool_calls" agent/tool_executor.py                 # every executor
   ```
   If upstream splits that helper again, the gate must move with it — and one un-funnelled path is a hole,
   not a regression you can defer.
4. **Prove the gate blocks, don't infer it.** Run the wiring proof and its mutation. `pytest
   tests/test_govern_gate.py` alone is not sufficient and never was.
5. **Check `skip_govern_gate` still reaches `handle_function_call`** in `model_tools.py`, and that the two
   dispatcher re-entry sites in `tool_executor.py` still pass it. Without it every call double-claims —
   which is not a security hole, but it doubles the ledger and the latency.

## Known-stale

- `BRANCHING.md` records upstream as **1320 ahead**; it was 3048 at this sync. Treat that figure as a
  timestamp, not a fact.
- Its *"Not yet done"* list still names the deployment config as untracked — fixed in `393a39c91`.
- The venv cannot collect 12 test modules (`tests/acp/*`, `tests/acp_adapter/*`, `tests/tools/test_mcp*`):
  the optional `acp` and `mcp` extras are not installed. Pre-existing, unrelated to any sync — but it
  means "the suite passed" has an asterisk until they are.

## Related

- [`BRANCHING.md`](BRANCHING.md) — why `dev` is the trunk, and the sync surface to keep small
- [`BREAKPOINT.md`](BREAKPOINT.md) — session state and the wider trap list
- [`../docs/design/cyberware-governance-flow.md`](../docs/design/cyberware-governance-flow.md) — what the
  gate governs, and what it does not
