"""Edge-case suite for the Stalwart sidecar (inbound ingest + relay webhook)."""

from __future__ import annotations


import pytest
from litestar.testing import TestClient

from jmap_proxy import inbound, relay_webhook
from jmap_proxy.main import app


# ─────────────────────── envelope parsing edge cases ───────────────────────


@pytest.mark.parametrize(
    "hdr,expected",
    [
        ("a@x.com,b@x.com", ["a@x.com", "b@x.com"]),
        (" a@x.com , b@x.com ", ["a@x.com", "b@x.com"]),
        ("a@x.com,,b@x.com", ["a@x.com", "b@x.com"]),  # empty middle
        (",a@x.com,", ["a@x.com"]),  # leading/trailing commas
        ("", []),
        ("   ", []),
        ("only@one.com", ["only@one.com"]),
    ],
)
def test_parse_recipients(hdr, expected):
    assert inbound.parse_recipients(hdr) == expected


def test_envelope_from_message_multiple_to_and_cc():
    raw = b"From: s@a.com\r\nTo: t1@b.com, t2@b.com\r\nCc: c@b.com\r\n\r\nbody"
    sender, recipients = inbound.envelope_from_message(raw)
    assert sender == "s@a.com"
    assert set(recipients) == {"t1@b.com", "t2@b.com", "c@b.com"}


def test_envelope_from_message_no_headers():
    sender, recipients = inbound.envelope_from_message(b"just a body, no headers")
    assert sender is None
    assert recipients == []


def test_envelope_from_message_unparseable_bytes():
    # Arbitrary bytes should not raise.
    sender, recipients = inbound.envelope_from_message(b"\xff\xfe\x00garbage")
    assert recipients == [] or isinstance(recipients, list)


def test_resolve_envelope_header_wins_over_message():
    raw = b"From: msg@a.com\r\nTo: msg@b.com\r\n\r\nx"
    s, r = inbound.resolve_envelope(raw, "env@a.com", "env@b.com")
    assert s == "env@a.com" and r == ["env@b.com"]


def test_resolve_envelope_empty_headers_fall_back():
    raw = b"From: msg@a.com\r\nTo: msg@b.com\r\n\r\nx"
    s, r = inbound.resolve_envelope(raw, "", "")
    assert s == "msg@a.com" and r == ["msg@b.com"]


def test_resolve_envelope_whitespace_sender_falls_back():
    raw = b"From: msg@a.com\r\nTo: msg@b.com\r\n\r\nx"
    s, r = inbound.resolve_envelope(raw, "   ", "env@b.com")
    assert s == "msg@a.com"  # blank header sender -> parsed from message
    assert r == ["env@b.com"]


def test_resolve_envelope_no_sender_anywhere_empty_string():
    raw = b"Subject: no from\r\n\r\nbody"
    s, r = inbound.resolve_envelope(raw, None, "env@b.com")
    assert s == ""  # empty reverse-path (<>) is valid for delivered mail
    assert r == ["env@b.com"]


# ─────────────────────── inbound HTTP endpoint edge cases ───────────────────────


@pytest.fixture
def no_deliver(monkeypatch):
    calls = []
    monkeypatch.setattr(
        inbound, "deliver_to_stalwart", lambda *a, **k: calls.append((a, k))
    )
    return calls


def test_inbound_get_405(no_deliver):
    with TestClient(app=app) as c:
        assert c.get("/_email/inbound").status_code == 405


def test_inbound_put_405(no_deliver):
    with TestClient(app=app) as c:
        assert c.request("PUT", "/_email/inbound", content=b"x").status_code == 405


def test_inbound_no_recipients_400(no_deliver):
    with TestClient(app=app) as c:
        r = c.post("/_email/inbound", content=b"no headers here")
    assert r.status_code == 400
    assert not no_deliver


def test_inbound_trailing_slash_still_routes(no_deliver):
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/inbound/",
            content=b"From: a@x.com\r\nTo: me@z.com\r\n\r\nx",
            headers={"X-OpenHost-Mail-Recipients": "me@z.com"},
        )
    assert r.status_code == 200


def test_inbound_empty_body_but_recipients_header(no_deliver):
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/inbound",
            content=b"",
            headers={"X-OpenHost-Mail-Recipients": "me@z.com"},
        )
    # delivered with empty body (edge but valid: header supplies recipients)
    assert r.status_code == 200


def test_inbound_delivery_exception_502(monkeypatch):
    def boom(*a, **k):
        raise OSError("smtp down")

    monkeypatch.setattr(inbound, "deliver_to_stalwart", boom)
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/inbound",
            content=b"x",
            headers={"X-OpenHost-Mail-Recipients": "me@z.com"},
        )
    assert r.status_code == 502


def test_inbound_large_body(no_deliver):
    big = b"From: a@x.com\r\nTo: me@z.com\r\n\r\n" + b"A" * (2 * 1024 * 1024)
    with TestClient(app=app) as c:
        r = c.post(
            "/_email/inbound",
            content=big,
            headers={"X-OpenHost-Mail-Recipients": "me@z.com"},
        )
    assert r.status_code == 200
    # full body forwarded to delivery
    assert no_deliver[0][0][0] == big


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
