#!/bin/sh
# Health check for the Synology MCP Hub.
#
# Each MCP exposes its own port; we hit a reachable URL on each one and
# fail the whole container if any single MCP is down. supervisord will
# restart individual programs on its own; this is the outer-container
# liveness signal for Docker / Portainer.

set -eu

# arr-mcp via supergateway has a dedicated /healthz endpoint.
curl -fsS --max-time 5 "http://127.0.0.1:8120/healthz" >/dev/null

# dispatcharr-mcp (FastMCP HTTP) — POST a JSON-RPC initialize to /mcp,
# expect a 200. (FastMCP doesn't ship a separate health route.)
curl -fsS --max-time 5 -X POST "http://127.0.0.1:8121/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":"hc","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' \
    >/dev/null

# gramps-mcp (Node) — same pattern; whatever path it serves, an
# initialize POST should succeed.
curl -fsS --max-time 5 -X POST "http://127.0.0.1:8122/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":"hc","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' \
    >/dev/null

echo "OK"
