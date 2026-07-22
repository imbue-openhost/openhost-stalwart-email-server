# openhost-stalwart-email-server

Stalwart mail server (SMTP + JMAP, SQLite) packaged as an OpenHost app, with a
Caddy front + a JMAP service-proxy sidecar.

## Outbound: SMTP smarthost relay

Outbound mail does **not** go direct-to-MX. On boot the entrypoint fetches the
instance's SMTP smarthost relay config from the OpenHost router
(`GET $OPENHOST_ROUTER_URL/api/email/relay-config`, authenticated with
`$OPENHOST_APP_TOKEN`) and configures Stalwart to relay everything through the
central `openhost-email-proxy`:

- a `Relay` `MtaRoute` (`openhost-smarthost`) pointing at the proxy with SMTP
  AUTH (username = the instance zone, password = the per-instance HMAC credential
  the router returns), and
- the `MtaOutboundStrategy` `route` set so all outbound uses that relay.

This is applied idempotently on every boot (so rotated credentials are picked
up). The relay password is fetched at runtime and never injected into the app
environment. If the router provides no relay config, this is skipped and the
mailbox still runs.

## Custom (bring-your-own) mail domain

If the owner delegated a custom mail domain to the instance (one NS record; see
the openhost `email_custom_domain` setting), the router returns it in the relay
config and the entrypoint additionally provisions that `Domain` in Stalwart plus
an owner `User` account on it — so the owner can send/receive as their own
domain in addition to the built-in `<zone>` address.
