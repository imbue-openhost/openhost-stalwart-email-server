"""Inbound mail ingest: receive a message from the OpenHost router and deliver it
into the local Stalwart mailbox over SMTP.

The email proxy (openhost-email-proxy) fetches inbound mail from SES/S3 and POSTs
the raw RFC822 to the instance's ``/_email/inbound`` (via the imbue-hosted-spaces
public door). The OpenHost router authenticates that hop (Authorization: Bearer =
the per-instance HMAC credential) and forwards the request to this app on its
loopback port. By the time it reaches us the request has already been
authenticated by the router and can only arrive over the loopback proxy, so we
simply deliver it.

Delivery uses plain SMTP to Stalwart's local listener (127.0.0.1:25). We use the
envelope sender/recipients the proxy passed in the X-OpenHost-Mail-* headers
(these come from the SES receipt, not from the message headers), falling back to
parsing the message if absent.
"""

from __future__ import annotations

import email
import email.utils
import os
import smtplib
from email.policy import default as default_policy

SMTP_HOST = os.environ.get("STALWART_SMTP_HOST", "127.0.0.1")
SMTP_PORT = int(os.environ.get("STALWART_SMTP_PORT", "25"))


def parse_recipients(raw_header: str) -> list[str]:
    return [r.strip() for r in raw_header.split(",") if r.strip()]


def envelope_from_message(raw: bytes) -> tuple[str | None, list[str]]:
    """Best-effort envelope sender/recipients from the message headers.

    Only used as a fallback when the proxy did not supply the SES envelope in the
    X-OpenHost-Mail-* headers.
    """
    try:
        msg = email.message_from_bytes(raw, policy=default_policy)
    except Exception:
        return None, []
    sender = None
    from_hdr = msg.get("From")
    if from_hdr is not None:
        addrs = email.utils.getaddresses([str(from_hdr)])
        if addrs and addrs[0][1]:
            sender = addrs[0][1]
    recipients: list[str] = []
    for field in ("To", "Cc"):
        val = msg.get(field)
        if val:
            recipients.extend(a[1] for a in email.utils.getaddresses([str(val)]) if a[1])
    return sender, recipients


def resolve_envelope(
    raw: bytes, sender_hdr: str | None, recipients_hdr: str | None
) -> tuple[str, list[str]]:
    """Pick the envelope to use: prefer the proxy-supplied SES envelope, else parse."""
    sender = (sender_hdr or "").strip()
    recipients = parse_recipients(recipients_hdr or "")
    if not sender or not recipients:
        parsed_sender, parsed_recipients = envelope_from_message(raw)
        if not sender and parsed_sender:
            sender = parsed_sender
        if not recipients:
            recipients = parsed_recipients
    return sender, recipients


def deliver_to_stalwart(
    raw: bytes, sender: str, recipients: list[str], *, host: str | None = None, port: int | None = None
) -> None:
    """Deliver a raw RFC822 message into Stalwart over local SMTP.

    Raises smtplib.SMTPException / OSError on failure so the caller can surface a
    5xx and let the proxy (and ultimately SNS) retry. A missing sender is sent as
    an empty reverse-path (``<>``), which is valid for delivered mail.
    """
    with smtplib.SMTP(host or SMTP_HOST, port or SMTP_PORT, timeout=30) as smtp:
        # Local, unauthenticated submission to Stalwart's SMTP listener; the
        # recipient zone is this instance's own, so Stalwart accepts it for local
        # delivery.
        smtp.sendmail(sender, recipients, raw)
