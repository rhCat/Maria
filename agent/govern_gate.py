"""Mandatory cyberware governance gate for every tool call.

This module replaces Hermes' local, heuristic approval *authority* (the
Tier-2 dangerous-pattern classifier + per-thread callback in
``tools/approval.py``) with an external, verifiable one: the cyberware
governance server (**govd**). Every tool call is mapped to a value-free
**claim** against the ``hermes:toolgate`` governed skill and POSTed to
``govd``'s ``/govern`` endpoint; the signed ``allow`` / ``reject`` /
``push_back`` verdict decides whether the tool runs.

Design invariants:

* **Verdict-only.** govd decides; Hermes still executes its own handler when
  the verdict is ``allow``. exod never runs a Hermes tool. The claim carries
  only the tool NAME, an effect class (the perk), and a sha256 **digest** of
  the arguments — never argument values, never secrets.
* **Mandatory + unbypassable.** The gate call sits at the single narrow waist
  every tool passes through (``agent/tool_executor.py``), before both the
  inline-dispatched tools and the registry-dispatched ones. Its enablement is
  **frozen at import** (mirroring ``approval._YOLO_MODE_FROZEN``) so a tool
  result / injected skill cannot flip it mid-process.
* **Fail-closed.** If govd is unreachable, the skill is unverified/drifted, or
  anything raises, the verdict is **deny** — unless the operator has explicitly
  set ``fail_open`` (off by default).

The unconditional ``detect_hardline_command`` / sudo-stdin floor in
``tools/approval.py`` is retained beneath this gate as defense-in-depth; this
module governs the *approval* decision, not the hardline kill-switch.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Optional

logger = logging.getLogger(__name__)

# The governed skill that carries the gate policy. Its perks are effect-classed
# (not one-per-tool) so per-actor ACL stays legible; ``destructive`` perks
# trigger a govd ``push_back`` -> human approval.
GATE_SKILL = "hermes:toolgate"

# Effect classes == perks on GATE_SKILL. Non-destructive: ``read``. Destructive
# (push_back): ``write`` / ``exec`` / ``net`` / ``delegate``.
PERK_READ = "read"
PERK_WRITE = "write"
PERK_EXEC = "exec"
PERK_NET = "net"
PERK_DELEGATE = "delegate"
# H2: modifying the gate's OWN code/config is a distinct, always-destructive
# effect class. The chip's ``hermes:toolgate`` skill marks ``selfmod``
# destructive and does NOT expose it to ACL loosening, so a self-sabotage write
# can never be silently allowed — it always reaches a human (or is denied).
PERK_SELFMOD = "selfmod"

# Tool -> effect-class perk. Kept in sync with the risk taxonomy in
# ``agent/tool_guardrails.py`` (IDEMPOTENT_TOOL_NAMES / MUTATING_TOOL_NAMES).
# Anything not listed and not matched by a prefix rule below falls through to
# the conservative default (_default_perk) -- unknown tools are treated as
# effectful, never as free reads.
_EXPLICIT_TOOL_PERKS: dict[str, str] = {
    # reads
    "read_file": PERK_READ,
    "search_files": PERK_READ,
    "session_search": PERK_READ,
    "read_terminal": PERK_READ,
    "todo": PERK_READ,
    "clarify": PERK_READ,
    "browser_snapshot": PERK_READ,
    "browser_get_images": PERK_READ,
    # Tool Search bridge meta-tools: pure catalog reads / unwrap wrappers. The
    # real underlying tool is gated when the bridge unwraps to it (executor
    # unwraps pre-gate; handle_function_call recurses without skip).
    "tool_search": PERK_READ,
    "tool_describe": PERK_READ,
    "tool_call": PERK_READ,
    # writes (local mutation)
    "write_file": PERK_WRITE,
    "patch": PERK_WRITE,
    "memory": PERK_WRITE,
    "skill_manage": PERK_WRITE,
    "cronjob": PERK_WRITE,
    "process": PERK_WRITE,
    # exec (arbitrary code)
    "terminal": PERK_EXEC,
    "execute_code": PERK_EXEC,
    # net / egress
    "web_search": PERK_NET,
    "web_extract": PERK_NET,
    "send_message": PERK_NET,
    # delegation (spawns a governed-or-not subagent)
    "delegate_task": PERK_DELEGATE,
}

# Prefix rules for families of dynamically-named tools.
_PREFIX_PERKS: tuple[tuple[str, str], ...] = (
    ("browser_", PERK_NET),   # browser_click/type/navigate/console/... reach the network
    ("mcp_", PERK_NET),       # MCP servers are external processes / egress
)

# Unknown tools are effectful by default (fail-closed classification).
_DEFAULT_PERK = PERK_EXEC

_DESTRUCTIVE_PERKS = frozenset({PERK_WRITE, PERK_EXEC, PERK_NET, PERK_DELEGATE, PERK_SELFMOD})

# H2: files whose modification would disable/subvert the gate itself. Matched by
# basename (cheap, and robust to install-dir differences) plus the runtime
# governance config / token paths.
_PROTECTED_BASENAMES = frozenset({
    "govern_gate.py",     # the gate module
    "tool_executor.py",   # the mandatory chokepoint
    "approval.py",        # the retained hardline floor + short-circuit
    "model_tools.py",     # handle_function_call re-entry gate (H3)
})

# Mutating tools whose target could be a protected file.
_SELFMOD_CAPABLE_TOOLS = frozenset({"write_file", "patch", "terminal", "execute_code"})


def _protected_config_basenames() -> set[str]:
    names = {"governance.conf"}
    for var in ("HERMES_GOVERN_CONFIG", "HERMES_GOVERN_TOKEN_FILE"):
        p = os.environ.get(var)
        if p:
            names.add(os.path.basename(p))
    return names


def _targets_gate_self(function_name: str, args: dict) -> bool:
    """True if this call would modify the gate's own code or config (H2)."""
    if function_name not in _SELFMOD_CAPABLE_TOOLS:
        return False
    protected = _PROTECTED_BASENAMES | _protected_config_basenames()
    try:
        if function_name in ("write_file", "patch"):
            path = str(args.get("path") or args.get("file_path") or "")
            return os.path.basename(path) in protected
        # terminal / execute_code: substring scan of the payload for any
        # protected basename. Heuristic backstop — the real guarantee is the
        # read-only-code deployment (Threat B); this catches the obvious
        # `echo ... > govern_gate.py` / `sed -i ... approval.py` cases.
        payload = str(args.get("command") or args.get("code") or "")
        return any(name in payload for name in protected)
    except Exception:
        # Fail toward protection: if we can't tell, treat as self-targeting.
        return True


