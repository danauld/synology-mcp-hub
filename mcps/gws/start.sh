#!/bin/sh
# /mcps/gws/start.sh — supervisord launches `supergateway --stdio` with this as
# the stdio target. Two reasons we need a wrapper rather than execing `gws mcp`
# directly:
#
#   1. supergateway's child_process.spawn doesn't reliably propagate env vars
#      to the child shell (Cloud Run lesson, 2026-04-11). Re-export here.
#   2. The `gws` Go binary needs ~/.config/gws/ hydrated with FOUR files
#      (credentials.json, client_secret.json, accounts.json, .encryption_key)
#      before it will run. Setting GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE alone
#      is NOT sufficient.
#
# GWS_CREDENTIALS env var is the unencrypted JSON output of
# `gws auth export --unmasked` — supplied via env/gws.env on the Synology host.

set -e

export HOME=/root
export XDG_CONFIG_HOME=/root/.config
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file

GWS_DIR="$HOME/.config/gws"
mkdir -p "$GWS_DIR"

if [ -z "$GWS_CREDENTIALS" ]; then
  echo "ERROR: GWS_CREDENTIALS env var not set — refusing to start gws MCP" >&2
  exit 1
fi

# Hydrate ~/.config/gws/ from GWS_CREDENTIALS. Idempotent — overwrites on each
# supervisord program restart, fine because the JSON is deterministic.
echo "$GWS_CREDENTIALS" > "$GWS_DIR/credentials.json"
node -e "
  const c = JSON.parse(process.env.GWS_CREDENTIALS);
  const fs = require('fs');
  fs.writeFileSync('$GWS_DIR/client_secret.json', JSON.stringify({installed:{client_id:c.client_id,project_id:'gen-lang-client-0819568261',auth_uri:'https://accounts.google.com/o/oauth2/auth',token_uri:'https://oauth2.googleapis.com/token',auth_provider_x509_cert_url:'https://www.googleapis.com/oauth2/v1/certs',client_secret:c.client_secret,redirect_uris:['http://localhost']}}));
  fs.writeFileSync('$GWS_DIR/accounts.json', JSON.stringify({default:'danauld@gmail.com',accounts:{'danauld@gmail.com':{added:'2026-05-07'}}}));
  fs.writeFileSync('$GWS_DIR/.encryption_key', 'cloud-run-static-key-32-bytes!!');
"

export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE="$GWS_DIR/credentials.json"

exec gws mcp -s drive,tasks,gmail,people
