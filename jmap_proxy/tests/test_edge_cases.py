"""Edge-case suite for the Stalwart sidecar relay-auth webhook."""

from __future__ import annotations


import pytest
from litestar.testing import TestClient

from jmap_proxy import relay_webhook
from jmap_proxy.main import app


# ─────────────────────── relay webhook edge cases ───────────────────────


@pytest.fixture
def hook_token(monkeypatch):
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "secret-tok")
    return "secret-tok"


@pytest.mark.parametrize(
    "header,ok",
    [
        ("Bearer secret-tok", True),
        ("bearer secret-tok", True),  # scheme case-insensitive
        ("Bearer  secret-tok ", True),  # extra spaces trimmed
        ("Bearer wrong", False),
        ("secret-tok", False),  # no scheme
        ("Basic secret-tok", False),  # wrong scheme
        ("", False),
        ("Bearer ", False),
    ],
)
def test_webhook_is_authorized(monkeypatch, header, ok):
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "secret-tok")
    assert relay_webhook.is_authorized(header) is ok


def test_webhook_no_token_configured_always_false(monkeypatch):
    monkeypatch.setattr(relay_webhook, "WEBHOOK_TOKEN", "")
    assert relay_webhook.is_authorized("Bearer anything") is False


@pytest.mark.parametrize(
    "payload,fires",
    [
        ({"events": [{"type": "delivery.auth-failed"}]}, True),
        ({"events": [{"type": "delivery.failed"}]}, False),
        (
            {"events": [{"type": "delivery.failed"}, {"type": "delivery.auth-failed"}]},
            True,
        ),
        ({"events": []}, False),
        ({}, False),
        ({"events": "notalist"}, False),
        ({"events": [{"no_type": "x"}]}, False),
        ({"events": ["junk", {"type": "delivery.auth-failed"}]}, True),
    ],
)
def test_webhook_event_filtering(monkeypatch, hook_token, payload, fires):
    triggered = []
    monkeypatch.setattr(
        relay_webhook, "trigger_reconfigure", lambda: triggered.append(True) or True
    )
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/relay-webhook",
            headers={"Authorization": f"Bearer {hook_token}"},
            json=payload,
        )
    assert r.status_code == 200
    assert bool(triggered) is fires


def test_webhook_bad_token_401_no_trigger(monkeypatch, hook_token):
    triggered = []
    monkeypatch.setattr(
        relay_webhook, "trigger_reconfigure", lambda: triggered.append(True) or True
    )
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/relay-webhook",
            headers={"Authorization": "Bearer nope"},
            json={"events": [{"type": "delivery.auth-failed"}]},
        )
    assert r.status_code == 401
    assert not triggered


def test_webhook_malformed_json_200_no_trigger(monkeypatch, hook_token):
    triggered = []
    monkeypatch.setattr(
        relay_webhook, "trigger_reconfigure", lambda: triggered.append(True) or True
    )
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/relay-webhook",
            headers={"Authorization": f"Bearer {hook_token}"},
            content=b"not json{",
        )
    assert r.status_code == 200  # ack so SNS/Stalwart doesn't retry-storm
    assert not triggered


def test_webhook_get_405(hook_token):
    with TestClient(app=app) as c:
        assert c.get("/_email/relay-webhook").status_code == 405


def test_event_types_non_dict_entries():
    assert relay_webhook.event_types({"events": [1, "x", {"type": "t"}, None]}) == ["t"]
