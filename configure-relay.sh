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
# When the relay-config reports a delegated custom mail domain, also registers
# that domain as a local Stalwart domain and adds an owner alias on it, so
# inbound mail for the custom domain is accepted and delivered to the owner's
# mailbox (without this, Stalwart only knows its built-in <zone> domain and would
# reject inbound for the custom domain).
#
# Idempotent: MtaRoute is created-or-updated by name; the strategy singleton is
# updated in place; the custom domain + owner alias are only added when absent.
# No-op (exit 0) when the router is unreachable or email is not configured, so
# the mail server still boots.
#
# Requires: curl, python3 (for JSON parsing), stalwart-cli, and a running
# Stalwart admin API on $STALWART_URL.
set -eu

# Register a delegated custom mail domain as a local Stalwart domain and add an
# alias for it to the owner account, so inbound mail addressed to the custom
# domain is accepted and delivered to the owner's existing mailbox.
#
# Stalwart's model (v0.16): a User principal has one server-derived primary
# address (name@primary-domain) plus an `aliases[]` list of {name, domainId}
# objects. To receive <user>@<custom_domain> we (1) create the Domain, then
# (2) append an alias {name:<user>, domainId:<custom-domain-id>} to the owner
# account. Both steps are idempotent: the Domain create is create-or-ignore, and
# the alias is only appended when not already present.
#
# Args: $1 = custom domain (normalized), $2 = owner local part (e.g. "owner").
#
# Uses stalwart-cli's --json output (compact JSON for `get`, NDJSON for `query`)
# parsed with python3 (already in the image) rather than fragile column parsing.
# The account's `aliases` is an object-list (a map of stringified positional
# indices to {name, domainId, enabled} objects), so we append at the next free
# index; setting an index that already resolves to this address is skipped.
configure_custom_domain_inbound() {
    _cd="$1"
    _user="$2"
    echo "relay-config: registering custom mail domain $_cd as local"

    # 1. Create the domain (create is not idempotent by name; tolerate the error
    #    when it already exists from a prior run).
    stalwart-cli create Domain --field "name=$_cd" >/dev/null 2>&1 || true

    # 2. Resolve the custom domain's id (query Domain, match on the name field).
    _dom_id="$(stalwart-cli query Domain --fields id,name --json 2>/dev/null \
        | python3 -c '
import json, sys
target = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if isinstance(o, dict) and (o.get("name") or "").strip().lower().rstrip(".") == target:
        print(o.get("id") or "")
        break
' "$_cd")"

    # 3. Resolve the owner account's id (query Account, match on the name field).
    _acct_id="$(stalwart-cli query Account --fields id,name --json 2>/dev/null \
        | python3 -c '
import json, sys
target = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if isinstance(o, dict) and o.get("name") == target:
        print(o.get("id") or "")
        break
' "$_user")"

    if [ -z "$_dom_id" ] || [ -z "$_acct_id" ]; then
        echo "relay-config: could not resolve domain/account id for $_cd (dom='$_dom_id' acct='$_acct_id')"
        return 1
    fi

    # 4. Decide the next alias index, and skip if an alias for this domain already
    #    exists (idempotent across reboots and the auth-failed re-sync webhook).
    #    `get --json` returns the whole account as one compact JSON document.
    _idx="$(stalwart-cli get Account "$_acct_id" --fields aliases --json 2>/dev/null \
        | python3 -c '
import json, sys
dom_id = sys.argv[1]
try:
    o = json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
aliases = o.get("aliases") or {}
# Object-list: a map of stringified indices -> {name, domainId, ...}. Tolerate a
# list encoding too, just in case.
items = aliases.values() if isinstance(aliases, dict) else (aliases if isinstance(aliases, list) else [])
count = 0
for it in items:
    count += 1
    if isinstance(it, dict) and it.get("domainId") == dom_id:
        print("SKIP"); sys.exit(0)
print(count)
' "$_dom_id")"

    if [ "$_idx" = "SKIP" ]; then
        echo "relay-config: owner alias on $_cd already present; skipping"
        echo "relay-config: custom mail domain $_cd configured for inbound"
        return 0
    fi
    [ -z "$_idx" ] && _idx=0

    # 5. Append the alias at the next free index (JSON-pointer patch of one list
    #    element, so existing aliases are preserved).
    stalwart-cli update "account/user" "$_acct_id" \
        --field "aliases/$_idx={\"name\":\"$_user\",\"domainId\":\"$_dom_id\",\"enabled\":true}" \
        >/dev/null 2>&1 || return 1

    echo "relay-config: custom mail domain $_cd configured for inbound ($_user@$_cd)"
    return 0
}

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
# Also surfaces the optional custom mail domain so we can register it as a local
# Stalwart domain (see below) — without that, inbound mail for a BYO custom
# domain would be rejected as non-local even though its DNS/SES are set up.
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
custom = (d.get("custom_domain") or "").strip().lower().rstrip(".")
if not host or not user or not pw:
    print("CONFIGURED=0"); sys.exit(0)
