"""Handle Stalwart's delivery.auth-failed webhook by re-syncing the relay config.

When the outbound smarthost rejects our SMTP AUTH (e.g. because RELAY_SECRET was
rotated centrally and the credential Stalwart holds is now stale), Stalwart emits
a ``delivery.auth-failed`` event. We subscribe to it (registered in
configure-relay.sh) so that instead of waiting for the next container boot, we
immediately re-fetch the current relay credential from the frontend and re-apply
the MtaRoute — closing the rotation window to one bounced message.

Auth: Stalwart is configured to send ``Authorization: Bearer <RELAY_WEBHOOK_TOKEN>``
(a per-container token also known only to this sidecar), so an untrusted caller
on the loopback interface can't trigger reconfigures. The reconfigure is
debounced so a burst of failures triggers at most one run at a time.
"""

from __future__ import annotations

import logging
import os
import subprocess
import threading

logger = logging.getLogger("jmap_proxy.relay_webhook")

WEBHOOK_TOKEN = os.environ.get("RELAY_WEBHOOK_TOKEN", "")
CONFIGURE_SCRIPT = os.environ.get("CONFIGURE_RELAY_SCRIPT", "/usr/local/bin/configure-relay.sh")

# Serialize + debounce reconfigures: at most one running, and coalesce concurrent
# triggers (a burst of auth failures should cause a single re-sync, not a storm).
_reconfigure_lock = threading.Lock()
_reconfigure_running = False


def is_authorized(authorization_header: str) -> bool:
    """Constant-time bearer check against the per-container webhook token."""
    import hmac

    if not WEBHOOK_TOKEN:
        return False
    scheme, _, value = (authorization_header or "").partition(" ")
    if scheme.lower() != "bearer" or not value:
        return False
    return hmac.compare_digest(value.strip(), WEBHOOK_TOKEN)


def event_types(payload: dict) -> list[str]:
    """Extract the event type keys from a Stalwart WebhookEvents payload."""
    events = payload.get("events")
    if not isinstance(events, list):
        return []
    return [e.get("type", "") for e in events if isinstance(e, dict)]


def trigger_reconfigure() -> bool:
    """Run configure-relay.sh once (coalescing concurrent calls).

    Returns True if a reconfigure was started, False if one was already running
    (in which case the in-flight run will pick up the current credential anyway).
    Runs with SKIP_WEBHOOK_REGISTER=1 so we don't re-register the webhook on every
    auth failure.
    """
    global _reconfigure_running
    with _reconfigure_lock:
        if _reconfigure_running:
            return False
        _reconfigure_running = True

    def _run() -> None:
        global _reconfigure_running
        try:
            env = dict(os.environ, SKIP_WEBHOOK_REGISTER="1")
            result = subprocess.run(
                ["/bin/sh", CONFIGURE_SCRIPT],
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            if result.returncode != 0:
                logger.warning("relay reconfigure exited %s: %s", result.returncode, result.stderr.strip())
            else:
                logger.info("relay reconfigure after auth-failed webhook completed")
        except Exception:
            logger.exception("relay reconfigure failed")
        finally:
            with _reconfigure_lock:
                _reconfigure_running = False

    threading.Thread(target=_run, daemon=True).start()
    return True
