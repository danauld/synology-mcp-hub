# Synology MCP Hub — single image hosting multiple Python/Node MCPs
#
# Layout inside container:
#   /mcps/arr/           — pip-installed `mcp-arr` package (stdio, wrapped by supergateway)
#   /mcps/dispatcharr/   — Python source (HTTP-native FastMCP)
#   /mcps/gramps/        — Node app (HTTP-native MCP, built dist/)
#   /mcps/trakt/         — Python source (stdio, wrapped by supergateway)
#   /mcps/pbs/           — Node app (HTTP-native MCP, recovered compiled JS in dist/)
#   /mcps/whatsupp/      — Node app (HTTP-native MCP, built dist/, Supabase backend)
#   (openfoodfacts + nanobanana are package installs, not under /mcps)
#
# Each MCP runs under supervisord on its own internal port:
#   8120 — arr            (via supergateway → arr-mcp stdio)
#   8121 — dispatcharr    (python server.py listens directly)
#   8122 — gramps         (node dist/index.js listens directly)
#   8123 — trakt          (via supergateway → python /mcps/trakt/server.py stdio)
#   8124 — openfoodfacts  (off-mcp-server, npm-global @jagjeevan/openfoodfacts-mcp@1.1.0)
#   8125 — pbs            (node /mcps/pbs/dist/index.js listens directly)
#   8127 — nanobanana     (nanobanana-mcp-server, pip-installed FastMCP HTTP)
#   8129 — whatsupp       (node /mcps/whatsupp/dist/index.js listens directly)
#                         (8126 is taken by vault-mcp on the Synology host)
#   8128 — gws            (Google Workspace CLI v0.7.0, supergateway-bridged)
#
# Cloudflare Tunnel routes <slug>-be.danielauld.com → mcp-hub:81NN.
# Per-MCP CF Worker shim handles OAuth + proxies to the backend hostnames.
# This Dockerfile bakes all 6 MCP sources at build time — no runtime pip/git.

# syntax=docker/dockerfile:1.7

FROM python:3.12-slim AS builder

# Install Node 22 + git so we can fetch + build the gramps TypeScript MCP.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates git build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# --- arr MCP: PUBLIC repo, no auth needed ---
RUN python -m pip install --upgrade pip \
    && python -m pip install --no-cache-dir "git+https://github.com/danauld/mcp-arr@main"

# --- dispatcharr + gramps: PRIVATE repos. Use BuildKit secret to inject a
# GitHub token at build time. Token is never written to the image.
# Build with: --secret id=gh_token,env=GH_TOKEN

RUN --mount=type=secret,id=gh_token \
    GH_TOKEN=$(cat /run/secrets/gh_token) \
    && git clone --depth=1 \
        "https://x-access-token:${GH_TOKEN}@github.com/danauld/mcp-dispatcharr.git" \
        /mcps/dispatcharr \
    && python -m pip install --no-cache-dir -r /mcps/dispatcharr/requirements.txt \
    && rm -rf /mcps/dispatcharr/.git

RUN --mount=type=secret,id=gh_token \
    GH_TOKEN=$(cat /run/secrets/gh_token) \
    && git clone --depth=1 \
        "https://x-access-token:${GH_TOKEN}@github.com/danauld/mcp-grampsweb.git" \
        /mcps/gramps \
    && cd /mcps/gramps \
    && npm ci \
    && npm run build \
    && npm prune --omit=dev \
    && rm -rf /mcps/gramps/.git

# --- trakt MCP: PRIVATE repo (recovered from Cloud Run image, pushed 2026-04-25) ---
RUN --mount=type=secret,id=gh_token \
    GH_TOKEN=$(cat /run/secrets/gh_token) \
    && git clone --depth=1 \
        "https://x-access-token:${GH_TOKEN}@github.com/danauld/mcp-trakt.git" \
        /mcps/trakt \
    && python -m pip install --no-cache-dir -r /mcps/trakt/requirements.txt \
    && rm -rf /mcps/trakt/.git

# --- pbs MCP: PRIVATE repo (recovered from Cloud Run image, pushed 2026-04-26).
# Compiled `dist/` only — no `src/` was recoverable. Runs `node dist/index.js`
# with TRANSPORT=http (see supervisord.conf). ---
RUN --mount=type=secret,id=gh_token \
    GH_TOKEN=$(cat /run/secrets/gh_token) \
    && git clone --depth=1 \
        "https://x-access-token:${GH_TOKEN}@github.com/danauld/mcp-pbs.git" \
        /mcps/pbs \
    && cd /mcps/pbs \
    && npm ci --omit=dev \
    && rm -rf /mcps/pbs/.git

