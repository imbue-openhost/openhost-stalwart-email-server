# JMAP Service

JMAP (RFC 8620) mail access to the owner's mailbox, exposed as an OpenHost
v2 cross-app service.

**Service URL:** `github.com/imbue-openhost/openhost-stalwart-email-server/services/jmap`

**Version:** `0.1.0`

## Calling the service

Consumer apps make requests through the router's v2 service proxy:

```
POST {OPENHOST_ROUTER_URL}/_services_v2/service_request
Authorization: Bearer {OPENHOST_APP_TOKEN}
X-OpenHost-Service-URL: github.com/imbue-openhost/openhost-stalwart-email-server/services/jmap
X-OpenHost-Service-Version: ^0.1.0
X-OpenHost-Service-Endpoint: /<jmap-path>
```

The router authenticates the caller, attaches the consumer's granted
permissions in `X-OpenHost-Permissions`, and forwards the request to this
provider. The provider validates the permissions and proxies to the
underlying Stalwart JMAP server.

Consumer apps **must not** send their own `Authorization` or `Cookie`
headers — the provider drops them and injects the owner's mailbox
credentials before forwarding upstream.

## Permissions

Grants are global-scoped and follow the same `{"key": "<identifier>"}`
shape as the secrets service.

| Key                | Grants                                                       |
|--------------------|--------------------------------------------------------------|
| `jmap:full_access` | Full read / write / send access to the owner's mailbox       |

Future expansion (e.g. `jmap:read`, `jmap:send`) will use the same shape.

### Permission denied response

When the caller is missing a required permission the provider returns
`403` with:

```json
{
  "error": "permission_required",
  "required_grant": {
    "grant_payload": {"key": "jmap:full_access"},
    "scope": "global"
  }
}
```

The router fills in `grant_url` for global-scoped grants automatically.

## Endpoints

The provider forwards requests to Stalwart's JMAP surface. Method-level
semantics are defined by the JMAP RFCs:

- RFC 8620 — JMAP core
- RFC 8621 — JMAP for mail
- RFC 8887 — JMAP over WebSocket

| Endpoint                                | Forwarded to (Stalwart)               |
|-----------------------------------------|---------------------------------------|
| `GET  /.well-known/jmap`                | `/.well-known/jmap` (session object)  |
| `POST /api`                             | `/jmap/api`                           |
| `GET  /eventsource`                     | `/jmap/eventsource` (SSE push)        |
| `GET  /ws`                              | `/jmap/ws` (WebSocket, RFC 8887)      |
| `PUT  /upload/{accountId}`              | `/jmap/upload/{accountId}`            |
| `GET  /download/{accountId}/{blobId}/{name}` | `/jmap/download/{accountId}/{blobId}/{name}` |

Request and response bodies are streamed — large blob uploads/downloads
and SSE event streams pass through without buffering.
