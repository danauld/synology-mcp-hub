# Synology MCP Hub — single image hosting multiple Python/Node MCPs
#
# Layout inside container:
#   /mcps/arr/         — pip-installed `mcp-arr` package (stdio, wrapped by supergateway)
#   /mcps/dispatcharr/ — Python source (HTTP-native FastMCP)
#   /mcps/gramps/      — Node app (HTTP-native MCP, built dist/)
#
# Each MCP runs under supervisord on its own internal port:
#   8120 — arr        (via supergateway → arr-mcp stdio)
#   8121 — dispatcharr (python server.py listens directly)
#   8122 — gramps     (node dist/index.js listens directly)
#
# Cloudflare Tunnel routes <slug>-be.danielauld.com → mcp-hub:81NN.
# Per-MCP CF Worker shim handles OAuth + proxies to the backend hostnames.
# This Dockerfile bakes all 3 MCP sources at build time — no runtime pip/git.

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

# --- arr MCP: pip-install from GitHub at a pinned commit (use `main` for now) ---
RUN python -m pip install --upgrade pip \
    && python -m pip install --no-cache-dir "git+https://github.com/danauld/mcp-arr@main"

# --- dispatcharr MCP: clone + pip install requirements ---
RUN git clone --depth=1 https://github.com/danauld/mcp-dispatcharr /mcps/dispatcharr \
    && python -m pip install --no-cache-dir -r /mcps/dispatcharr/requirements.txt

# --- gramps MCP: clone, npm install + build, keep only runtime deps + dist ---
RUN git clone --depth=1 https://github.com/danauld/mcp-grampsweb /mcps/gramps \
    && cd /mcps/gramps \
    && npm ci \
    && npm run build \
    && npm prune --omit=dev

# --- final stage: runtime image (no build toolchain bloat) ---
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    SUPERVISOR_LOGLEVEL=info \
    HUB_VERSION=v1

# Runtime deps only: Node (for gramps + supergateway), supervisor, tini for clean shutdown.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates supervisor tini \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g supergateway@3.4.3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder (arr-mcp + dispatcharr deps).
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy MCP sources.
COPY --from=builder /mcps /mcps

# Supervisor config + healthcheck script.
COPY supervisord.conf /etc/supervisor/conf.d/mcp-hub.conf
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# Expose the three internal ports. The Cloudflare Tunnel container reaches
# these via Docker network DNS — no host port-mapping required at runtime,
# but EXPOSE makes the contract explicit.
EXPOSE 8120 8121 8122

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# tini handles signal forwarding to supervisord; supervisord then forwards to children.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/mcp-hub.conf"]
