# ══════════════════════════════════════════════════════════════════════════════
# Khidmeti API — Multi-stage Dockerfile
#
# STAGES :
#   base        → image Alpine épinglée, non-root user, workdir
#   deps        → node_modules (layer caché si package.json stable)
#   builder     → compilation TypeScript → dist/
#   development → hot-reload via nest start --watch
#   production  → image minimale, dist/ + prod deps, non-root
#
# STRATÉGIE VOLUME OLLAMA :
#   Ce Dockerfile ne touche PAS à Ollama.
#   L'API communique via HTTP (OLLAMA_BASE_URL=http://ollama:11434).
#   Le modèle gemma4 réside dans le volume `khidmeti-ollama-data`,
#   indépendant de ce build → `make rebuild` ne retélécharge jamais le modèle.
#
# UTILISATION :
#   Development  → docker compose up (target: development, volumes montés)
#   Production   → docker compose -f docker-compose.prod.yml up (target: production)
#   Build seul   → DOCKER_BUILDKIT=1 docker build --target production .
# ══════════════════════════════════════════════════════════════════════════════

# ── Version Node.js épinglée ──────────────────────────────────────────────────
# Surcharger via : docker build --build-arg NODE_VERSION=22.14-alpine3.21 .
ARG NODE_VERSION=20.19-alpine3.21

# ══════════════════════════════════════════════════════════════════════════════
# Stage 0 : base — fondation commune à tous les stages
# ══════════════════════════════════════════════════════════════════════════════
FROM node:${NODE_VERSION} AS base

# Métadonnées OCI (visibles via `docker inspect`)
LABEL org.opencontainers.image.title="Khidmeti API"
LABEL org.opencontainers.image.description="NestJS backend — plateforme services à domicile Algérie"

WORKDIR /app

# Sécurité : l'utilisateur `node` (uid=1000) est fourni par node:alpine.
# Transférer la propriété du workdir avant de switcher.
RUN chown node:node /app

USER node

# ══════════════════════════════════════════════════════════════════════════════
# Stage 1 : deps — installation des dépendances (layer le plus lent → le plus caché)
#
# STRATÉGIE CACHE :
#   Seul package.json est copié → ce layer est invalidé UNIQUEMENT si les
#   dépendances changent, pas si le code source change.
#   Un `git commit` typique (modification de src/) ne retrigger PAS npm install.
# ══════════════════════════════════════════════════════════════════════════════
FROM base AS deps

# Copier uniquement le manifeste — le lock file est généré ici
COPY --chown=node:node package.json ./

# --legacy-peer-deps : résout le conflit déclaré-mais-compatible entre
#   eslint@9 et @typescript-eslint@7 sans downgrader l'un ou l'autre.
# --ignore-scripts : désactive les postinstall scripts (sécurité)
# Note : si package-lock.json est commité, remplacer `npm install` par `npm ci`
RUN npm install --legacy-peer-deps --ignore-scripts

# ══════════════════════════════════════════════════════════════════════════════
# Stage 2 : builder — compilation TypeScript → dist/
# ══════════════════════════════════════════════════════════════════════════════
FROM deps AS builder

# Copier les sources APRÈS node_modules → cache préservé si seul src/ change
COPY --chown=node:node . .

# nest build :
#   - Appelle tsc via @nestjs/cli
#   - Le plugin @nestjs/swagger (nest-cli.json) enrichit les types API docs
#   - Génère dist/ avec source maps et décorateurs résolus
RUN npm run build

# ══════════════════════════════════════════════════════════════════════════════
# Stage 3 : development — hot-reload, source maps, ts-node
#
# Utilisé par docker-compose.yml (target: development).
# Les sources sont montées en volume depuis l'hôte :
#   ./apps/api/src:/app/src:ro
# → Toute modification de .ts est détectée par nest start --watch
# ══════════════════════════════════════════════════════════════════════════════
FROM deps AS development

ENV NODE_ENV=development
# V8 heap limité à 400 MB (conteneur limité à 512 MB dans docker-compose)
ENV NODE_OPTIONS="--max-old-space-size=400"

# Copier les sources pour le cas où le volume n'est pas monté
COPY --chown=node:node . .

EXPOSE 3000

# HEALTHCHECK : Docker marque le conteneur "healthy" seulement après 200.
# Les services depends_on: condition: service_healthy attendent cet état.
# wget est préféré à curl (disponible sur Alpine sans installation supplémentaire)
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["npm", "run", "start:dev"]

# ══════════════════════════════════════════════════════════════════════════════
# Stage 4 : production — image minimale, sécurisée, sans devDeps
#
# Ce stage repart de l'image base (pas de deps), installe uniquement les
# dépendances de production, et copie uniquement dist/ depuis le builder.
# Résultat : image ~180 MB au lieu de ~600 MB avec devDeps.
# ══════════════════════════════════════════════════════════════════════════════
FROM node:${NODE_VERSION} AS production

ARG NODE_VERSION=20.19-alpine3.21

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV NODE_OPTIONS="--max-old-space-size=400"

# Mettre à jour les paquets Alpine (correctifs CVE) au moment du build
# rm -rf /var/cache/apk/* → réduit la taille de l'image
RUN apk update && apk upgrade --no-cache && rm -rf /var/cache/apk/*

RUN chown node:node /app
USER node

# Copier uniquement le manifeste pour l'install de prod
COPY --chown=node:node package.json ./

# --omit=dev : exclut eslint, typescript, jest, @nestjs/cli, etc.
# --ignore-scripts : aucun script postinstall potentiellement dangereux
# npm cache clean --force : réduit la taille de l'image finale (~30 MB)
RUN npm install --omit=dev --legacy-peer-deps --ignore-scripts \
 && npm cache clean --force

# Copier UNIQUEMENT le code compilé depuis le builder (pas les .ts sources)
COPY --from=builder --chown=node:node /app/dist ./dist

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

# exec form (sans shell) → PID 1 = node → SIGTERM/SIGINT gérés correctement
# Sans exec form : PID 1 = sh → node ne reçoit pas les signaux → shutdown brutal
CMD ["node", "dist/main"]
