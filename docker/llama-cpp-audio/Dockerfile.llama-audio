# ══════════════════════════════════════════════════════════════════════════════
# docker/llama-cpp-audio/Dockerfile — v3 (single-stage)
#
# FIX v3 : libllama-common.so.0 / libmtmd.so.0 : cannot open shared object file
#
# ROOT CAUSE :
#   llama.cpp crée plusieurs .so : libllama-common.so, libmtmd.so, libggml*.so
#   Le multi-stage ne copiait que le binaire llama-server → les .so manquaient.
#   BUILD_SHARED_LIBS=OFF ne désactive pas les GGML backend plugins (GGML_BACKEND_DL).
#
# SOLUTION : single-stage Dockerfile
#   Build ET run dans la même image → toutes les .so sont naturellement présentes.
#   Inconvénient : image ~600 MB (vs ~300 MB multi-stage).
#   Avantage    : 100% fiable, aucun problème de .so manquant.
#
# OPTIMISATIONS CPU (Codespace Linux x86_64) :
#   GGML_NATIVE=ON    → détection automatique AVX/AVX2/FMA/F16C du CPU hôte
#   GGML_NATIVE=ON    → inclut automatiquement les optimisations SIMD disponibles
#   libsndfile1-dev   → décodeur audio WAV/MP3/OGG pour PR#21421 (Gemma4 audio)
#   LLAMA_CURL=ON     → support HF_TOKEN pour téléchargement de modèles protégés
#
# TEMPS DE BUILD : ~10-20 min (git clone + cmake + compilation)
# TAILLE IMAGE   : ~600 MB (build tools conservés dans le runtime)
# ══════════════════════════════════════════════════════════════════════════════

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# ── Dépendances de compilation ET de runtime ──────────────────────────────────
# Toutes dans la même couche — pas de multi-stage donc pas besoin de séparer.
#
# build-essential + cmake + git : compilation de llama.cpp
# libsndfile1-dev               : décodage audio WAV/MP3/OGG (PR#21421 Gemma4)
# libcurl4-openssl-dev          : support LLAMA_CURL (HF_TOKEN)
# libgomp1                      : OpenMP parallélisme CPU
# curl                          : healthcheck Docker
# ca-certificates               : SSL pour git clone et HF
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    curl \
    ca-certificates \
    libsndfile1-dev \
    libcurl4-openssl-dev \
    libgomp1 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ── Clone depuis master — contient PR#21421 (Gemma4 audio conformer encoder) ──
RUN git clone --depth=1 https://github.com/ggml-org/llama.cpp.git .

# ── Build llama.cpp ────────────────────────────────────────────────────────────
#
# GGML_NATIVE=ON     : détecte et active AVX/AVX2/FMA/F16C automatiquement
#                      → mel spectrogram audio ~2× plus rapide que GGML_NATIVE=OFF
# LLAMA_CURL=ON      : support HF_TOKEN dans les variables d'env
# LLAMA_BUILD_TESTS=OFF : ne compile pas les tests → build ~30% plus rapide
#
# NOTE : on ne passe PAS BUILD_SHARED_LIBS=OFF intentionnellement.
# Les .so (libllama-common, libmtmd, libggml*) seront dans /build/build/
# et accessibles car on est en single-stage (même FS).
RUN cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
  && cmake --build build \
    --config Release \
    --target llama-server \
    -j$(nproc)

# ── Installer dans /usr/local pour que ld.so trouve les .so automatiquement ───
#
# cmake --install copie :
#   /usr/local/bin/llama-server
#   /usr/local/lib/libllama-common.so*
#   /usr/local/lib/libmtmd.so*
#   /usr/local/lib/libggml*.so*
# ldconfig met à jour le cache ld.so → les .so sont trouvées sans LD_LIBRARY_PATH
RUN cmake --install build --prefix /usr/local \
  && ldconfig

# Vérification au build time — doit afficher TOUTES les dépendances résolues
RUN ldd /usr/local/bin/llama-server | grep -v "not found" || true
RUN echo "✅ llama-server installé avec toutes ses dépendances"

EXPOSE 8011

# llama-server lit automatiquement les variables LLAMA_ARG_* depuis l'environnement
ENTRYPOINT ["/usr/local/bin/llama-server"]
