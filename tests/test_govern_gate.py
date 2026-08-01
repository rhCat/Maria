"""Tests for the mandatory cyberware governance gate (agent/govern_gate.py).

These are hermetic: no network. The govd HTTP layer (``_http_json``) and the
catalog verification (``_skill_is_verified``) are monkeypatched so we exercise
the decision logic — allow / reject / push_back / fail-closed / fail-open —
without a live node.
"""

import importlib
import io
import json
import os
import urllib.error

import pytest

import agent.govern_gate as gg


@pytest.fixture(autouse=True)
def _reset(monkeypatch):
    # Enable the gate for the test and point it at a dummy skill-verified node.
    monkeypatch.setenv("HERMES_GOVERN_ENABLED", "1")
    monkeypatch.delenv("HERMES_GOVERN_FAIL_OPEN", raising=False)
    # Re-import so the frozen ``_ENABLED_ENV`` / ``_FAIL_OPEN_FROZEN`` module
    # constants pick up this test's environment.
    importlib.reload(gg)
    gg.reset_catalog_cache()
    yield


# --------------------------------------------------------------------------- #
# Classification
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("tool,expected", [
    ("read_file", gg.PERK_READ),
    ("search_files", gg.PERK_READ),
    ("todo", gg.PERK_READ),
    ("write_file", gg.PERK_WRITE),
    ("memory", gg.PERK_WRITE),
    ("terminal", gg.PERK_EXEC),
    ("execute_code", gg.PERK_EXEC),
    ("web_extract", gg.PERK_NET),
    ("browser_click", gg.PERK_NET),      # prefix rule
    ("mcp_github_create_issue", gg.PERK_NET),  # prefix rule
    ("delegate_task", gg.PERK_DELEGATE),
    ("some_unknown_tool", gg.PERK_EXEC),  # fail-closed default
])
def test_classify_perk(tool, expected):
    perk, digest, target = gg.classify_tool(tool, {"x": 1})
    assert perk == expected
    assert len(digest) == 64  # sha256 hex


def test_args_digest_is_value_free_and_stable():
    _, d1, _ = gg.classify_tool("write_file", {"path": "/a", "content": "secret"})
    _, d2, _ = gg.classify_tool("write_file", {"content": "secret", "path": "/a"})
    assert d1 == d2  # canonical (order-independent)
    _, d3, _ = gg.classify_tool("write_file", {"path": "/a", "content": "different"})
    assert d1 != d3


def test_coarse_target_never_leaks_full_path():
    _, _, target = gg.classify_tool("read_file", {"path": "/home/user/.ssh/id_rsa"})
    assert target == "path:home"
    assert "id_rsa" not in target


# --------------------------------------------------------------------------- #
# Enable / disable
# --------------------------------------------------------------------------- #

@pytest.mark.skipif(
    gg._marker_present(),
    reason="H4: the root-owned governed marker is present, so the gate cannot be "
           "switched off by environment here — that is the point of the marker. "
           "This assertion only describes an unmarked host (dev checkout, CI).",
)
def test_disabled_allows_everything(monkeypatch):
    monkeypatch.setenv("HERMES_GOVERN_ENABLED", "0")
    importlib.reload(gg)
    v = gg.govern_tool_call("terminal", {"command": "rm -rf /"})
    assert v.allowed is True
    assert "disabled" in v.reason


def test_marker_predicate_rejects_a_forgeable_marker(tmp_path, monkeypatch):
    """H4: only a root-owned, non-group/other-writable marker counts.

    A marker the agent could create or rewrite would not be an authority it is
    unable to forge, so a file owned by the calling user must not qualify. The
    predicate reads the path at call time, so pointing it elsewhere is enough
    to exercise it without touching the real /etc.

    That the marker actually WINS over the environment is proved end-to-end in
    the container (a child process with the switch cleared still reports the
    gate enabled); it cannot be asserted here, because the constants derive at
    import and importlib.reload re-runs the real predicate.
    """
    forgeable = tmp_path / "governed"
    forgeable.write_text("x")
    monkeypatch.setattr(gg, "_GOVERNED_MARKER", str(forgeable))
    assert gg._marker_present() is False, "a user-owned marker must not count"

    monkeypatch.setattr(gg, "_GOVERNED_MARKER", str(tmp_path / "absent"))
    assert gg._marker_present() is False, "a missing marker must not count"


