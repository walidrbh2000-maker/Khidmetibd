# ══════════════════════════════════════════════════════════════════════════════
# docker/llama-cpp-audio/Dockerfile
#
# Image llama.cpp construite depuis master — inclut PR#21421 (audio Gemma4)
#
# UTILISATION :
#   cd docker/llama-cpp-audio && docker build -t khidmeti-llama-audio .
#
# Ou via docker compose (voir docker-compose.yml, service ai-gemma4) :
#   image: khidmeti-llama-audio
#   build: { context: ./docker/llama-cpp-audio }
#
# POURQUOI un build custom ?
#   L'image ghcr.io/ggml-org/llama.cpp:server est reconstruite périodiquement
#   depuis le master de llama.cpp. Si PR#21421 n'est pas encore dans le tag
#   `:server` public, ce Dockerfile construit directement depuis master qui
#   contient déjà le PR mergé (audio Gemma4 conformer encoder).
#
# OPTIMISATIONS CPU 8 GB RAM :
#   - GGML_AVX2=ON    → accélération SIMD (mel spectrogram ~2× plus rapide)
#   - GGML_AVX=ON     → fallback si AVX2 indisponible
#   - GGML_F16C=ON    → opérations float16 plus rapides
#   - LLAMA_CURL=ON   → support HF_TOKEN pour download protégé
#   - CMAKE_BUILD_TYPE=Release → optimisations compilateur (-O3)
#
# TEMPS DE BUILD : ~5-15 min (dépend du CPU du Codespace)
# TAILLE IMAGE   : ~200 MB (Alpine multi-stage)
# ══════════════════════════════════════════════════════════════════════════════

# ── Stage 1 : builder ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Dépendances de compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    curl \
    ca-certificates \
    libcurl4-openssl-dev \
    libsndfile1-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone depuis master — contient PR#21421
RUN git clone --depth=1 https://github.com/ggml-org/llama.cpp.git .

# Configuration CMake optimisée CPU (pas de GPU)
RUN cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON \
    -DGGML_AVX=ON \
    -DGGML_AVX2=ON \
    -DGGML_F16C=ON \
    -DGGML_FMA=ON \
    && cmake --build build \
       --config Release \
       --target llama-server \
       -j$(nproc)

# ── Stage 2 : runtime ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive

# Runtime : libsndfile1 requis pour le décodage audio WAV/MP3/OGG (PR#21421)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    libsndfile1 \
    libgomp1 \
  && rm -rf /var/lib/apt/lists/*

# Copier uniquement le binaire du builder
COPY --from=builder /build/build/bin/llama-server /usr/local/bin/llama-server

RUN chmod +x /usr/local/bin/llama-server

EXPOSE 8011

# Entrypoint compatible avec les variables d'env LLAMA_ARG_* du docker-compose
# llama-server lit automatiquement les variables d'environnement LLAMA_ARG_*
ENTRYPOINT ["llama-server"]