# --- whatsupp MCP: PRIVATE repo (medication & supplement tracker, Supabase
# backend). Node TS Express HTTP MCP using StreamableHTTPServerTransport.
# The Git repo nests the server under "App • WhatSupp/whatsupp-mcp-server/"
# (alongside the iOS app source), so we clone to a tmp dir, move the server
# subfolder into /mcps/whatsupp, then build there. Migrated from Cloud Run
# 2026-05-10 (v6). Auth: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY via env_file. ---
RUN --mount=type=secret,id=gh_token \
    GH_TOKEN=$(cat /run/secrets/gh_token) \
    && git clone --depth=1 \
        "https://x-access-token:${GH_TOKEN}@github.com/danauld/WhatSupp.git" \
        /tmp/whatsupp-src \
    && mv "/tmp/whatsupp-src/App • WhatSupp/whatsupp-mcp-server" /mcps/whatsupp \
    && rm -rf /tmp/whatsupp-src \
    && cd /mcps/whatsupp \
    && npm ci \
    && npm run build \
    && npm prune --omit=dev

# --- final stage: runtime image (no build toolchain bloat) ---
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    SUPERVISOR_LOGLEVEL=info \
    HUB_VERSION=v6

# Runtime deps only: Node (for gramps + supergateway), supervisor, tini for clean shutdown.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates supervisor tini \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g supergateway@3.4.3 \
    && npm install -g @jagjeevan/openfoodfacts-mcp@1.1.0 \
    # gws MCP (Google Workspace CLI). PIN to 0.7.0 — `gws mcp` subcommand was
    # removed in 0.8.0 (upstream PR #275). Do NOT bump to @latest.
    && npm install -g @googleworkspace/cli@0.7.0 \
    # Patch upstream v1.1.0 bug: dist/tools/index.js calls registerPriceTools(server)
    # twice in a row, which causes "Tool getProductPrices is already registered"
    # at startup. Remove the second call. Track upstream for a fix; once resolved,
    # bump the version pin and remove this awk.
    && awk 'BEGIN{p=""} { if ($0 ~ /^[[:space:]]*registerPriceTools\(server\);$/ && p ~ /^[[:space:]]*registerPriceTools\(server\);$/) { p=$0; next } if (p != "") print p; p=$0 } END{ if (p != "") print p }' \
        /usr/lib/node_modules/@jagjeevan/openfoodfacts-mcp/dist/tools/index.js > /tmp/off-index.js \
    && mv /tmp/off-index.js /usr/lib/node_modules/@jagjeevan/openfoodfacts-mcp/dist/tools/index.js \
    && [ "$(grep -c 'registerPriceTools(server);' /usr/lib/node_modules/@jagjeevan/openfoodfacts-mcp/dist/tools/index.js)" = "1" ] \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --- nanobanana MCP: PyPI-installed Python FastMCP server (zhongweili/nanobanana-mcp-server).
# Installs the `nanobanana-mcp-server` console script. Reads FASTMCP_TRANSPORT=http
# + FASTMCP_HOST + FASTMCP_PORT from supervisord env to serve over HTTP on :8127.
# Auth: GEMINI_API_KEY (Google AI Studio), supplied via env_file: env/nanobanana.env. ---
RUN python -m pip install --no-cache-dir "nanobanana-mcp-server>=0.4.4"

# Copy installed Python packages from builder (arr-mcp + dispatcharr deps).
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy MCP sources.
COPY --from=builder /mcps /mcps

# gws MCP wrapper script (no build-time dependencies — just a shell script that
# hydrates ~/.config/gws/ from the GWS_CREDENTIALS env var at supervisord
# program start, then execs `gws mcp -s drive,tasks,gmail,people`).
COPY mcps/gws /mcps/gws
RUN chmod +x /mcps/gws/start.sh

# Supervisor config + healthcheck script.
COPY supervisord.conf /etc/supervisor/conf.d/mcp-hub.conf
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# Expose the three internal ports. The Cloudflare Tunnel container reaches
# these via Docker network DNS — no host port-mapping required at runtime,
# but EXPOSE makes the contract explicit.
EXPOSE 8120 8121 8122 8123 8124 8125 8127 8128 8129

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# tini handles signal forwarding to supervisord; supervisord then forwards to children.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/mcp-hub.conf"]
