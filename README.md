# Synology MCP Hub

A single Docker container that hosts multiple Python and Node MCP wrappers around LAN-backed apps on Daniel's Synology Balmoral. Replaces the per-MCP Cloud Run + standalone-stack pattern with a consolidated runtime.

**Pair repo (private)**: [`danauld/synology-mcp-hub-workers`](https://github.com/danauld/synology-mcp-hub-workers) — three Cloudflare Workers that handle OAuth + proxy authenticated MCP requests to this Hub via Cloudflare Tunnel + Service Token.

## Architecture

```
Claude.ai web / Claude Code / Codex
   │  OAuth 2.1 + PKCE
   ▼   https://<slug>-mcp.danielauld.com/mcp
[Cloudflare Worker — <slug>-mcp shim]
   │  proxies with CF-Access-Client-Id + Secret headers
   ▼   https://<slug>-mcp-be.danielauld.com/mcp
[CF self-hosted Access app — Service Token policy]
   ▼   tunnel: synology-dommus
[mcp-hub container] supervisord runs:
   - port 8120 → arr        (supergateway → arr-mcp stdio)
   - port 8121 → dispatcharr (python server.py, FastMCP HTTP)
   - port 8122 → gramps     (node dist/index.js, native HTTP)
   ▼   Docker bridge networks (no tunnel hop)
[backends] sonarr, radarr, prowlarr, dispatcharr, grampsweb
```

## v1 MCP roster

| MCP | Language | Transport | Source | Internal port |
|---|---|---|---|---|
| **arr** (Sonarr/Radarr/Prowlarr) | Python | stdio + supergateway | `github.com/danauld/mcp-arr` (pip) | 8120 |
| **dispatcharr** | Python | FastMCP HTTP | `github.com/danauld/mcp-dispatcharr` (clone) | 8121 |
| **gramps** | Node TS | native HTTP | `github.com/danauld/mcp-grampsweb` (clone + npm build) | 8122 |

v2 (planned): Trakt MCP — see the worker repo for the addition pattern.

## Build + deploy

### Local build (test)

```bash
cd /Users/daniel/MCP/synology-mcp-hub
docker build -t synology-mcp-hub:dev .
# smoke test (without real backends, programs will start but their API calls fail; healthchecks may red)
docker run --rm -p 8120-8122:8120-8122 synology-mcp-hub:dev
```

### Cross-build for Synology amd64

Synology hosts run amd64. From the M-series Mac:

```bash
docker buildx build \
  --platform linux/amd64 \
  --push \
  --tag ghcr.io/danauld/synology-mcp-hub:latest \
  --tag ghcr.io/danauld/synology-mcp-hub:$(date +%Y-%m-%d) \
  .
```

Authenticate to GHCR first if needed: `echo $GITHUB_TOKEN | docker login ghcr.io -u danauld --password-stdin`.

### Deploy on Synology

The Hub stack uses env files mounted from the Synology host. On the Synology:

```bash
mkdir -p /volume1/docker/synology-mcp-hub/env
# Copy the .env.example files from this repo into env/ and fill in values.
# arr.env       — SONARR_API_KEY, RADARR_API_KEY, PROWLARR_API_KEY
# dispatcharr.env — DISPATCHARR_API_KEY
# gramps.env    — GRAMPS_USERNAME, GRAMPS_PASSWORD
```

Then deploy via Portainer:

1. Stacks → Add stack → name `mcp-hub`
2. Build method: Repository (this repo) OR copy `docker-compose.yml` directly
3. Deploy
4. Verify: `docker exec mcp-hub /usr/local/bin/healthcheck.sh` → "OK"

## Adding a new MCP (v2 onward)

Three files to edit, in order:

1. **Dockerfile** — add `pip install` (or `git clone + pip install -r requirements.txt` / `npm ci + npm run build`) for the new MCP under the builder stage. Use a fresh layer so we can cache.
2. **supervisord.conf** — add a `[program:<slug>]` block with the next free port (8123, 8124, …). Mirror the closest existing block by transport type.
3. **env/<slug>.env.example** — list the env vars the new MCP needs.
4. **docker-compose.yml** — add `env_file:` line for the new env file. Optionally join an additional Docker network if the new backend lives in one.
5. **scripts/healthcheck.sh** — add a port check.

Then:
- `git commit + push` (this repo)
- Cross-build + push to GHCR with a new tag
- Update the Synology stack to pull the new image
- Add a Worker shim for the new MCP in the workers repo
- Add CF resources (KV, SaaS OIDC app, DNS records, tunnel ingress rule for `<slug>-mcp-be.danielauld.com`)

The pair repo's README has the Worker side of this.

## Restore from scratch (computer migration)

If the local Mac is lost, recovery is:

```bash
# 1. Clone both repos
git clone https://github.com/danauld/synology-mcp-hub.git
git clone https://github.com/danauld/synology-mcp-hub-workers.git

# 2. Cross-build + push image (need GHCR auth)
cd synology-mcp-hub
docker buildx build --platform linux/amd64 --push \
  --tag ghcr.io/danauld/synology-mcp-hub:latest .

# 3. Worker side: cd ../synology-mcp-hub-workers; see its README
# 4. Synology side: deploy the docker-compose.yml via Portainer
# 5. Cloudflare resources: see Obsidian `systems/mcps/Synology MCP Hub.md`
#    for the full CF API call sequence to recreate KV, SaaS OIDC apps,
#    Access apps, Service Tokens, and tunnel ingress rules.
```

The Obsidian note is the authoritative restore script. This README covers the "what is it" and the build commands. See the note for the "how to recreate the cloud resources" sequence.

## Operational notes

- **Logs**: `docker logs mcp-hub` shows all three programs interleaved, prefixed by program name. Use `docker logs mcp-hub 2>&1 | grep -E "^(arr|dispatcharr|gramps)\\b"` to filter to one MCP.
- **Restart one MCP without restarting the container**: `docker exec mcp-hub supervisorctl restart arr` (or `dispatcharr` / `gramps`).
- **Programs go red on backend outage**: e.g., if Sonarr is down, the arr-mcp tools will error but the program stays running. supervisord's `autorestart` only fires on process exit, not on tool failures.
- **Image rebuild required for code changes**: Sources are baked at build time, not mounted. Code changes → rebuild → push → re-pull on Synology. (Tradeoff: predictable, reproducible deploys vs. instant iteration. We picked predictability.)
- **Adding a new tunnel ingress rule**: The synology-dommus tunnel is shared with other Synology services. Use the CF API (`PUT /accounts/{id}/cfd_tunnel/{id}/configurations`) with the existing config + the new rule appended; don't replace the whole config without copying existing rules.

## Cost

- Previous architecture (3 separate stacks):
  - arr-mcp Synology stack: free (Synology compute)
  - dispatcharr-mcp + own tunnel: free
  - grampsweb-mcp Cloud Run: ~$0.04 AUD/mo
  - Total: ~$0.04/mo + 3 stacks to maintain
- New architecture: 1 Hub stack on Synology + 3 Workers on Cloudflare free tier = **$0/mo** + 1 stack to maintain.

Cost saving is rounding error; the win is fleet consistency + auth upgrade (URL-token-secret → OAuth via per-MCP Worker).

## License

MIT.