# --------------------------------------------------------------------------- #
# Verdict mapping (skill verified)
# --------------------------------------------------------------------------- #

def _verified(monkeypatch):
    monkeypatch.setattr(gg, "_skill_is_verified", lambda: (True, ""))


def test_allow(monkeypatch):
    _verified(monkeypatch)
    monkeypatch.setattr(gg, "_govern",
                        lambda perk, keys, approve: (200, {"decision": "allow", "run_id": "r1", "plan_sha": "p1"}))
    v = gg.govern_tool_call("read_file", {"path": "x"})
    assert v.allowed is True
    assert v.run_id == "r1" and v.plan_sha == "p1"


def test_reject_blocks_with_problems(monkeypatch):
    _verified(monkeypatch)
    monkeypatch.setattr(gg, "_govern",
                        lambda perk, keys, approve: (200, {"decision": "reject",
                                                           "problems": [{"code": "skill_remote_closed"}]}))
    v = gg.govern_tool_call("terminal", {"command": "ls"})
    assert v.allowed is False
    assert "skill_remote_closed" in v.block_message()


def test_push_back_approved_then_confirmed(monkeypatch):
    _verified(monkeypatch)
    calls = {"n": 0}

    def fake_govern(perk, keys, approve):
        calls["n"] += 1
        if approve:
            return 200, {"decision": "allow", "run_id": "r2", "plan_sha": "p2"}
        return 200, {"decision": "push_back"}

    monkeypatch.setattr(gg, "_govern", fake_govern)
    # Human approves.
    import tools.approval as approval
    monkeypatch.setattr(approval, "request_tool_approval",
                        lambda *a, **k: {"approved": True, "message": None})
    v = gg.govern_tool_call("write_file", {"path": "x"})
    assert v.allowed is True
    assert v.run_id == "r2"
    assert calls["n"] == 2  # initial + confirm


def test_push_back_denied_by_human(monkeypatch):
    _verified(monkeypatch)
    monkeypatch.setattr(gg, "_govern",
                        lambda perk, keys, approve: (200, {"decision": "push_back"}))
    import tools.approval as approval
    monkeypatch.setattr(approval, "request_tool_approval",
                        lambda *a, **k: {"approved": False, "message": "user denied"})
    v = gg.govern_tool_call("write_file", {"path": "x"})
    assert v.allowed is False
    assert "denied" in v.reason


# --------------------------------------------------------------------------- #
# Transport: govd signals verdicts with non-2xx
# --------------------------------------------------------------------------- #
#
# REGRESSION. The tests above monkeypatch ``_govern``, so they exercise decision
# dispatch over a transport that always returns 200. The live node does not: it
# answers 403 for ``reject`` and 409 for ``push_back``, and ``urlopen`` raises on
# both. That turned every destructive claim into a generic ``govd HTTP <code>``
# fail-closed deny and left ``_resolve_push_back`` unreachable -- covered by the
# 200-mocks above, dead in production. These tests drive the real ``urlopen``
# boundary so the mock can never diverge from the node again.

def _raise_http(code: str, payload: dict):
    """Patch urlopen to raise a real HTTPError carrying ``payload`` as its body."""
    def _fake(req, timeout=None):
        raise urllib.error.HTTPError(
            "http://node/govern", code, "verdict", {},
            io.BytesIO(json.dumps(payload).encode("utf-8")),
        )
    return _fake


