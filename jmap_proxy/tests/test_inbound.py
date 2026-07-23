"""Tests for inbound mail ingest (envelope resolution + local SMTP delivery)."""

from __future__ import annotations

from typing import Any

import pytest

from jmap_proxy import inbound


def test_parse_recipients_splits_and_trims() -> None:
    assert inbound.parse_recipients("a@x.com, b@x.com ,, c@x.com") == [
        "a@x.com",
        "b@x.com",
        "c@x.com",
    ]
    assert inbound.parse_recipients("") == []


def test_resolve_envelope_prefers_headers() -> None:
    raw = b"From: msgfrom@x.com\r\nTo: msgto@x.com\r\n\r\nbody\r\n"
    sender, recipients = inbound.resolve_envelope(
        raw, "envfrom@x.com", "env1@y.com,env2@y.com"
    )
    assert sender == "envfrom@x.com"
    assert recipients == ["env1@y.com", "env2@y.com"]


def test_resolve_envelope_falls_back_to_message() -> None:
    raw = b"From: msgfrom@x.com\r\nTo: msgto@y.com, other@y.com\r\n\r\nbody\r\n"
    sender, recipients = inbound.resolve_envelope(raw, None, None)
    assert sender == "msgfrom@x.com"
    assert recipients == ["msgto@y.com", "other@y.com"]


def test_resolve_envelope_partial_header_uses_message_for_missing() -> None:
    raw = b"From: msgfrom@x.com\r\nTo: msgto@y.com\r\n\r\nbody\r\n"
    # recipients supplied, sender missing -> sender from message
    sender, recipients = inbound.resolve_envelope(raw, None, "env@y.com")
    assert sender == "msgfrom@x.com"
    assert recipients == ["env@y.com"]


def test_deliver_to_stalwart_uses_smtp(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: dict[str, Any] = {}

    class _FakeSMTP:
        def __init__(self, host: str, port: int, timeout: int = 30) -> None:
            calls["host"] = host
            calls["port"] = port

        def __enter__(self) -> "_FakeSMTP":
            return self

        def __exit__(self, *a: Any) -> None:
            return None

        def sendmail(self, sender: str, recipients: list[str], raw: bytes) -> None:
            calls["sender"] = sender
            calls["recipients"] = recipients
            calls["raw"] = raw

    monkeypatch.setattr(inbound.smtplib, "SMTP", _FakeSMTP)
    inbound.deliver_to_stalwart(
        b"raw msg", "a@x.com", ["b@y.com"], host="127.0.0.1", port=25
    )
    assert calls["host"] == "127.0.0.1"
    assert calls["port"] == 25
    assert calls["sender"] == "a@x.com"
    assert calls["recipients"] == ["b@y.com"]
    assert calls["raw"] == b"raw msg"