def _env_flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# --- Frozen switches (H1) ---------------------------------------------------
#
# The three security-relevant switches — ENABLED, FAIL_OPEN, URL — are read
# ONCE at import, from the process ENVIRONMENT ONLY, and never re-read. This is
# the H1 hardening: they must be injected by the (root-owned) systemd unit from
# ``/etc/maria/governance.conf``, NOT sourced from the agent-writable
# ``~/.hermes/config.yaml``. If the gate re-read config at call time, a single
# ``write_file`` to config.yaml would disable the gate that is supposed to
# govern that very write. There is deliberately NO config fallback for these.
#
# Non-security values (``token_file`` path, ``timeout``) MAY still come from
# config: the token file itself is root-owned ``chmod 600`` (its path is not a
# bypass surface), and timeout only affects latency/DoS-window, not authority.
_ENABLED_FROZEN = _env_flag("HERMES_GOVERN_ENABLED", False)
_FAIL_OPEN_FROZEN = _env_flag("HERMES_GOVERN_FAIL_OPEN", False)
_URL_FROZEN = (os.environ.get("HERMES_GOVERN_URL") or "").rstrip("/")


def _config() -> dict:
    """Non-security config only (token_file, timeout). NEVER consulted for
    enabled/fail_open/url — see H1 above."""
    try:
        from hermes_cli.config import load_config
        return load_config().get("governance", {}) or {}
    except Exception as e:  # pragma: no cover - config is best-effort
        logger.debug("govern_gate: no governance config (%s)", e)
        return {}


def is_enabled() -> bool:
    """Whether the mandatory gate is active. Frozen at import from env only."""
    return _ENABLED_FROZEN


def _fail_open() -> bool:
    """Fail-open posture. Frozen at import from env only; default fail-closed."""
    return _FAIL_OPEN_FROZEN


def _base_url() -> str:
    """govd endpoint. Frozen at import from env only (no config fallback, so a
    fake-govd URL can't be written into config)."""
    return _URL_FROZEN or "http://127.0.0.1:5773"


def _token() -> Optional[str]:
    """Bearer token from a ``chmod 600`` file pointer (never inlined). The path
    may come from config; the file is root-owned so the path is not a bypass."""
    path = os.environ.get("HERMES_GOVERN_TOKEN_FILE") or _config().get("token_file")
    if not path:
        return None
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError as e:
        logger.warning("govern_gate: cannot read token file %s (%s)", path, e)
        return None


def _timeout() -> float:
    try:
        return float(os.environ.get("HERMES_GOVERN_TIMEOUT") or _config().get("timeout") or 8.0)
    except (TypeError, ValueError):
        return 8.0


# --------------------------------------------------------------------------- #
# Classification
# --------------------------------------------------------------------------- #