print("CONFIGURED=1")
print(f"RELAY_HOST={shlex.quote(host)}")
print(f"RELAY_PORT={int(port)}")
print(f"RELAY_USER={shlex.quote(user)}")
print(f"RELAY_PW={shlex.quote(pw)}")
print(f"CUSTOM_DOMAIN={shlex.quote(custom)}")
')"
eval "$EVAL"

if [ "${CONFIGURED:-0}" != "1" ]; then
    echo "relay-config: email not configured on this instance; skipping outbound relay setup"
    exit 0
fi

# Implicit TLS when the relay port is the submission-over-TLS port (465).
if [ "$RELAY_PORT" = "465" ]; then
    IMPLICIT_TLS=true
else
    IMPLICIT_TLS=false
fi

echo "relay-config: configuring outbound smarthost $RELAY_USER@$RELAY_HOST:$RELAY_PORT (implicitTls=$IMPLICIT_TLS)"

# Create-or-update the relay route by name ("openhost-smarthost"). Delete any
# prior instance first so re-provisioning (e.g. rotated credential) is idempotent
# across reboots; ignore errors when it doesn't yet exist.
stalwart-cli delete MtaRoute openhost-smarthost >/dev/null 2>&1 || true
stalwart-cli apply --file /dev/stdin <<PLAN
{"@type":"create","object":"MtaRoute","value":{"openhost-smarthost":{"@type":"Relay","name":"openhost-smarthost","description":"OpenHost email proxy smarthost","address":"$RELAY_HOST","port":$RELAY_PORT,"protocol":"smtp","implicitTls":$IMPLICIT_TLS,"allowInvalidCerts":false,"authUsername":"$RELAY_USER","authSecret":{"@type":"Value","secret":"$RELAY_PW"}}}}
PLAN

# Point the default outbound route at the smarthost; keep local mail local.
stalwart-cli update MtaOutboundStrategy singleton \
    --field 'route={"match":[{"if":"is_local_domain('"'"''"'"', rcpt_domain)","then":"'"'"'local'"'"'"}],"else":"'"'"'openhost-smarthost'"'"'"}'

echo "relay-config: outbound smarthost configured"

# If the owner delegated a custom mail domain, register it as a local Stalwart
# domain and give the owner an alias on it, so inbound mail for that domain is
# accepted (is_local_domain) and delivered to the owner's existing mailbox.
# Without this, Stalwart only knows its built-in <zone> domain (created at first
# boot) and would reject inbound for the custom domain even though its DNS/SES
# are set up. Best-effort and idempotent — a failure here never aborts relay
# setup, and re-running does not duplicate the domain or the alias.
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
OWNER_EMAIL_USER="${OWNER_EMAIL_USER:-owner}"
if [ -n "$CUSTOM_DOMAIN" ]; then
    configure_custom_domain_inbound "$CUSTOM_DOMAIN" "$OWNER_EMAIL_USER" \
        || echo "relay-config: custom-domain inbound setup failed for $CUSTOM_DOMAIN (continuing)"
fi

# Register a Stalwart webhook that fires on outbound relay AUTH failure
# (delivery.auth-failed) so a rotated RELAY_SECRET is picked up immediately: the
# sidecar re-runs this script on receipt instead of waiting for the next boot.
# Idempotent — delete any prior hook first. Authenticated to the sidecar with a
# per-container bearer token (RELAY_WEBHOOK_TOKEN, generated at boot). Skipped if
# no token is set (e.g. reconfigure invoked from the webhook itself, to avoid a
# re-registration loop).
if [ -n "${RELAY_WEBHOOK_TOKEN:-}" ] && [ "${SKIP_WEBHOOK_REGISTER:-0}" != "1" ]; then
    WEBHOOK_URL="http://127.0.0.1:8082/_email/relay-webhook"
    stalwart-cli delete WebHook openhost-relay-auth >/dev/null 2>&1 || true
    stalwart-cli apply --file /dev/stdin <<HOOK
{"@type":"create","object":"WebHook","value":{"openhost-relay-auth":{"url":"$WEBHOOK_URL","events":["delivery.auth-failed"],"eventsPolicy":"include","level":"info","signatureKey":{"@type":"None"},"httpAuth":{"@type":"Bearer","bearerToken":{"@type":"Value","secret":"$RELAY_WEBHOOK_TOKEN"}},"httpHeaders":{},"throttle":"30s","enable":true}}}
HOOK
    echo "relay-config: registered delivery.auth-failed webhook -> sidecar"
fi