@pytest.mark.parametrize("code,decision", [(403, "reject"), (409, "push_back")])
def test_http_json_returns_verdict_on_non_2xx(monkeypatch, code, decision):
    monkeypatch.setattr(gg.urllib.request, "urlopen",
                        _raise_http(code, {"decision": decision, "problems": []}))
    status, body = gg._http_json("POST", "/govern", {"skill": "s"}, with_auth=False)
    assert status == code
    assert body["decision"] == decision


def test_http_json_propagates_auth_failure(monkeypatch):
    # 401 carries no ``decision`` -- a transport/auth failure, NOT a verdict. It
    # must keep raising so the caller stays on the fail-closed path.
    monkeypatch.setattr(gg.urllib.request, "urlopen",
                        _raise_http(401, {"error": "missing/invalid Authorization: Bearer token"}))
    with pytest.raises(urllib.error.HTTPError):
        gg._http_json("POST", "/govern", {"skill": "s"}, with_auth=False)


def test_real_409_reaches_the_human_approval_gate(monkeypatch):
    """End-to-end: a genuine 409 must resolve as push_back, not a blanket deny."""
    _verified(monkeypatch)
    seen = {"asked": False}

    def _urlopen(req, timeout=None):
        # First claim -> 409 push_back. The approve-confirm re-POST -> 200 allow.
        if seen["asked"]:
            body = json.dumps({"decision": "allow", "run_id": "r9", "plan_sha": "p9"}).encode()
            resp = io.BytesIO(body)
            resp.status = 200
            resp.__enter__ = lambda s=resp: s
            resp.__exit__ = lambda s, *a: False
            return resp
        raise urllib.error.HTTPError(
            "http://node/govern", 409, "push_back", {},
            io.BytesIO(json.dumps({"decision": "push_back", "needs_approve": ["exec"]}).encode()),
        )

    monkeypatch.setattr(gg.urllib.request, "urlopen", _urlopen)

    import tools.approval as approval

    def _approve(*a, **k):
        seen["asked"] = True
        return {"approved": True, "message": None}

    monkeypatch.setattr(approval, "request_tool_approval", _approve)

    v = gg.govern_tool_call("terminal", {"command": "echo hi"})
    assert seen["asked"] is True, "409 never reached the human approval gate"
    assert v.allowed is True
    assert v.run_id == "r9"


def test_real_403_surfaces_problems_not_a_bare_status(monkeypatch):
    _verified(monkeypatch)
    monkeypatch.setattr(gg.urllib.request, "urlopen",
                        _raise_http(403, {"decision": "reject",
                                          "problems": [{"code": "plaintext_secret_key"}]}))
    v = gg.govern_tool_call("write_file", {"path": "x"})
    assert v.allowed is False
    assert "plaintext_secret_key" in v.block_message()
    assert "HTTP 403" not in v.reason


# --------------------------------------------------------------------------- #
# Fail-closed / fail-open
# --------------------------------------------------------------------------- #

def test_fail_closed_when_skill_unverified(monkeypatch):
    monkeypatch.setattr(gg, "_skill_is_verified", lambda: (False, "hermes:toolgate absent from catalog"))
    v = gg.govern_tool_call("read_file", {"path": "x"})
    assert v.allowed is False
    assert "absent" in v.reason


def test_fail_closed_when_govd_unreachable(monkeypatch):
    _verified(monkeypatch)

    def boom(*a, **k):
        raise OSError("connection refused")

    monkeypatch.setattr(gg, "_govern", boom)
    v = gg.govern_tool_call("read_file", {"path": "x"})
    assert v.allowed is False


def test_fail_open_override(monkeypatch):
    monkeypatch.setenv("HERMES_GOVERN_FAIL_OPEN", "1")
    importlib.reload(gg)
    monkeypatch.setattr(gg, "_skill_is_verified", lambda: (False, "node down"))
    v = gg.govern_tool_call("read_file", {"path": "x"})
    assert v.allowed is True
    assert "fail-open" in v.reason