def classify_tool(function_name: str, function_args: dict) -> tuple[str, str, str]:
    """Map a tool call to ``(perk, args_digest, target)``.

    ``args_digest`` is a sha256 over the canonical JSON of the args — a
    value-free fingerprint that lets govd/ledger correlate a decision to a
    specific call without ever seeing the values. ``target`` is a coarse,
    non-sensitive hint (a path root or host class) for ACL/audit, never a full
    value.
    """
    name = function_name or ""
    # H2 override: a call that would modify the gate's own code/config is always
    # the ``selfmod`` class, regardless of the tool's normal effect class.
    if _targets_gate_self(name, function_args or {}):
        perk = PERK_SELFMOD
    else:
        perk = _EXPLICIT_TOOL_PERKS.get(name)
        if perk is None:
            for prefix, p in _PREFIX_PERKS:
                if name.startswith(prefix):
                    perk = p
                    break
        if perk is None:
            perk = _DEFAULT_PERK

    try:
        canonical = json.dumps(function_args or {}, sort_keys=True, ensure_ascii=False, default=str)
    except Exception:
        canonical = repr(function_args)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    target = _coarse_target(name, function_args or {})
    return perk, digest, target


def _coarse_target(name: str, args: dict) -> str:
    """A non-sensitive class label for the target (audit hint, not a value)."""
    try:
        if name in ("web_extract", "web_search") or name.startswith(("browser_", "mcp_")):
            url = str(args.get("url") or args.get("query") or "")
            if "://" in url:
                host = url.split("://", 1)[1].split("/", 1)[0]
                return f"host:{host[:64]}"
            return "net"
        if name in ("read_file", "write_file", "patch"):
            path = str(args.get("path") or args.get("file_path") or "")
            # only the first path segment — a directory class, not the full path
            root = path.lstrip("/").split("/", 1)[0] if path else ""
            return f"path:{root[:48]}"
        if name in ("terminal", "execute_code"):
            return "shell"
    except Exception:
        pass
    return name[:48]


# --------------------------------------------------------------------------- #
# Verdict
# --------------------------------------------------------------------------- #

@dataclass
class GateVerdict:
    allowed: bool
    reason: str = ""
    problems: list = field(default_factory=list)
    run_id: str = ""
    plan_sha: str = ""
    perk: str = ""

    def block_message(self) -> str:
        base = self.reason or "Tool call blocked by cyberware governance."
        if self.problems:
            base += " problems=" + json.dumps(self.problems, ensure_ascii=False)
        return f"BLOCKED by govd ({GATE_SKILL}): {base} Do NOT retry, rephrase, or route around this."


# The catalog is cached process-wide; verification state rarely changes and a
# fetch per tool call would be wasteful. Refresh is lazy + lock-guarded.
_catalog_lock = threading.Lock()
_catalog_cache: Optional[dict] = None


def _http_json(method: str, path: str, body: Optional[dict], *, with_auth: bool) -> tuple[int, dict]:
    url = f"{_base_url()}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if with_auth:
        tok = _token()
        if tok:
            req.add_header("Authorization", f"Bearer {tok}")
    try:
        with urllib.request.urlopen(req, timeout=_timeout()) as resp:  # noqa: S310 (fixed scheme)
            payload = resp.read().decode("utf-8")
            try:
                return resp.status, json.loads(payload)
            except json.JSONDecodeError:
                return resp.status, {"raw": payload}
    except urllib.error.HTTPError as e:
        # govd returns VERDICTS on non-2xx: 403 = reject, 409 = push_back. Those
        # are decisions, not transport failures, and urlopen raises on both. Left
        # unhandled, every reject/push_back collapsed into a generic
        # ``govd HTTP <code>`` fail-closed deny -- which made the entire decision
        # dispatch in ``govern_tool_call`` unreachable, including the human
        # approval gate for destructive perks. Discriminate on the BODY, not the
        # status code: a verdict carries ``decision``; an auth/transport failure
        # (401, 5xx) does not, and must keep propagating to the fail-closed path.
        try:
            parsed = json.loads(e.read().decode("utf-8"))
        except Exception:
            raise
        if isinstance(parsed, dict) and "decision" in parsed:
            return e.code, parsed
        raise


def _skill_is_verified() -> tuple[bool, str]:
    """Confirm ``hermes:toolgate`` is present, verified, and drift-free."""
    global _catalog_cache
    with _catalog_lock:
        if _catalog_cache is None:
            try:
                _, cat = _http_json("GET", "/catalog", None, with_auth=False)
                _catalog_cache = cat
            except Exception as e:
                return False, f"catalog fetch failed: {e}"
        cat = _catalog_cache or {}
    for s in cat.get("skills", []):
        if s.get("skill") == GATE_SKILL:
            if not s.get("verified"):
                return False, f"{GATE_SKILL} not verified"
            if s.get("drift"):
                return False, f"{GATE_SKILL} drift={s.get('drift')}"
            return True, ""
    return False, f"{GATE_SKILL} absent from catalog"


