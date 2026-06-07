#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="moltbot-sandbox-sandbox"
DASHBOARD_URL="https://dash.cloudflare.com/?to=/:account/workers/containers"
DEFAULT_WORKER_URL="https://moltbot-sandbox.hacolby.workers.dev"

echo "Generating a new MOLTBOT_GATEWAY_TOKEN..."
TOKEN="$(openssl rand -hex 32)"

echo "Writing MOLTBOT_GATEWAY_TOKEN to Cloudflare Workers secrets..."
printf '%s\n' "$TOKEN" | npx wrangler secret put MOLTBOT_GATEWAY_TOKEN

cat <<EOF

The gateway token has been rotated.

Cloudflare Wrangler does not currently expose a direct container deletion command.
Delete the hung container manually before redeploying:

  1. Open: ${DASHBOARD_URL}
  2. Go to Workers & Pages -> Containers.
  3. Locate and delete: ${CONTAINER_NAME}
  4. Wait until the container is gone from the dashboard.

EOF

read -r -p "Type 'deleted' after ${CONTAINER_NAME} has been deleted: " CONFIRMATION
if [[ "$CONFIRMATION" != "deleted" ]]; then
  echo "Aborted. Re-run npm run reset-gateway after deleting ${CONTAINER_NAME}."
  exit 1
fi

echo "Redeploying Worker with the new gateway token..."
DEPLOY_LOG="$(mktemp)"
if ! npm run deploy 2>&1 | tee "$DEPLOY_LOG"; then
  echo "Deploy failed. The new gateway token is still:"
  echo "$TOKEN"
  exit 1
fi

WORKER_URL="${WORKER_URL:-$DEFAULT_WORKER_URL}"
if [[ -z "$WORKER_URL" ]]; then
  WORKER_URL="$(grep -Eo 'https://[^[:space:]]+\.workers\.dev' "$DEPLOY_LOG" | tail -n 1 || true)"
fi

if [[ -z "$WORKER_URL" ]]; then
  WORKER_NAME="$(node -e "const fs=require('fs'); const text=fs.readFileSync('wrangler.jsonc','utf8'); const match=text.match(/\"name\"\\s*:\\s*\"([^\"]+)\"/); process.stdout.write(match ? match[1] : 'moltbot-sandbox');")"
  WORKER_URL="https://${WORKER_NAME}.workers.dev"
fi

rm -f "$DEPLOY_LOG"

echo
echo "Gateway reset complete."
echo "New gateway token:"
echo "$TOKEN"
echo
echo "Open the gateway:"
echo "${WORKER_URL}?token=${TOKEN}"
