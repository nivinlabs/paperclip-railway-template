# Build upstream Paperclip from a pinned ref.
FROM node:22-bookworm AS paperclip-build
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

ARG PAPERCLIP_REPO=https://github.com/paperclipai/paperclip.git
ARG PAPERCLIP_REF=v2026.416.0

WORKDIR /paperclip
RUN git clone --depth 1 --branch "${PAPERCLIP_REF}" "${PAPERCLIP_REPO}" .
RUN pnpm install --frozen-lockfile

# Patch hermes-paperclip-adapter to add ollama-cloud to VALID_PROVIDERS
# so the adapter correctly recognizes and displays the ollama-cloud provider
# instead of falling back to "auto" or prefix-inferred "zai".
RUN ADAPTER_DIR=$(find /paperclip/node_modules -path "*/hermes-paperclip-adapter/dist/shared/constants.js" | head -1) \
    && if [ -n "$ADAPTER_DIR" ]; then \
      sed -i 's/"kilocode",/"kilocode", "ollama-cloud",/' "$ADAPTER_DIR"; \
      echo "Patched $ADAPTER_DIR"; \
      grep -o "ollama-cloud" "$ADAPTER_DIR"; \
    else \
      echo "WARNING: hermes-paperclip-adapter constants.js not found"; \
    fi

RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js

# Runtime image (direct Paperclip server, no wrapper).
FROM node:22-bookworm
ENV NODE_ENV=production
ENV CLAUDE_CODE_BUBBLEWRAP=1
# Match upstream production image defaults (paperclipai/paperclip Dockerfile) so
# agent tooling, OpenCode, and config paths behave the same in containers.
ENV HOME=/paperclip \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
    OPENCODE_ALLOW_ALL_MODELS=true

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    ripgrep \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

# Install Hermes Agent — required by the hermes_local adapter which spawns
# hermes as a child process to execute agent tasks.
RUN pip install --quiet hermes-agent

WORKDIR /app
COPY --from=paperclip-build /paperclip /app

WORKDIR /wrapper
COPY package.json /wrapper/package.json
RUN npm install --omit=dev && npm cache clean --force
COPY src /wrapper/src
COPY scripts/entrypoint.sh /wrapper/entrypoint.sh
COPY scripts/bootstrap-ceo.mjs /wrapper/template/bootstrap-ceo.mjs
RUN chmod +x /wrapper/entrypoint.sh

# Optional local adapters/tools parity with upstream Dockerfile.
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai
RUN npm install --global --omit=dev tsx
RUN mkdir -p /paperclip \
    && chown -R node:node /app /paperclip /wrapper

# Railway sets PORT at runtime and this process binds to it.
# Entrypoint runs as root, fixes /paperclip volume permissions, then execs as node.
EXPOSE 3100
ENTRYPOINT ["/wrapper/entrypoint.sh"]
CMD ["node", "/wrapper/src/server.js"]
