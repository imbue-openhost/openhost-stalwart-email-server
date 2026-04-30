"""OpenHost JMAP service provider.

Sits between the router's v2 service proxy and Stalwart's JMAP listener:

  consumer app  -->  router  -->  Caddy (handle_path /_jmap_service/*)
                                    -->  this sidecar (127.0.0.1:8082)
                                    -->  Stalwart HTTP listener (127.0.0.1:8081)

Validates the X-OpenHost-Permissions header for the {"key": "jmap:full_access"}
grant, drops any consumer-supplied Authorization/Cookie, injects the owner
mailbox's Basic auth, and reverse-proxies HTTP, SSE, and WebSocket traffic.
"""

import asyncio
import json
import logging
import os
from typing import Any

import httpx
import websockets
from litestar import Litestar
from litestar.handlers import asgi
from litestar.types import Receive, Scope, Send

logger = logging.getLogger("jmap_proxy")

UPSTREAM_BASE = os.environ.get("STALWART_UPSTREAM", "http://127.0.0.1:8081")
USER_BASIC_AUTH = os.environ.get("USER_BASIC_AUTH", "")

PERMISSION_DENIED_BODY = json.dumps(
    {
        "error": "permission_required",
        "required_grant": {
            "grant_payload": {"key": "jmap:full_access"},
            "scope": "global",
        },
    }
).encode("utf-8")

# RFC 7230 hop-by-hop headers, plus headers we own ourselves.
_HOP_BY_HOP = frozenset(
    {
        b"connection",
        b"keep-alive",
        b"proxy-authenticate",
        b"proxy-authorization",
        b"te",
        b"trailers",
        b"transfer-encoding",
        b"upgrade",
    }
)
_STRIPPED_REQUEST = _HOP_BY_HOP | frozenset(
    {
        b"authorization",
        b"cookie",
        b"host",
        b"x-openhost-permissions",
        b"x-openhost-consumer",
    }
)
_STRIPPED_RESPONSE = _HOP_BY_HOP


def _has_jmap_grant(perms_raw: bytes) -> bool:
    try:
        grants = json.loads(perms_raw or b"[]")
    except (json.JSONDecodeError, ValueError):
        return False
    if not isinstance(grants, list):
        return False
    for g in grants:
        if not isinstance(g, dict):
            continue
        payload = g.get("grant")
        if isinstance(payload, dict) and payload.get("key") == "jmap:full_access":
            return True
    return False


def _lookup_header(scope_headers: list[tuple[bytes, bytes]], name: bytes) -> bytes:
    for k, v in scope_headers:
        if k.lower() == name:
            return v
    return b""


def _map_path(path: str) -> str:
    if not path.startswith("/"):
        path = "/" + path
    if path.rstrip("/") == "/.well-known/jmap":
        return path
    return "/jmap" + path


