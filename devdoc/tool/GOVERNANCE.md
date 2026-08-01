# Maria's tool-gate — posture, verification, and what is still open

Status as of 2026-08-01. Companion to [`docker-compose.maria.yml`](docker-compose.maria.yml)
and [`README.md`](README.md).

Every tool call Maria makes is governed by an external authority (cyberware's
`govd`) rather than by local heuristics. This file records how that is enforced,
what has actually been *measured* rather than assumed, and which gaps remain.

---

## The single waist

`agent/govern_gate.py` maps each tool call to a value-free **claim** — tool name,
an effect class (the perk), and a sha256 digest of the arguments, never the
argument values — and POSTs it to `govd`. The signed `allow` / `reject` /
`push_back` verdict decides whether the handler runs.

The gate is invoked from exactly one place: `_apply_govern_gate`, inside
`_authorized_dispatch` in `agent/tool_executor.py`. Every dispatch site across
the concurrent and sequential executors funnels through it, on `final_args` —
*after* middleware rewrites — so the claim's digest covers what will actually
execute rather than what the model first proposed.

Both user-facing surfaces reach it, because both construct the same agent:

| surface | path |
|---|---|
| CLI | `cli.py` → `run_agent.AIAgent` |
| TUI | `ui-tui` → `tui_gateway/methods_prompt.py` → `run_agent.AIAgent` |

Six further surfaces inherit the same waist: `batch_runner`, `acp_adapter`,
`delegate_tool`, `background_review`, `curator`, and the Feishu plugin.
`tui_gateway/methods_tools.py` does **not** dispatch model tool calls — it
handles TUI RPC only (battery, process registry, MCP lifecycle) — so there is no
second dispatch path.

Subagents are in-process (`delegate_tool.py` constructs `AIAgent` directly; no
`Popen` anywhere in it), so a child shares the parent's already-frozen state and
cannot weaken it.

## The hardening layers

| | property | mechanism |
|---|---|---|
| **H1** | config cannot disable the gate | ENABLED / FAIL_OPEN / URL read **once at import, from the environment only**. No config fallback — otherwise one `write_file` to the agent-writable `config.yaml` would disable the gate governing that very write. |
| **H2** | the gate cannot be edited by the agent | writes naming `govern_gate.py`, `tool_executor.py`, `approval.py`, `model_tools.py`, `governance.conf`, the token file, or the marker are reclassified to the self-modification perk. Backed by a read-only code tree: `COPY --chmod=a+rX,go-w`, root-owned, agent runs as uid 10000. |
| **H3** | re-entry is gated | `model_tools.handle_function_call` is inside the protected set. |
| **H4** | **the environment is not the authority** | a root-owned marker at `/etc/maria/governed`, consulted at import, **wins over the environment**. |

### Why H4 exists

H1 moved authority off the agent-writable config and onto the environment. That
is necessary but not sufficient, because **the environment is not an enforcement
boundary — every process controls its own**. A tool call that earned a single
`allow` verdict could start a fresh interpreter in a weaker posture, and the
child came up ungoverned: the gate governed the first command and nothing after
it. Omitting the variable was as effective as clearing it, since the env default
is off.

The marker moves authority somewhere the agent cannot write:

- root-owned, mode `0644`, inside a root-owned `0755` directory, so uid 10000 can
  neither rewrite nor unlink it, nor shadow it with a directory of its own
- the path is a **hardcoded constant, not env-derived** — otherwise the same child
  could simply redirect it
- when present it forces governed + fail-closed regardless of what any descendant
  sets
- forging it is harmless by construction: creating a marker can only turn
  governance **on**

Absent the marker, behaviour is unchanged — the environment decides and defaults
off — so developer checkouts, CI, and plain CLI runs are unaffected. The marker
is what an **image** ships to say "this deployment is governed, and that is not
negotiable".

## Verification

Measured against a built image, run as the agent's own uid inside the container,
then re-run against the live cage after deploy. Nine cases:

| | attempt | result |
|---|---|---|
| B1 | overwrite the gate's own source | contained — read-only tree |
| B2 | disable via agent-writable `config.yaml` | contained — H1, no config fallback |
| B3 | fresh process with the switch cleared | contained — H4 *(escaped before H4)* |
| B4 | fresh process with the switch omitted | contained — H4 *(escaped before H4)* |
| B5 | force fail-open | contained — marker forces fail-closed |
| B6 | in-process reload after mutating the environment | contained — H4 |
| B7 | unlink or rewrite the marker | contained — permission denied |
| B8 | shadow the marker via a writable `/etc/maria` | contained — root-owned |
| B9 | launch the real entrypoint in a weaker posture | gate still reports enabled |

Live cage after deploy: boot logs `[assert-governed] gate ON, fail-closed`, the
marker is present root-owned, and a child process with the switch cleared still
reports the gate **enabled**.

## Known gaps — read before trusting this

**The boot assertion is detection, not enforcement.**
`cont-init.d/005-assert-governed` reports the posture at boot, but s6-overlay's
`S6_BEHAVIOUR_IF_STAGE2_FAILS` defaults to `0` ("continue silently"), so a
non-zero exit is logged and the boot proceeds. Setting it to `2` makes it
enforcing, at the cost of making *every* cont-init failure fatal. Not taken yet.

**Outside the container is ungoverned.** A CLI run on the host has no marker and
gets the environment default, which is off. Nothing here changes that; the
container boundary is the governance boundary.

**Upstream's `!command` shell mode bypasses the gate.** `hermes_cli/bang_shell.py`
(not yet merged) executes without entering `tool_executor.py`, so it produces no
claim and no ledger entry, relying on the legacy heuristic guards instead. It is
human-initiated and upstream gates it off for gateway/cron/platform sessions —
but that gating depends on `HERMES_GATEWAY_SESSION`, `HERMES_CRON_SESSION`, or
`HERMES_SESSION_PLATFORM` being set, and **none of them are set in the running
container's environment**. Verify before merging upstream.

**The gate governs permission, not execution.** `govd` renders a verdict; Hermes
still runs its own handler on `allow`. A verdict is not a sandbox.

## Operating notes

Traps that cost real time, recorded so they cost it once:

- **govd is bound to the tailnet address, not loopback.** The compose publishes
  `${GOVD_BIND}:5774:5773`, so `127.0.0.1:5774` gets connection refused. Probe the
  bind address. It looks exactly like "govd is down".
- **Two different tokens, easily confused.** The *agent principal* credential
  (`MARIA_GOVD_TOKEN`) lets the agent make claims. The *monitor* token reads the
  ledger. Never reuse one for the other. In `fleet.json` this node is registered
  as `maria-dev-mac` (port 5774) — the entry named `maria` is a different host.
- **A failed credential lookup is a silent no-op deploy.** If a `cat` in the
  launch line fails, the variable comes out empty, compose refuses the whole file
  with *"required variable … is missing a value"*, and the running containers are
  left untouched and healthy. It looks like a successful deploy. Verify the
  container's `Created` timestamp actually moved.
- **The image needs rebuilding for gate changes to take effect.** A fix in git is
  not a fix in the thing that is running.
