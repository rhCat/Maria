# Governance flow — what cyberware replaced, and what it did not

Maria runs every tool call through cyberware's `govd`. This note records **exactly which part of the old
behaviour that replaced**, because the answer is narrower than "Hermes is now governed", and the difference
is load-bearing for anyone reasoning about what a ledger entry proves.

Measured against a live node on 2026-07-26. Function counts and control-flow figures come from an alembic
citrinitas ground over `hermes-agent-tools` @ `3ef6bbd2` and `cyberware` @ `1838455`.

## 1. What the native layer was

Before cyberware, governance lived entirely in `tools/approval.py`: **111 control-flow graphs**, and its
shape is unmistakable once you look at the function names —

| function | nodes | cyclomatic |
|---|---|---|
| `check_all_command_guards` | 185 | **51** |
| `_quoted_grep_pattern_spans` | 103 | 29 |
| `check_execute_code_guard` | 95 | 22 |
| `prompt_dangerous_approval` | 75 | 21 |
| `_run_approval_gate` | 80 | 21 |
| `_iter_shell_command_starts` | 89 | 20 |

plus `_read_shell_word`, `_shell_tokens_with_spans`, `_iter_top_level_shell_segments`,
`_scan_dollar_paren_end`, `_literal_command_substitution_output`.

That is **a bash lexer**. The flow was: tokenize the command → walk its segments → resolve quoting and
`$(…)` substitution → match against danger patterns → prompt a human if it looked dangerous → run it
in-process. One function carried a cyclomatic complexity of 51, which is the real cost: every branch is an
opportunity to misclassify a string, and a determined caller only needs one.

## 2. What govd replaced — the authority, not the actor

cyberware inverts the question. It never inspects the command:

- **destructiveness is a property of the declared perk**, not of the text
- the wire carries a value-free claim — tool NAME, effect-class perk, a sha256 `ARGS_DIGEST`, a coarse
  `TARGET`. Never argument values
- the guarantee is meant to come from **confinement**, not from regexes

The scale of the swap: `approval.py`'s 51-complexity classifier versus cyberware's `oversight.scan` at
9 nodes / complexity 3 — a small, auditable denylist table. The chip states the principle plainly:
*"A determined bypass is stopped by confinement, not by the regexes."*

## 3. What did NOT change

**Hermes' own handler still executes the tool.** On `allow`, `_apply_govern_gate` returns `None`, the
executor proceeds, and the handler runs in-process via `subprocess`. `exod` is never reached.

**The native approval layer is still in the path.** `govern_gate._resolve_push_back` calls
`tools.approval.request_tool_approval`, so a govd `push_back` is rendered by the pre-cyberware machinery,
which owns the prompt, the `[o]nce/[s]ession/[a]lways/[d]eny` semantics, and the fail-closed timeout. This is
visible in the wording an operator actually sees:

    BLOCKED: User denied this potentially dangerous action (matched 'cyberware govd requires approval …')

That string is `tools/approval.py` — govd's reason placed into a `matched '…'` slot originally meant for a
regex hit. The two systems are **composed, not substituted**. The gate's docstring is accurate that it
replaces the approval *authority* while retaining the hardline floor as defence-in-depth; the consequence
worth writing down is that every user-facing surface is still the old one.

## 4. The full delegated chain — what a governed run looks like

```
agent   Claim ─ skill · perk · var KEYS (no values)
govd    Govern ─ authenticate principal · per-actor ACL · registry authenticity · TLC · budget
                 → blesses a value-free plan (sequence, snippet_shas, wrapper, plan_sha)
agent   Open the per-run WebSocket ─ hello{run_id, session_token} → step_request{step, plan_sha, var_values}
govd    Stage the workspace ─ mint a signed grant binding
                 run_id · plan_sha · snippet_shas · workspace · exact argv · cargo mode · acl_sha · nbf/exp/nonce
exod    Verify the grant ─ RE-RUN acl_allows off-node · re-verify the token proof · re-check the closure
exod    Run confined ─ --unshare-net · dropped privileges · workspace the SOLE rw mount (+cargo if granted)
exod    Ed25519-sign the authoritative result
govd    Verify the envelope · record step_result{authority: exod, exod_keyid, meter, values_sha}
                 · seal var_values into the encrypted tier-2 ledger
agent   ← executed{status, exit} ─ STATUS ONLY. A step's DATA returns via the cargo mount.
```

Two properties make this worth the length:

**Neither side trusts the other.** exod does not take govd's word for the ACL — it re-runs `acl_allows`
against the operator attestation and re-verifies possession of the caller's token. govd holds neither the
ACL-issuer key nor any actor's proof key, so a compromised govd can refuse work but cannot widen a token past
its attested ACL, nor misattribute a run to a more privileged one.

**The return path is asymmetric on purpose.** Status crosses the wire; output goes through the cargo mount;
inputs are sealed at rest. That is what makes `values_sha` and `authority=exod` mean anything — the node
*witnessed* the execution rather than being told about it.

## 5. Where Maria's calls actually stop

**After step 2.** Steps 3–9 never run for a `hermes:toolgate` claim. `agent/govern_gate.py` contains no
WebSocket client at all — it imports `urllib.request` and nothing else for transport, so it is structurally
incapable of reaching `/oversight`. Nothing in this repo invokes `toolgate/run`, the one perk backed by exod.

Consequences, each observable in the ledger today:

- **no grant** → none of exod's re-checks run
- **no confinement** → no `--unshare-net`, no dropped privileges, no workspace binding
- **no signed envelope** → nothing attests that the action occurred
- **no sealed values** → the tier-2 `run_values` table exists on the node and holds **0 rows**
- **`progress 0/N`, `authority ""`** on every entry — the plan's single step `hermes_claim` is provisioned
  and never executed

Measured directly: a `write_file` allowed through the gate produced 19 bytes on disk while its run recorded
`seq ['hermes_claim']`, `events []`, `workspace NONE`. The file exists; cyberware ran nothing.

**So a ledger entry proves that permission was granted — not that the action happened.** An `allow` for a
call that was never made is byte-identical to one that wrote a file. That is not a defect in the ledger; it
is the ledger accurately reporting that no governed step executed.

## 6. What closes the gap

1. A WebSocket client in the gate — vendor the ~59 stdlib lines from `cyberware/infra/govern/govd_client.py`
   (`_ws_connect/_ws_send/_ws_recv/_sock_read`), **delegated frames only**. Never import the module: it
   drags `infra.*` into the cage and carries `run_governed`, the cooperative path that executes snippets
   locally — precisely the capability Maria must not have.
2. Route `terminal` → `hermes:toolgate/run`, whose destructive floor and pinned case-table already exist and
   are blessed, and are simply never called.
3. A shared **cargo** work volume so a confined step operates on the same bytes Maria would have touched —
   which forces the work/self split: `auth.json`, `config.yaml` and `sessions/` must stay unreachable from
   any governed step.

`net` is the genuine exception: exod runs `--unshare-net`, so web/browser/MCP cannot execute confined without
a brokered-egress profile. Until one exists, that class stays advisory, and should be stated as such rather
than implied by the perk table.

## Related

- `agent/govern_gate.py` — the gate; `_AUTH_SCHEME_FROZEN` selects the identity scheme
- `scripts/test-maria-governed-conversation.sh` — deterministic, real dispatch against the live node
- `scripts/test-maria-conversation-live.sh` — LLM-driven, chain sampled per turn
- cyberware `docs/delegated-execution-ledger.md` — the exod-sealed record design
