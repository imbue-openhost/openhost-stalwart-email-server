#!/bin/sh
# Configure Stalwart's outbound smarthost from the OpenHost email relay-config.
#
# Fetches GET $OPENHOST_ROUTER_URL/api/email/relay-config with the app token
# (only the mailbox app is authorized to read it). When email is configured on
# the instance, applies an MtaRoute (@type Relay) pointing at the openhost-email-
# proxy submission smarthost (implicit TLS on 465) authenticated with the
# per-instance HMAC credential (user=zone, password=HMAC), then points the
# outbound strategy's default route at it (local mail still delivered locally).
#
# Idempotent: MtaRoute is created-or-updated by name; the strategy singleton is
# updated in place. No-op (exit 0) when the router is unreachable or email is not
# configured, so the mail server still boots.
#
# Requires: curl, python3 (for JSON parsing), stalwart-cli, and a running
# Stalwart admin API on $STALWART_URL.
set -eu

ROUTER_URL="${OPENHOST_ROUTER_URL:-}"
APP_TOKEN="${OPENHOST_APP_TOKEN:-}"
if [ -z "$ROUTER_URL" ] || [ -z "$APP_TOKEN" ]; then
    echo "relay-config: no router URL / app token; skipping outbound relay setup"
    exit 0
fi

RESP="$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer $APP_TOKEN" \
    "$ROUTER_URL/api/email/relay-config" 2>/dev/null || true)"
if [ -z "$RESP" ]; then
    echo "relay-config: router unreachable or returned nothing; skipping"
    exit 0
fi

# Parse with python3 (available in the image) and emit shell assignments.
EVAL="$(printf '%s' "$RESP" | python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    print("CONFIGURED=0"); sys.exit(0)
if not d.get("configured"):
    print("CONFIGURED=0"); sys.exit(0)
host = d.get("smtp_relay_host") or ""
port = d.get("smtp_relay_port") or 465
user = d.get("smtp_relay_user") or ""
pw = d.get("smtp_relay_password") or ""
if not host or not user or not pw:
    print("CONFIGURED=0"); sys.exit(0)
print("CONFIGURED=1")
print(f"RELAY_HOST={shlex.quote(host)}")
print(f"RELAY_PORT={int(port)}")
print(f"RELAY_USER={shlex.quote(user)}")
print(f"RELAY_PW={shlex.quote(pw)}")
')"
eval "$EVAL"

if [ "${CONFIGURED:-0}" != "1" ]; then
    echo "relay-config: email not configured on this instance; skipping outbound relay setup"
    exit 0
fi

# The openhost-email-proxy terminates TLS at the Fly edge (implicit TLS) on
# whatever port it publishes (465 and 587), then forwards the decrypted stream to
# its internal listener. So the smarthost always uses implicit TLS regardless of
# port. (587 is used because some providers — e.g. Hetzner — block outbound 465.)
IMPLICIT_TLS=true

echo "relay-config: configuring outbound smarthost $RELAY_USER@$RELAY_HOST:$RELAY_PORT (implicitTls=$IMPLICIT_TLS)"

# Create-or-update the relay route named "openhost-smarthost". Delete any prior
# instance first so re-provisioning (rotated credential, changed port) is
# idempotent. NOTE: `delete MtaRoute` takes the object ID, not the name — a
# stored route has an auto-generated id, so we resolve the id by name and delete
# that (a plain `delete ... openhost-smarthost` is a no-op and leaves the old
# route, causing a primaryKeyViolation on the subsequent create).
_route_id="$(stalwart-cli query MtaRoute --fields id,name --json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if isinstance(o, dict) and o.get("name") == "openhost-smarthost":
        print(o.get("id") or "")
        break
')"
if [ -n "$_route_id" ]; then
    stalwart-cli delete MtaRoute "$_route_id" >/dev/null 2>&1 || true
