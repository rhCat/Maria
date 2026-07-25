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

def test_disabled_allows_everything(monkeypatch):
    monkeypatch.setenv("HERMES_GOVERN_ENABLED", "0")
    importlib.reload(gg)
    v = gg.govern_tool_call("terminal", {"command": "rm -rf /"})
    assert v.allowed is True
    assert "disabled" in v.reason


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