def _build_upstream_headers(scope_headers: list[tuple[bytes, bytes]]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for k, v in scope_headers:
        if k.lower() in _STRIPPED_REQUEST:
            continue
        out.append((k.decode("latin-1"), v.decode("latin-1")))
    if USER_BASIC_AUTH:
        out.append(("Authorization", f"Basic {USER_BASIC_AUTH}"))
    return out


# ─── HTTP ───


async def _send_simple_response(send: Send, status: int, body: bytes) -> None:
    await send(
        {
            "type": "http.response.start",
            "status": status,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body, "more_body": False})


async def _proxy_http(scope: Scope, receive: Receive, send: Send) -> None:
    perms = _lookup_header(scope["headers"], b"x-openhost-permissions")
    if not _has_jmap_grant(perms):
        await _send_simple_response(send, 403, PERMISSION_DENIED_BODY)
        # Drain the request body so the connection can be reused.
        more = True
        while more:
            msg = await receive()
            if msg["type"] == "http.disconnect":
                return
            more = msg.get("more_body", False)
        return

    target_path = _map_path(scope["path"])
    query = scope.get("query_string", b"")
    target_url = target_path
    if query:
        target_url = f"{target_path}?{query.decode('latin-1')}"

    upstream_headers = _build_upstream_headers(scope["headers"])

    async def request_body():
        while True:
            msg = await receive()
            if msg["type"] == "http.disconnect":
                return
            chunk = msg.get("body", b"") or b""
            if chunk:
                yield chunk
            if not msg.get("more_body", False):
                return

    method = scope["method"]
    has_body = method in ("POST", "PUT", "PATCH")

    client = httpx.AsyncClient(base_url=UPSTREAM_BASE, timeout=None, follow_redirects=True)
    try:
        upstream_req = client.build_request(
            method=method,
            url=target_url,
            headers=upstream_headers,
            **({"content": request_body()} if has_body else {}),
        )
        upstream_resp = await client.send(upstream_req, stream=True)
    except Exception:
        logger.exception("upstream request failed")
        await client.aclose()
        body = json.dumps({"error": "upstream_unavailable"}).encode("utf-8")
        await _send_simple_response(send, 502, body)
        return

    response_headers: list[tuple[bytes, bytes]] = []
    for k, v in upstream_resp.headers.raw:
        if k.lower() in _STRIPPED_RESPONSE:
            continue
        response_headers.append((k, v))

    await send(
        {
            "type": "http.response.start",
            "status": upstream_resp.status_code,
            "headers": response_headers,
        }
    )
    try:
        async for chunk in upstream_resp.aiter_raw():
            await send({"type": "http.response.body", "body": chunk, "more_body": True})
        await send({"type": "http.response.body", "body": b"", "more_body": False})
    finally:
        await upstream_resp.aclose()
        await client.aclose()


# ─── WebSocket ───


async def _proxy_ws(scope: Scope, receive: Receive, send: Send) -> None:
    perms = _lookup_header(scope["headers"], b"x-openhost-permissions")

    # ASGI requires us to consume websocket.connect before any send.
    msg = await receive()
    if msg["type"] != "websocket.connect":
        return

    if not _has_jmap_grant(perms):
        await send({"type": "websocket.close", "code": 1008})
        return

    upstream_url = (
        UPSTREAM_BASE.replace("https://", "wss://", 1).replace("http://", "ws://", 1)
        + "/jmap/ws"
    )
    upstream_headers = _build_upstream_headers(scope["headers"])
    subprotocols = scope.get("subprotocols") or None

    try:
        upstream = await websockets.connect(
            upstream_url,
            additional_headers=upstream_headers,
            subprotocols=subprotocols,
            max_size=None,
        )
    except Exception:
        logger.exception("failed to open upstream JMAP websocket")
        await send({"type": "websocket.close", "code": 1011})
        return

    accept_msg: dict[str, Any] = {"type": "websocket.accept"}
    if upstream.subprotocol:
        accept_msg["subprotocol"] = upstream.subprotocol
    await send(accept_msg)

    async def client_to_upstream() -> None:
        while True:
            event = await receive()
            etype = event["type"]
            if etype == "websocket.disconnect":
                return
            if etype != "websocket.receive":
                continue
            text = event.get("text")
            if text is not None:
                await upstream.send(text)
                continue
            data = event.get("bytes")
            if data is not None:
                await upstream.send(data)

    async def upstream_to_client() -> None:
        async for frame in upstream:
            if isinstance(frame, str):
                await send({"type": "websocket.send", "text": frame})
            else:
                await send({"type": "websocket.send", "bytes": frame})

    c2u = asyncio.create_task(client_to_upstream())
    u2c = asyncio.create_task(upstream_to_client())
    try:
        _, pending = await asyncio.wait(
            {c2u, u2c}, return_when=asyncio.FIRST_COMPLETED
        )
        for task in pending:
            task.cancel()
        for task in pending:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
    finally:
        await upstream.close()
        try:
            await send({"type": "websocket.close"})
        except Exception:
            pass


# ─── ASGI dispatch ───


@asgi("/", is_mount=True)
async def proxy(scope: Scope, receive: Receive, send: Send) -> None:
    if scope["type"] == "http":
        await _proxy_http(scope, receive, send)
    elif scope["type"] == "websocket":
        await _proxy_ws(scope, receive, send)


app = Litestar(route_handlers=[proxy])