fi
stalwart-cli apply --file /dev/stdin <<PLAN
{"@type":"create","object":"MtaRoute","value":{"openhost-smarthost":{"@type":"Relay","name":"openhost-smarthost","description":"OpenHost email proxy smarthost","address":"$RELAY_HOST","port":$RELAY_PORT,"protocol":"smtp","implicitTls":$IMPLICIT_TLS,"allowInvalidCerts":false,"authUsername":"$RELAY_USER","authSecret":{"@type":"Value","secret":"$RELAY_PW"}}}}
PLAN

# Point the default outbound route at the smarthost; keep local mail local.
# MtaOutboundStrategy.route is an Expression whose ``match`` is a MAP of
# stringified indices (not an array), and is_local_domain takes a single arg.
# Getting either wrong yields "invalidPatch: Invalid value for object property".
stalwart-cli update MtaOutboundStrategy singleton \
    --field 'route={"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'"'"'local'"'"'"}},"else":"'"'"'openhost-smarthost'"'"'"}'

# Disable Stalwart's own outbound DKIM signing. Mail relayed through the SES
# smarthost is DKIM-signed by SES (Easy DKIM, using the domain identity whose
# CNAMEs the instance publishes). If Stalwart ALSO signs, the message carries two
# DKIM-Signature headers and SES rejects it with
# "BadRequestException: Duplicate header 'DKIM-Signature'". So we turn signing off
# in two places: the signing expression, and the auto-generated per-domain keys.
stalwart-cli update SenderAuth singleton \
    --field 'dkimSignDomain={"match":{},"else":"false"}' >/dev/null 2>&1 || true
# Delete any auto-created DKIM signature keys (the expression alone isn't enough
# on some builds). Idempotent: nothing to delete on a re-run.
_dkim_ids="$(stalwart-cli query DkimSignature --fields id --json 2>/dev/null | python3 -c '
import json, sys
ids = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if isinstance(o, dict) and o.get("id"):
        ids.append(o["id"])
print(",".join(ids))
')"
if [ -n "$_dkim_ids" ]; then
    stalwart-cli delete DkimSignature --ids "$_dkim_ids" >/dev/null 2>&1 || true
fi

echo "relay-config: outbound smarthost configured (SES signs DKIM; local signing disabled)"

# Register a Stalwart webhook that fires on outbound relay AUTH failure
# (delivery.auth-failed) so a rotated RELAY_SECRET is picked up immediately: the
# sidecar re-runs this script on receipt instead of waiting for the next boot.
# Idempotent — delete any prior hook first. Authenticated to the sidecar with a
# per-container bearer token (RELAY_WEBHOOK_TOKEN, generated at boot). Skipped if
# no token is set (e.g. reconfigure invoked from the webhook itself, to avoid a
# re-registration loop).
if [ -n "${RELAY_WEBHOOK_TOKEN:-}" ] && [ "${SKIP_WEBHOOK_REGISTER:-0}" != "1" ]; then
    WEBHOOK_URL="http://127.0.0.1:8082/_email/relay-webhook"
    # Delete a prior hook by id (delete takes the id, not the name), so re-runs
    # don't hit a primaryKeyViolation.
    _wh_id="$(stalwart-cli query WebHook --fields id,url --json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if isinstance(o, dict) and o.get("url", "").endswith("/_email/relay-webhook"):
        print(o.get("id") or "")
        break
')"
    if [ -n "$_wh_id" ]; then
        stalwart-cli delete WebHook --ids "$_wh_id" >/dev/null 2>&1 || true
    fi
    # ``events`` is a set<EventType>, which serializes as a MAP of value -> true
    # (not an array); an array yields "invalidPatch: ... Properties: events".
    stalwart-cli apply --file /dev/stdin <<HOOK
{"@type":"create","object":"WebHook","value":{"openhost-relay-auth":{"url":"$WEBHOOK_URL","events":{"delivery.auth-failed":true},"eventsPolicy":"include","level":"info","signatureKey":{"@type":"None"},"httpAuth":{"@type":"Bearer","bearerToken":{"@type":"Value","secret":"$RELAY_WEBHOOK_TOKEN"}},"httpHeaders":{},"throttle":"30s","enable":true}}}
HOOK
    echo "relay-config: registered delivery.auth-failed webhook -> sidecar"
fi
