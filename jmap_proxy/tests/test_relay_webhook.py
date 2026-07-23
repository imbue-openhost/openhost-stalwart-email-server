"""Tests for the relay-auth-failed webhook handler + reconfigure trigger."""

from __future__ import annotations

from typing import Any

import pytest
from litestar.testing import TestClient

from jmap_proxy import relay_webhook
from jmap_proxy.main import app


def test_is_authorized(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "tok123")
    assert relay_webhook.is_authorized("Bearer tok123") is True
    assert relay_webhook.is_authorized("Bearer nope") is False
    assert relay_webhook.is_authorized("tok123") is False
    assert relay_webhook.is_authorized("") is False


def test_is_authorized_no_token_configured(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "")
    assert relay_webhook.is_authorized("Bearer anything") is False


def test_event_types_extraction() -> None:
    payload = {"events": [{"type": "delivery.auth-failed"}, {"type": "delivery.failed"}, "junk"]}
    assert relay_webhook.event_types(payload) == ["delivery.auth-failed", "delivery.failed"]
    assert relay_webhook.event_types({}) == []


def test_webhook_triggers_reconfigure_on_auth_failed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "tok")
    called: list[bool] = []
    monkeypatch.setattr(relay_webhook, "trigger_reconfigure", lambda: called.append(True) or True)
    with TestClient(app=app) as client:
        resp = client.post(
            "/_email/relay-webhook",
            headers={"Authorization": "Bearer tok"},
            json={"events": [{"id": "1", "type": "delivery.auth-failed", "data": {}}]},
        )
    assert resp.status_code == 200
    assert called == [True]


def test_webhook_ignores_other_events(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "tok")
    called: list[bool] = []
    monkeypatch.setattr(relay_webhook, "trigger_reconfigure", lambda: called.append(True) or True)
    with TestClient(app=app) as client:
        resp = client.post(
            "/_email/relay-webhook",
            headers={"Authorization": "Bearer tok"},
            json={"events": [{"id": "1", "type": "delivery.failed", "data": {}}]},
        )
    assert resp.status_code == 200
    assert called == []


def test_webhook_rejects_bad_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "tok")
    with TestClient(app=app) as client:
        resp = client.post(
            "/_email/relay-webhook",
            headers={"Authorization": "Bearer wrong"},
            json={"events": [{"type": "delivery.auth-failed"}]},
        )
    assert resp.status_code == 401


def test_webhook_rejects_get(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "tok")
    with TestClient(app=app) as client:
        resp = client.get("/_email/relay-webhook")
    assert resp.status_code == 405


def test_trigger_reconfigure_coalesces(monkeypatch: pytest.MonkeyPatch) -> None:
    # Simulate a long-running reconfigure so a second concurrent trigger is a no-op.
    import threading

    release = threading.Event()
    started = threading.Event()

    def fake_run(cmd: Any, **kw: Any) -> Any:
        started.set()
        release.wait(2)

        class _R:
            returncode = 0
            stderr = ""

        return _R()

    monkeypatch.setattr(relay_webhook.subprocess, "run", fake_run)
    assert relay_webhook.trigger_reconfigure() is True
    started.wait(2)
    # Second call while the first is still running -> coalesced (False).
    assert relay_webhook.trigger_reconfigure() is False
    release.set()
