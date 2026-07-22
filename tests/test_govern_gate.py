"""Tests for the mandatory cyberware governance gate (agent/govern_gate.py).

These are hermetic: no network. The govd HTTP layer (``_http_json``) and the
catalog verification (``_skill_is_verified``) are monkeypatched so we exercise
the decision logic — allow / reject / push_back / fail-closed / fail-open —
without a live node.
"""

import importlib
import os

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
