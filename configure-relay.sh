#!/bin/sh
# Configure Stalwart's outbound smarthost to relay through the OpenHost router's
# email service (SMTP submission).
#
# Under OpenHost's email service model the app never holds the Imbue relay
# password. Instead the router runs a local SMTP submission listener; this app
# relays there authenticated with its own app token, and the router attaches the
# per-instance relay credential and forwards to the Imbue smarthost. So all we
# configure here is an MtaRoute pointing at OPENHOST_SMTP_HOST:OPENHOST_SMTP_PORT,
# authenticated with username=OPENHOST_APP_NAME / secret=OPENHOST_APP_TOKEN.
#
# The router listener is loopback/gateway-only (not public) and speaks plaintext
# SMTP AUTH on the host, so implicitTls is false.
#
# Idempotent: MtaRoute is created-or-updated by name; the strategy singleton is
# updated in place. No-op (exit 0) when the email service isn't wired (no SMTP
# host/app token), so the mail server still boots.
#
# Requires: stalwart-cli and a running Stalwart admin API on $STALWART_URL.
set -eu

SMTP_HOST="${OPENHOST_SMTP_HOST:-}"
SMTP_PORT="${OPENHOST_SMTP_PORT:-2525}"
APP_NAME="${OPENHOST_APP_NAME:-}"
APP_TOKEN="${OPENHOST_APP_TOKEN:-}"
if [ -z "$SMTP_HOST" ] || [ -z "$APP_NAME" ] || [ -z "$APP_TOKEN" ]; then
    echo "relay-config: no router SMTP host / app identity; skipping outbound relay setup"
    exit 0
fi

echo "relay-config: configuring outbound smarthost via router $APP_NAME@$SMTP_HOST:$SMTP_PORT"

# Create-or-update the relay route named "openhost-smarthost". Delete any prior
# instance first so re-provisioning (changed host/port) is idempotent. NOTE:
# `delete MtaRoute` takes the object ID, not the name — a stored route has an
# auto-generated id, so we resolve the id by name and delete that (a plain
# `delete ... openhost-smarthost` is a no-op and leaves the old route, causing a
# primaryKeyViolation on the subsequent create).
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
{"@type":"create","object":"MtaRoute","value":{"openhost-smarthost":{"@type":"Relay","name":"openhost-smarthost","description":"OpenHost router email service","address":"$SMTP_HOST","port":$SMTP_PORT,"protocol":"smtp","implicitTls":false,"allowInvalidCerts":true,"authUsername":"$APP_NAME","authSecret":{"@type":"Value","secret":"$APP_TOKEN"}}}}
PLAN

# Point the default outbound route at the smarthost; keep local mail local.
# MtaOutboundStrategy.route is an Expression whose ``match`` is a MAP of
# stringified indices (not an array), and is_local_domain takes a single arg.
# Getting either wrong yields "invalidPatch: Invalid value for object property".
stalwart-cli update MtaOutboundStrategy singleton \
    --field 'route={"match":{"0":{"if":"is_local_domain(rcpt_domain)","then":"'"'"'local'"'"'"}},"else":"'"'"'openhost-smarthost'"'"'"}'

# Disable Stalwart's own outbound DKIM signing. Mail relayed onward is DKIM-signed
# by SES (Easy DKIM, using the domain identity whose CNAMEs the instance
# publishes). If Stalwart ALSO signs, the message carries two DKIM-Signature
# headers and SES rejects it with "Duplicate header 'DKIM-Signature'". So we turn
# signing off in two places: the signing expression, and the auto-generated
# per-domain keys.
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

echo "relay-config: outbound smarthost configured via router (SES signs DKIM; local signing disabled)"