def test_unknown_decision_fails_closed(monkeypatch):
    _verified(monkeypatch)
    monkeypatch.setattr(gg, "_govern",
                        lambda perk, keys, approve: (200, {"decision": "maybe"}))
    v = gg.govern_tool_call("read_file", {"path": "x"})
    assert v.allowed is False


# ───────────────────────── ed25519 assertions (the issuer-free scheme) ─────────────────────────
# The verifier lives in cyberware; this side only MINTS. These pin the wire format and the fail-closed
# paths. Cross-repo byte-compatibility is verified by minting here and verifying with
# infra/govern/ed25519_auth.py — done manually at build time; these keep the local half honest.

def _mk_key(tmp_path, raw: bytes, name="k.key", hexform=False):
    p = tmp_path / name
    p.write_text(raw.hex() + "\n") if hexform else p.write_bytes(raw)
    return str(p)


def _reload_with(monkeypatch, **env):
    for k, v in env.items():
        monkeypatch.setenv(k, v) if v is not None else monkeypatch.delenv(k, raising=False)
    importlib.reload(gg)
    return gg


def test_default_scheme_is_the_static_token(monkeypatch, tmp_path):
    tok = tmp_path / "t"
    tok.write_text("static-secret")
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME=None,
                     HERMES_GOVERN_TOKEN_FILE=str(tok))
    assert g._AUTH_SCHEME_FROZEN == "token"
    assert g._bearer() == "static-secret"


def test_ed25519_scheme_mints_a_fresh_assertion(monkeypatch, tmp_path):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    raw = Ed25519PrivateKey.generate().private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME="ed25519",
                     HERMES_GOVERN_KEY_FILE=_mk_key(tmp_path, raw))
    a, b = g._bearer(), g._bearer()
    assert a and b
    assert a != b, "each claim must carry a FRESH assertion — a cached one is replayable"


def test_raw_key_with_whitespace_edges_is_accepted(monkeypatch, tmp_path):
    """REGRESSION. `fh.read().strip()` strips whitespace BYTES from a binary key: ~5% of random 32-byte
    keys begin or end with 0x09/0x0a/0x0b/0x0c/0x0d/0x20 and were silently truncated to 31 bytes and
    rejected — intermittently, and only for some keys. Caught by the first cross-repo mint."""
    raw = bytes([0x20]) + bytes(range(1, 31)) + bytes([0x0a])
    assert len(raw) == 32
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME="ed25519",
                     HERMES_GOVERN_KEY_FILE=_mk_key(tmp_path, raw, "ws.key"))
    assert g._bearer() is not None


def test_hex_key_form_is_accepted(monkeypatch, tmp_path):
    raw = bytes(range(32))
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME="ed25519",
                     HERMES_GOVERN_KEY_FILE=_mk_key(tmp_path, raw, "h.key", hexform=True))
    assert g._bearer() is not None


@pytest.mark.parametrize("bad", [b"", b"short", bytes(31), bytes(33)])
def test_malformed_key_mints_nothing(monkeypatch, tmp_path, bad):
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME="ed25519",
                     HERMES_GOVERN_KEY_FILE=_mk_key(tmp_path, bad, "bad.key"))
    assert g._bearer() is None, "a bad key must mint NOTHING — never a header, never an unauthenticated pass"


def test_missing_key_file_mints_nothing(monkeypatch, tmp_path):
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME="ed25519",
                     HERMES_GOVERN_KEY_FILE=str(tmp_path / "nope.key"))
    assert g._bearer() is None


def test_ed25519_scheme_without_a_key_file_mints_nothing(monkeypatch):
    g = _reload_with(monkeypatch, HERMES_GOVERN_AUTH_SCHEME="ed25519", HERMES_GOVERN_KEY_FILE=None)
    assert g._bearer() is None
