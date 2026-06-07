#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Runs openclaw onboard --non-interactive to configure from env vars
# 2. Patches config for features onboard doesn't cover (channels, gateway auth)
# 3. Starts the gateway
#
# NOTE: Persistence (backup/restore) is handled by the Sandbox SDK at the
# Worker level, not inside the container. The Worker calls createBackup()
# and restoreBackup() which use squashfs snapshots stored in R2.
# No rclone or R2 credentials are needed inside the container.

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
CORE_WORKSPACE_DIR="$CONFIG_DIR/workspace"
MEMORY_FILE="$CORE_WORKSPACE_DIR/MEMORY.md"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"
mkdir -p "$CORE_WORKSPACE_DIR"

if [ ! -f "$MEMORY_FILE" ]; then
    cat > "$MEMORY_FILE" << 'EOFMEMORY'
# Memory

Persistent notes for this OpenClaw workspace.
EOFMEMORY
    echo "Created missing memory file: $MEMORY_FILE"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    # Determine auth choice — openclaw onboard reads the actual key values
    # from environment variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
    # so we only pass --auth-choice, never the key itself, to avoid
    # exposing secrets in process arguments visible via ps/proc.
    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowedOrigins = ['*'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

// Allow any origin to connect to the gateway control UI.
// The gateway runs inside a Cloudflare Container behind the Worker, which
// proxies requests from the public workers.dev domain. Without this,
// openclaw >= 2026.2.26 rejects WebSocket connections because the browser's
// origin (https://....workers.dev) doesn't match the gateway's localhost.
// Security is handled by CF Access + gateway token auth, not origin checks.
config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowedOrigins = ['*'];

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
const WORKERS_AI_COMPAT_CHAT_MODELS = [
    '@cf/moonshotai/kimi-k2.6',
    '@cf/zai-org/glm-4.7-flash',
    '@cf/openai/gpt-oss-120b',
    '@cf/meta/llama-4-scout-17b-16e-instruct',
    '@cf/google/gemma-4-26b-a4b-it',
    '@cf/nvidia/nemotron-3-120b-a12b',
    '@cf/moonshotai/kimi-k2.5',
    '@cf/ibm/granite-4.0-h-micro',
    '@cf/aisingapore/gemma-sea-lion-v4-27b-it',
    '@cf/openai/gpt-oss-20b',
    '@cf/qwen/qwen3-30b-a3b-fp8',
    '@cf/google/gemma-3-12b-it',
    '@cf/mistralai/mistral-small-3.1-24b-instruct',
    '@cf/qwen/qwq-32b',
    '@cf/qwen/qwen2.5-coder-32b-instruct',
    '@cf/meta/llama-guard-3-8b',
    '@cf/deepseek-ai/deepseek-r1-distill-qwen-32b',
    '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
    '@cf/meta/llama-3.2-1b-instruct',
    '@cf/meta/llama-3.2-3b-instruct',
    '@cf/meta/llama-3.2-11b-vision-instruct',
    '@cf/meta/llama-3.1-8b-instruct-awq',
    '@cf/meta/llama-3.1-8b-instruct-fp8',
    '@cf/meta/llama-3.1-8b-instruct',
    '@cf/meta/llama-3-8b-instruct',
    '@cf/meta/llama-3-8b-instruct-awq',
    '@cf/mistral/mistral-7b-instruct-v0.2',
    '@cf/google/gemma-7b-it-lora',
    '@cf/google/gemma-2b-it-lora',
    '@cf/meta/llama-2-7b-chat-hf-lora',
    '@cf/google/gemma-7b-it',
    '@hf/nousresearch/hermes-2-pro-mistral-7b',
    '@cf/mistral/mistral-7b-instruct-v0.2-lora',
    '@cf/microsoft/phi-2',
    '@cf/defog/sqlcoder-7b-2',
    '@cf/meta/llama-2-7b-chat-fp16',
    '@cf/mistral/mistral-7b-instruct-v0.1',
    '@cf/meta/llama-2-7b-chat-int8',
    '@cf/meta/llama-3.1-70b-instruct',
    '@cf/meta/llama-3.1-8b-instruct-fast',
];

function toOpenClawModel(modelId) {
    return {
        id: modelId,
        name: modelId,
        contextWindow: 131072,
        maxTokens: 8192,
    };
}

const rawModelOverride = process.env.CF_AI_GATEWAY_MODEL || '';
const shouldConfigureWorkersAi =
    rawModelOverride.startsWith('workers-ai/') ||
    (!rawModelOverride && process.env.CLOUDFLARE_AI_GATEWAY_API_KEY && process.env.CF_AI_GATEWAY_ACCOUNT_ID && process.env.CF_AI_GATEWAY_GATEWAY_ID);

if (process.env.CF_AI_GATEWAY_MODEL || shouldConfigureWorkersAi) {
    const raw = rawModelOverride || 'workers-ai/@cf/moonshotai/kimi-k2.6';
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (gwProvider === 'workers-ai') {
        if (accountId && gatewayId) {
            baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/compat';
        } else if (accountId) {
            baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + accountId + '/ai/v1';
        }
    } else if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;
        const models =
            gwProvider === 'workers-ai'
                ? WORKERS_AI_COMPAT_CHAT_MODELS.map(toOpenClawModel)
                : [toOpenClawModel(modelId)];
        const defaultModelId =
            gwProvider === 'workers-ai' && !WORKERS_AI_COMPAT_CHAT_MODELS.includes(modelId)
                ? WORKERS_AI_COMPAT_CHAT_MODELS[0]
                : modelId;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models,
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + defaultModelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + defaultModelId + ' via ' + baseUrl);
        if (gwProvider === 'workers-ai') {
            console.log('Workers AI compat models available: ' + models.length);
        }
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

# Gateway token (if set) is already written to openclaw.json by the config
# patch above (gateway.auth.token). We deliberately avoid passing --token on
# the command line because CLI arguments are visible to all processes in the
# container via ps/proc.
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
else
    echo "Starting gateway with device pairing (no token)..."
fi
exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
