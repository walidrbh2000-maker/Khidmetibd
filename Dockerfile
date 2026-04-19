# ══════════════════════════════════════════════════════════════════════════════
# Khidmeti — Ollama image avec modèle intégré
#
# PROBLÈME RÉSOLU :
#   ollama/ollama:latest stocke les modèles dans /root/.ollama/models.
#   Si on monte un volume sur /root/.ollama (pour la config runtime),
#   Docker cache les fichiers de l'image → modèle invisible → re-download.
#
# SOLUTION — chemin séparé :
#   Les modèles sont baked dans /ollama/models (hors portée de tout volume).
#   Le volume runtime peut couvrir /root/.ollama sans jamais toucher les modèles.
#   OLLAMA_MODELS=/ollama/models indique à Ollama où les trouver.
#
# USAGE :
#   Build :   docker compose build ollama
#   Rebuild : docker compose build --no-cache ollama
#   Changer de modèle : modifier ARG OLLAMA_MODEL, rebuild.
#
# TAILLE IMAGE :
#   ollama/ollama:latest  ~1.0 GB
#   + gemma4:e2b          ~7.2 GB
#   ─────────────────────────────
#   Total                 ~8.2 GB  (stocké dans le layer cache Docker)
# ══════════════════════════════════════════════════════════════════════════════

FROM ollama/ollama:latest

# Modèle à intégrer — doit correspondre à OLLAMA_MODEL dans .env
ARG OLLAMA_MODEL=gemma4:e2b

# ── Chemin dédié aux modèles baked (hors portée des volumes) ─────────────────
#
# /ollama/models est un chemin "neutre" :
#   • Aucun volume ne sera jamais monté dessus
#   • Ollama le lit via OLLAMA_MODELS au runtime
#   • Survit à docker compose down / up (il est dans l'image, pas dans un volume)
ENV OLLAMA_MODELS=/ollama/models

RUN mkdir -p /ollama/models

# ── Pull du modèle pendant le build ──────────────────────────────────────────
#
# Ordre des opérations :
#   1. Démarrer ollama serve en arrière-plan (nécessaire pour ollama pull)
#   2. Attendre qu'il soit prêt (poll /api/tags)
#   3. Tirer le modèle — stocké dans OLLAMA_MODELS=/ollama/models
#   4. Arrêter proprement le serveur
#
# Le résultat est committé dans un layer Docker → permanent dans l'image.
# ─────────────────────────────────────────────────────────────────────────────
RUN ollama serve & \
    OLLAMA_PID=$! && \
    echo "⏳ Attente démarrage Ollama..." && \
    for i in $(seq 1 30); do \
      curl -sf http://localhost:11434/api/tags > /dev/null 2>&1 && break; \
      sleep 1; \
    done && \
    echo "📥 Pull ${OLLAMA_MODEL}..." && \
    ollama pull ${OLLAMA_MODEL} && \
    echo "✅ Modèle téléchargé dans /ollama/models" && \
    kill $OLLAMA_PID && \
    wait $OLLAMA_PID 2>/dev/null || true

EXPOSE 11434

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
