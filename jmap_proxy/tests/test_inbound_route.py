"""Tests for the /_email/inbound ASGI handler in the sidecar."""

from __future__ import annotations

from typing import Any

import pytest
from litestar.testing import TestClient

from jmap_proxy import inbound
from jmap_proxy.main import app


@pytest.fixture()
def delivered(monkeypatch: pytest.MonkeyPatch) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []

    def _fake_deliver(raw: bytes, sender: str, recipients: list[str], **kw: Any) -> None:
        calls.append({"raw": raw, "sender": sender, "recipients": recipients})

    monkeypatch.setattr(inbound, "deliver_to_stalwart", _fake_deliver)
    return calls


def test_inbound_delivers_with_envelope_headers(delivered: list[dict[str, Any]]) -> None:
    with TestClient(app=app) as client:
        resp = client.post(
            "/_email/inbound",
            content=b"From: a@ext.com\r\nTo: me@zone.example\r\n\r\nhi\r\n",
            headers={
                "Content-Type": "message/rfc822",
                "X-OpenHost-Mail-Sender": "a@ext.com",
                "X-OpenHost-Mail-Recipients": "me@zone.example",
            },
        )
    assert resp.status_code == 200
    assert resp.json() == {"delivered": True}
    assert delivered[0]["sender"] == "a@ext.com"
    assert delivered[0]["recipients"] == ["me@zone.example"]


def test_inbound_rejects_get(delivered: list[dict[str, Any]]) -> None:
    with TestClient(app=app) as client:
        resp = client.get("/_email/inbound")
    assert resp.status_code == 405
    assert not delivered


def test_inbound_400_when_no_recipients(delivered: list[dict[str, Any]]) -> None:
    # No headers and an unparseable/empty envelope -> 400.
    with TestClient(app=app) as client:
        resp = client.post("/_email/inbound", content=b"not a real message")
    assert resp.status_code == 400
    assert not delivered


def test_inbound_502_on_delivery_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    def _boom(*a: Any, **k: Any) -> None:
        raise OSError("connection refused")

    monkeypatch.setattr(inbound, "deliver_to_stalwart", _boom)
    with TestClient(app=app) as client:
        resp = client.post(
            "/_email/inbound",
            content=b"raw",
            headers={"X-OpenHost-Mail-Recipients": "me@zone.example"},
        )
    assert resp.status_code == 502
