# ══════════════════════════════════════════════════════════════════════════════
# apps/api/Dockerfile — v14.3
#
# CHANGEMENT v14.3 vs v14.2 :
#   + ffmpeg ajouté dans le stage BASE (disponible en dev ET production)
#
# POURQUOI ffmpeg :
#   llama.cpp PR#21421 n'accepte que 'wav' et 'mp3' comme format audio.
#   iOS envoie m4a, Android peut envoyer ogg/webm/aac.
#   gemma4.strategy.ts transcodeToWav() convertit tout format → WAV 16kHz mono
#   via ffmpeg avant envoi à llama.cpp (résout erreur 400 définitivement).
#
# TAILLE IMAGE :
#   ffmpeg Alpine ≈ +30 MB sur l'image finale (libavcodec, libavformat, etc.)
#   Acceptable — ffmpeg Alpine est compilé minimal (pas de GUI, pas d'encodeurs inutiles)
#
# AUTRES STAGES :
#   Inchangés vs v14.2 (deps, builder, development, production)
# ══════════════════════════════════════════════════════════════════════════════

ARG NODE_VERSION=20.19-alpine3.21

# ══════════════════════════════════════════════════════════════════════════════
# Stage 0 : base — fondation commune à tous les stages
# ══════════════════════════════════════════════════════════════════════════════
FROM node:${NODE_VERSION} AS base

LABEL org.opencontainers.image.title="Khidmeti API"
LABEL org.opencontainers.image.description="NestJS backend — plateforme services à domicile Algérie"

# ── ffmpeg (v14.3) ────────────────────────────────────────────────────────────
# Requis par gemma4.strategy.ts transcodeToWav() pour convertir les formats
# audio non supportés par llama.cpp (m4a, ogg, webm, aac) → WAV 16kHz mono.
#
# Alpine ffmpeg inclut :
#   libavcodec  : décodeurs m4a/AAC, OGG/Vorbis, WebM/Opus, FLAC, MP3, WAV
#   libavformat : démuxers pour tous les containers audio courants
#   libswresample : resampling vers 16kHz mono PCM
#
# Pas besoin de codecs vidéo — ffmpeg Alpine est déjà minimal.
RUN apk add --no-cache ffmpeg

WORKDIR /app

RUN chown node:node /app

USER node

# ══════════════════════════════════════════════════════════════════════════════
# Stage 1 : deps — installation des dépendances
# ══════════════════════════════════════════════════════════════════════════════
FROM base AS deps

COPY --chown=node:node package.json ./

RUN npm install --legacy-peer-deps --ignore-scripts

# ══════════════════════════════════════════════════════════════════════════════
# Stage 2 : builder — compilation TypeScript → dist/
# ══════════════════════════════════════════════════════════════════════════════
FROM deps AS builder

COPY --chown=node:node . .

RUN npm run build

# ══════════════════════════════════════════════════════════════════════════════
# Stage 3 : development — hot-reload, source maps, ts-node
# ══════════════════════════════════════════════════════════════════════════════
FROM deps AS development

ENV NODE_ENV=development
ENV NODE_OPTIONS="--max-old-space-size=768"

COPY --chown=node:node . .

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["npm", "run", "start:dev"]

# ══════════════════════════════════════════════════════════════════════════════
# Stage 4 : production — image minimale, sécurisée, sans devDeps
# ══════════════════════════════════════════════════════════════════════════════
FROM node:${NODE_VERSION} AS production

ARG NODE_VERSION=20.19-alpine3.21

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV NODE_OPTIONS="--max-old-space-size=768"

# ── ffmpeg dans production aussi ──────────────────────────────────────────────
# Le stage production repart de l'image node de base (pas de `base` stage).
# ffmpeg doit être réinstallé ici pour être disponible en production.
RUN apk update && apk upgrade --no-cache \
 && apk add --no-cache ffmpeg \
 && rm -rf /var/cache/apk/*

RUN chown node:node /app
USER node

COPY --chown=node:node package.json ./

RUN npm install --omit=dev --legacy-peer-deps --ignore-scripts \
 && npm cache clean --force

COPY --from=builder --chown=node:node /app/dist ./dist

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "dist/main"]
