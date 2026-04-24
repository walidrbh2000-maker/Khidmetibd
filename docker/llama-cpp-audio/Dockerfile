# ══════════════════════════════════════════════════════════════════════════════
# docker/llama-cpp-audio/Dockerfile — v3
#
# FIX v3 : /bin/sh: 1: file: not found
#   Cause   : 'file' est un package séparé, absent de Ubuntu 22.04 slim
#   Solution: remplacer 'file' par 'readelf' (binutils, inclus dans build-essential)
#   Avantage: readelf est l'outil industriel standard pour inspecter les ELF binaries
#
# VÉRIFICATIONS BUILD (readelf + ldd guard) :
#   readelf -h → type ELF + architecture (équivalent de 'file' mais natif)
#   ldd guard   → confirme BUILD_SHARED_LIBS=OFF (aucune libllama.so résiduele)
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

RUN git clone --depth=1 https://github.com/ggml-org/llama.cpp.git .

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

# ── Vérification du binaire (readelf remplace 'file' — binutils déjà présent) ─
RUN ls -lh build/bin/llama-server \
 && readelf -h build/bin/llama-server | grep -E "Type:|Machine:" \
 && echo "✅ ELF binary OK" \
 && (ldd build/bin/llama-server 2>&1 | grep -q "libllama" \
     && echo "❌ ERREUR: libllama trouvée — BUILD_SHARED_LIBS=OFF a échoué" && exit 1 \
     || echo "✅ Static linking confirmé — aucune libllama.so")

# ── Stage 2 : runtime ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 \
    libgomp1 \
    libcurl4 \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/bin/llama-server /usr/local/bin/llama-server

RUN chmod +x /usr/local/bin/llama-server \
 && ldd /usr/local/bin/llama-server

EXPOSE 8011

ENTRYPOINT ["/usr/local/bin/llama-server"]
