# ══════════════════════════════════════════════════════════════════════════════
# docker/llama-cpp-audio/Dockerfile — v2
#
# FIX v2 : libllama-common.so.0: cannot open shared object file
#   Cause   : multi-stage avec dynamic linking → shared libs non copiées
#   Solution: BUILD_SHARED_LIBS=OFF → static linking → binaire autonome
#
# AVANTAGE static linking :
#   - Binaire 100% autonome (aucune dépendance .so à copier)
#   - Fonctionne sur n'importe quelle Ubuntu 22.04 (même libc)
#   - libsndfile conservé en dynamique (seul requis pour l'audio)
#
# OPTIMISATIONS CPU :
#   AVX2 + F16C + FMA → mel spectrogram audio ~2× plus rapide sur CPU moderne
#
# TEMPS DE BUILD : ~10-20 min (git clone + cmake complet)
# TAILLE IMAGE   : ~300 MB (binaire statique + libsndfile)
# ══════════════════════════════════════════════════════════════════════════════

# ── Stage 1 : builder ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

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

# Clone depuis master — contient PR#21421 (Gemma4 audio conformer encoder)
RUN git clone --depth=1 https://github.com/ggml-org/llama.cpp.git .

# ── BUILD_SHARED_LIBS=OFF : static linking ────────────────────────────────────
# Évite "libllama-common.so.0: cannot open shared object file"
# Avec static linking, tout est intégré dans le binaire llama-server.
# libsndfile reste dynamique → installé dans le runtime stage
RUN cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_CURL=ON \
    -DGGML_AVX=ON \
    -DGGML_AVX2=ON \
    -DGGML_F16C=ON \
    -DGGML_FMA=ON \
  && cmake --build build \
    --config Release \
    --target llama-server \
    -j$(nproc)

RUN ls -lh build/bin/llama-server && file build/bin/llama-server

# ── Stage 2 : runtime ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive

# libsndfile1  : requis pour décoder WAV/MP3/OGG (audio PR#21421)
# libgomp1     : OpenMP pour le parallélisme CPU de llama.cpp
# libcurl4     : requis si LLAMA_CURL=ON (téléchargement modèles HF)
# ca-certificates + curl : SSL + healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 \
    libgomp1 \
    libcurl4 \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/bin/llama-server /usr/local/bin/llama-server

RUN chmod +x /usr/local/bin/llama-server

# Vérifier les dépendances dynamiques au build time
RUN ldd /usr/local/bin/llama-server

EXPOSE 8011

# llama-server lit automatiquement les variables LLAMA_ARG_* depuis l'environnement
ENTRYPOINT ["/usr/local/bin/llama-server"]