def reset_catalog_cache() -> None:
    """Test/ops hook: force a catalog re-fetch on the next verdict."""
    global _catalog_cache
    with _catalog_lock:
        _catalog_cache = None


def _govern(perk: str, var_keys: list[str], approve: Optional[list[str]]) -> tuple[int, dict]:
    body: dict[str, Any] = {"skill": GATE_SKILL, "perk": perk, "var_keys": var_keys}
    if approve:
        body["approve"] = approve
    return _http_json("POST", "/govern", body, with_auth=True)


def govern_tool_call(
    function_name: str,
    function_args: dict,
    *,
    session_key: str = "",
    approval_callback=None,
) -> GateVerdict:
    """The mandatory gate. Return an allow/deny verdict for one tool call.

    Resolves a govd ``push_back`` synchronously through the existing human
    approval gate (``tools.approval.request_tool_approval`` — CLI prompt /
    gateway queue / non-interactive fail-closed), so the caller only ever sees
    ``allow`` (run) or ``deny`` (block).
    """
    if not is_enabled():
        return GateVerdict(allowed=True, reason="governance disabled")

    perk, digest, target = classify_tool(function_name, function_args)
    var_keys = ["TOOL", "ARGS_DIGEST", "TARGET"]

    # Registry authenticity is part of the gate: never trust a drifted/unverified
    # policy skill.
    ok, why = _skill_is_verified()
    if not ok:
        return _fail(why, perk)

    try:
        status, verdict = _govern(perk, var_keys, approve=None)
    except urllib.error.HTTPError as e:
        return _fail(f"govd HTTP {e.code}", perk)
    except Exception as e:
        return _fail(f"govd unreachable: {e}", perk)

    decision = str(verdict.get("decision", "")).lower()

    if decision == "allow":
        return GateVerdict(
            allowed=True,
            reason="allow",
            run_id=verdict.get("run_id", ""),
            plan_sha=verdict.get("plan_sha", ""),
            perk=perk,
        )

    if decision == "reject":
        return GateVerdict(
            allowed=False,
            reason="rejected by govd",
            problems=verdict.get("problems", []) or [],
            perk=perk,
        )

    if decision == "push_back":
        return _resolve_push_back(
            function_name, perk, digest, target, var_keys, verdict,
            approval_callback=approval_callback,
        )

    return _fail(f"unknown govd decision {decision!r}", perk)


def _resolve_push_back(
    function_name: str,
    perk: str,
    digest: str,
    target: str,
    var_keys: list[str],
    verdict: dict,
    *,
    approval_callback=None,
) -> GateVerdict:
    """A destructive perk needs human approval. Ask the existing gate; if the
    human approves, re-POST the claim with ``approve:[perk]`` and honor govd's
    second verdict."""
    reason = (
        f"cyberware govd requires approval to run '{function_name}' "
        f"(effect='{perk}', target='{target}', args_digest={digest[:12]})."
    )
    try:
        from tools.approval import request_tool_approval
        outcome = request_tool_approval(
            function_name,
            reason,
            rule_key=f"govd:{perk}:{function_name}",
            approval_callback=approval_callback,
        )
    except Exception as e:
        return _fail(f"approval gate error: {e}", perk)

    if not outcome.get("approved"):
        return GateVerdict(
            allowed=False,
            reason=outcome.get("message") or "human denied govd push_back",
            perk=perk,
        )

    # Human approved -> confirm the destructive perk with govd.
    try:
        status, confirmed = _govern(perk, var_keys, approve=[perk])
    except Exception as e:
        return _fail(f"govd unreachable on approve: {e}", perk)

    if str(confirmed.get("decision", "")).lower() == "allow":
        return GateVerdict(
            allowed=True,
            reason="approved",
            run_id=confirmed.get("run_id", ""),
            plan_sha=confirmed.get("plan_sha", ""),
            perk=perk,
        )
    return GateVerdict(
        allowed=False,
        reason="govd declined after approval",
        problems=confirmed.get("problems", []) or [],
        perk=perk,
    )


def _fail(reason: str, perk: str) -> GateVerdict:
    """Terminal error -> fail-closed unless the operator opted into fail-open."""
    if _fail_open():
        logger.warning("govern_gate: fail-open, allowing despite: %s", reason)
        return GateVerdict(allowed=True, reason=f"fail-open: {reason}", perk=perk)
    return GateVerdict(allowed=False, reason=reason, perk=perk)
