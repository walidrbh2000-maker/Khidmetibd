## ══════════════════════════════════════════════════════════════════════════════
## KHIDMETI BACKEND — Makefile v12.0
##
## FIX v12.0 :
##   - _ensure-models : téléchargement délégué à llama.cpp:server (LLAMA_ARG_HF_REPO)
##   - download-vision : nouveau repo ggml-org/moondream2-20250414-GGUF
##   - ai-status / health : noms de fichiers mis à jour (Q4_K_M auto-sélectionné)
##   - Makefile header : architecture modèles mise à jour
##
## Téléchargement automatique et intelligent de tous les modèles IA :
##   make start          → vérifie dirs, démarre tout (modèles téléchargés par llama.cpp)
##   make models         → vérifie l'état des répertoires modèles
##   make download-whisper → télécharge Whisper depuis l'HÔTE (Codespaces)
##   make download-vision  → télécharge moondream2 depuis l'HÔTE (Codespaces)
##
## Architecture modèles (v12) :
##   docker/models/text/    [cache llama.cpp — Qwen3-0.6B-Q4_K_M via HF_REPO]
##   docker/models/vision/  [cache llama.cpp — moondream2 via HF_REPO]
##   docker/models/audio/   [cache HuggingFace Whisper]   (~800 MB)
## ══════════════════════════════════════════════════════════════════════════════

SHELL := /bin/bash

# ── Détection OS / Arch ───────────────────────────────────────────────────────
OS   := $(shell uname -s 2>/dev/null || echo Windows_NT)
ARCH := $(shell uname -m 2>/dev/null || echo unknown)

ifeq ($(OS),Darwin)
  OPEN_CMD := open
else ifeq ($(OS),Windows_NT)
  OPEN_CMD := start
else
  OPEN_CMD := $(shell command -v xdg-open 2>/dev/null || echo "echo ")
endif

SED_I := $(shell \
  if sed --version 2>/dev/null | grep -q GNU; then echo "sed -i"; \
  else echo "sed -i ''"; fi)

LOCAL_IP := $(shell \
  ip route get 1 2>/dev/null | awk '{print $$7; exit}' || \
  ifconfig 2>/dev/null | awk '/inet /{print $$2}' | grep -v 127.0.0.1 | head -1 || \
  hostname -I 2>/dev/null | awk '{print $$1}' || \
  echo "127.0.0.1")

HOST     := $(shell hostname)
DATETIME := $(shell date +%Y%m%d-%H%M%S)
ARGS     ?=

# Modèle Whisper (lu depuis .env, avec fallback)
WHISPER_MODEL_ID := $(shell \
  grep '^WHISPER_MODEL=' .env 2>/dev/null | cut -d= -f2 | tr -d ' "' \
  || echo "Systran/faster-whisper-large-v3-turbo")

.DEFAULT_GOAL := help

.PHONY: help start stop restart models \
        _ensure-env _ensure-dirs _ensure-models \
        download-whisper download-vision \
        build rebuild logs logs-api logs-mongo logs-redis \
        logs-qdrant logs-minio logs-nginx logs-mongo-ui \
        logs-ai-text logs-ai-audio logs-ai-vision \
        health status ai-status dns \
        minio-buckets minio-console minio-list \
        test-api test-ai test-ai-vision test-ai-audio \
        firewall backup restore \
        shell-api shell-mongo shell-redis shell-minio shell-qdrant \
        mongo-stats redis-info redis-flush clean-logs clean \
        prod-start prod-update \
        tunnel-quick tunnel-stop tunnel-status \
        flutter-run ngrok ngrok-reset \
        scripts scripts-migrations scripts-seeds

help:
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  KHIDMETI v12.0 — كل شيء بأمر واحد"
	@echo "  OS : $(OS) | IP : $(LOCAL_IP)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "  make start          ← COMMANDE PRINCIPALE (tout automatique)"
	@echo "  make models         ← Vérifier l'état des répertoires modèles"
	@echo ""
	@echo "  [Quotidien]"
	@echo "  make stop           Arrêter"
	@echo "  make restart        Redémarrer"
	@echo "  make health         État des services"
	@echo "  make ai-status      État IA + modèles sur disque"
	@echo "  make logs           Tous les logs"
	@echo "  make dns            URLs + Flutter config"
	@echo ""
	@echo "  [Modèles IA]"
	@echo "  make models              Vérifier l'état des répertoires modèles"
	@echo "  make download-whisper    Télécharger Whisper depuis l'hôte (Codespaces)"
	@echo "  make download-vision     Télécharger moondream2 depuis l'hôte (Codespaces)"
	@echo ""
	@echo "  [Suivi 1er démarrage — téléchargement en cours]"
	@echo "  make logs-ai-text   Qwen3   (~500 MB, ~2-5 min)"
	@echo "  make logs-ai-vision moondream2 (~1.8 GB, ~10-20 min)"
	@echo "  make logs-ai-audio  Whisper (~800 MB, ~5-15 min)"
	@echo ""
	@echo "  [Tests IA]"
	@echo "  make test-ai        Darija → JSON"
	@echo "  make test-ai-audio  Santé Whisper"
	@echo "  make test-ai-vision Santé moondream2"
	@echo ""
	@echo "  [Tunnel]"
	@echo "  make ngrok          Tunnel permanent (auto-installe si absent)"
	@echo "  make tunnel-quick   Cloudflare Quick Tunnel"
	@echo ""
	@echo "  [Scripts]"
	@echo "  make scripts        Migrations + Seeds"
	@echo "  make backup         Sauvegarder MongoDB"
	@echo ""
	@echo "  [Nettoyage]"
	@echo "  make clean          Volumes Docker (modèles intacts)"
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
# _ensure-dirs : crée les dossiers de travail et les répertoires modèles
# ──────────────────────────────────────────────────────────────────────────────
_ensure-dirs:
	@mkdir -p logs backups/mongodb
	@mkdir -p docker/models/text docker/models/audio docker/models/vision

# ──────────────────────────────────────────────────────────────────────────────
# _ensure-env : crée .env depuis .env.example si absent
# ──────────────────────────────────────────────────────────────────────────────
_ensure-env:
	@if [ ! -f .env ]; then \
	  if [ -f .env.example ]; then \
	    cp .env.example .env; \
	    echo "  ⚠️  .env créé depuis .env.example → remplissez FIREBASE_* dans .env"; \
	    echo ""; \
	  else \
	    echo "  ⚠️  .env absent — créez-le manuellement"; \
	  fi; \
	fi

# ──────────────────────────────────────────────────────────────────────────────
# _ensure-models : crée les répertoires, les téléchargements sont gérés
#                 nativement par llama.cpp:server via LLAMA_ARG_HF_REPO
#
# AVANT (v11.x) : curl → HuggingFace échouait dans Codespaces (HTML au lieu de GGUF)
# APRÈS (v12)   : llama.cpp télécharge au démarrage avec HF_TOKEN → plus robuste
#
# Suivi du premier démarrage (téléchargement en cours) :
#   make logs-ai-text    → Qwen3   (~500 MB, ~2-5 min)
#   make logs-ai-vision  → moondream2 (~1.8 GB, ~10-20 min)
# ──────────────────────────────────────────────────────────────────────────────
_ensure-models: _ensure-dirs
	@echo ""
	@echo "  ✅ Répertoires modèles prêts"
	@echo "     Téléchargement géré par llama.cpp:server au 1er démarrage"
	@echo "     via LLAMA_ARG_HF_REPO + HF_TOKEN (.env)"
	@echo ""
	@_whisper_size=$$(du -sm docker/models/audio 2>/dev/null | cut -f1); \
	if [ "$${_whisper_size:-0}" -gt 100 ]; then \
	  echo "  ✅ [audio]  Whisper en cache ($$(du -sh docker/models/audio | cut -f1))"; \
	else \
	  echo "  ⏳ [audio]  Whisper → téléchargé au 1er démarrage ai-audio (~800 MB)"; \
	  echo "             ou : make download-whisper  (si container sans internet)"; \
	fi
	@echo ""

# ── Alias public ──────────────────────────────────────────────────────────────
models: _ensure-models

# ══════════════════════════════════════════════════════════════════════════════
# download-whisper : télécharge Whisper depuis l'HÔTE (contourne les
#                   restrictions réseau des containers Codespaces)
#
# POURQUOI cela fonctionne :
#   L'hôte Codespaces a toujours accès à internet, même quand le container
#   Docker reçoit un 401 ou une restriction réseau sur huggingface.co.
#
# STRATÉGIE :
#   On utilise huggingface_hub Python avec HF_HOME pointant vers
#   docker/models/audio/, qui est monté en volume dans le container ai-audio :
#     ./docker/models/audio → /root/.cache/huggingface
#   Le container trouve donc les fichiers au prochain démarrage.
# ══════════════════════════════════════════════════════════════════════════════
download-whisper: _ensure-dirs
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Téléchargement Whisper depuis l'hôte"
	@echo "  Modèle : $(WHISPER_MODEL_ID)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@_dir_size=$$(du -sm docker/models/audio 2>/dev/null | cut -f1); \
	_cached=$$(find docker/models/audio -name "*.bin" -o -name "model.safetensors" \
	  2>/dev/null | head -1); \
	if [ -n "$$_cached" ] || [ "$${_dir_size:-0}" -gt 100 ]; then \
	  echo "  ✅ Whisper déjà en cache ($$(du -sh docker/models/audio | cut -f1))"; \
	  echo "  → make restart  pour relancer le container avec le modèle"; \
	  echo ""; \
	  exit 0; \
	fi
	@if ! command -v python3 &>/dev/null; then \
	  echo "  ❌ python3 requis (sudo apt install python3)"; \
	  exit 1; \
	fi
	@echo "  🐍 Python : $$(python3 --version)"
	@echo "  📦 Vérification huggingface_hub..."
	@python3 -c "import huggingface_hub" 2>/dev/null \
	  || pip3 install -q huggingface_hub --break-system-packages 2>/dev/null \
	  || pip3 install -q huggingface_hub 2>/dev/null \
	  || python3 -m pip install -q huggingface_hub 2>/dev/null \
	  || { echo "  ❌ Impossible d'installer huggingface_hub"; exit 1; }
	@echo "  ✅ huggingface_hub disponible"
	@echo ""
	@echo "  📥 Téléchargement $(WHISPER_MODEL_ID)..."
	@echo "     Taille : ~800 MB — durée : 5-15 min selon connexion"
	@echo "     Destination : docker/models/audio/ (cache HuggingFace)"
	@echo ""
	@_WHISPER_MODEL="$(WHISPER_MODEL_ID)" HF_HOME="$(PWD)/docker/models/audio" \
	  python3 scripts/download_whisper.py
	@echo ""
	@echo "  ✅ Whisper en cache → $$(du -sh docker/models/audio | cut -f1)"
	@echo ""
	@echo "  Prochaine étape : make restart"
	@echo ""

# ══════════════════════════════════════════════════════════════════════════════
# download-vision : télécharge moondream2 depuis l'HÔTE (contourne les
#                  restrictions réseau des containers Codespaces)
#
# FIX v12.0 :
#   Repo mis à jour : ggml-org/moondream2-20250414-GGUF
#   → vikhyatk/moondream2 ne contient PAS moondream2-text-Q8_0.gguf (404)
#   → ggml-org est le repo officiel llama.cpp-compatible avec chat_template
#   → HF_TOKEN injecté automatiquement depuis .env
#
# FICHIERS (sélectionnés automatiquement par le script) :
#   moondream2-*-Q4_K_M.gguf  (~1.4 GB)  — modèle texte
#   mmproj-*-f16.gguf         (~100 MB)  — projecteur multimodal
# ══════════════════════════════════════════════════════════════════════════════
download-vision: _ensure-dirs
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Téléchargement moondream2 depuis l'hôte"
	@echo "  Dépôt : ggml-org/moondream2-20250414-GGUF"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@_vision_size=$$(du -sm docker/models/vision 2>/dev/null | cut -f1); \
	_cached=$$(find docker/models/vision -name "*.gguf" -size +100M 2>/dev/null | head -1); \
	if [ -n "$$_cached" ] && [ "$${_vision_size:-0}" -gt 1000 ]; then \
	  echo "  ✅ moondream2 déjà en cache ($$(du -sh docker/models/vision | cut -f1))"; \
	  echo "  → make restart  pour relancer le container ai-vision"; \
	  echo ""; \
	  exit 0; \
	fi
	@if ! command -v python3 &>/dev/null; then \
	  echo "  ❌ python3 requis (sudo apt install python3)"; \
	  exit 1; \
	fi
	@echo "  🐍 Python : $$(python3 --version)"
	@echo "  📦 Vérification huggingface_hub..."
	@python3 -c "import huggingface_hub" 2>/dev/null \
	  || pip3 install -q huggingface_hub --break-system-packages 2>/dev/null \
	  || pip3 install -q huggingface_hub 2>/dev/null \
	  || python3 -m pip install -q huggingface_hub 2>/dev/null \
	  || { echo "  ❌ Impossible d'installer huggingface_hub"; exit 1; }
	@echo "  ✅ huggingface_hub disponible"
	@echo ""
	@echo "  📥 Téléchargement des modèles vision..."
	@echo "     moondream2 Q4_K_M  : ~1.4 GB"
	@echo "     mmproj f16         : ~100 MB"
	@echo "     Durée estimée      : 10-30 min selon connexion"
	@echo "     Destination        : docker/models/vision/"
	@echo ""
	@HF_HOME="$(PWD)/docker/models/vision" \
	  _VISION_DEST="$(PWD)/docker/models/vision" \
	  HF_TOKEN="$$(grep '^HF_TOKEN=' .env 2>/dev/null | cut -d= -f2 | tr -d ' "')" \
	  python3 scripts/download_vision.py
	@echo ""
	@echo "  ✅ Vision en cache → $$(du -sh docker/models/vision | cut -f1)"
	@echo ""
	@echo "  Prochaine étape : make restart"
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## START — Commande principale tout-en-un
## ══════════════════════════════════════════════════════════════════════════════

start: _ensure-dirs _ensure-env _ensure-models
	@echo "══════════════════════════════════════════════════════"
	@echo "  Démarrage Khidmeti v12.0 — llama.cpp:server direct"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "  🚀 Démarrage des containers..."
	@docker compose up -d
	@echo ""
	@echo "  ⏳ Attente ai-text (Qwen3, 1er démarrage = téléchargement ~500 MB)..."
	@echo "     Suivi : make logs-ai-text"
	@READY=0; \
	for i in $$(seq 1 90); do \
	  if curl -sf http://localhost:8011/health > /dev/null 2>&1; then \
	    READY=1; break; \
	  fi; \
	  printf "."; sleep 5; \
	done; \
	echo ""; \
	if [ "$$READY" -eq 1 ]; then \
	  echo "  ✅ ai-text prêt !"; \
	else \
	  echo "  ⚠️  ai-text non prêt → make logs-ai-text"; \
	fi
	@echo ""
	@$(MAKE) --no-print-directory health
	@echo ""
	@$(MAKE) --no-print-directory dns

stop:
	@docker compose down
	@echo ""
	@echo "  ✅ Services arrêtés. Modèles dans docker/models/ — intacts."
	@echo ""

restart: stop
	@sleep 2
	@$(MAKE) start

build:
	@docker compose build --no-cache api
	@echo "✅ Build terminé."

rebuild: build
	@$(MAKE) start

## ══════════════════════════════════════════════════════════════════════════════
## LOGS
## ══════════════════════════════════════════════════════════════════════════════

logs:
	@docker compose logs --tail=100 -f

logs-api:
	@docker compose logs -f api

logs-mongo:
	@docker compose logs -f mongo

logs-mongo-ui:
	@docker compose logs -f mongo-express

logs-redis:
	@docker compose logs -f redis

logs-qdrant:
	@docker compose logs -f qdrant

logs-minio:
	@docker compose logs -f minio

logs-nginx:
	@docker compose logs -f nginx

logs-ai-text:
	@docker compose logs -f ai-text

logs-ai-audio:
	@docker compose logs -f ai-audio

logs-ai-vision:
	@docker compose logs -f ai-vision 2>/dev/null \
	  || echo "  ai-vision non activé (commenté dans docker-compose.yml)"

## ══════════════════════════════════════════════════════════════════════════════
## DIAGNOSTIC
## ══════════════════════════════════════════════════════════════════════════════

health:
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  État des services Khidmeti v12.0"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@_c() { \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" "$$2" 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "  ✅ $$1" || echo "  ❌ $$1 ($$code)"; \
	}; \
	_c "NestJS  :3000 " "http://localhost:3000/health"; \
	_c "nginx   :80   " "http://localhost/health"; \
	_c "Qdrant  :6333 " "http://localhost:6333/healthz"; \
	_c "MinIO   :9001 " "http://localhost:9001/minio/health/live"; \
	code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8011/health 2>/dev/null); \
	[ "$$code" = "200" ] \
	  && echo "  ✅ ai-text :8011 (Qwen3)" \
	  || echo "  ⏳ ai-text :8011 (téléchargement en cours → make logs-ai-text)"; \
	code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null); \
	[ "$$code" = "200" ] \
	  && echo "  ✅ ai-audio:8000 (Whisper large-v3-turbo)" \
	  || echo "  ⏳ ai-audio:8000 (1er démarrage = téléchargement Whisper ~800 MB)"; \
	code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8012/health 2>/dev/null); \
	[ "$$code" = "200" ] \
	  && echo "  ✅ ai-vision:8012 (moondream2)" \
	  || echo "  ⏳ ai-vision:8012 (téléchargement en cours → make logs-ai-vision)";
	@echo -n "  "; \
	  docker exec khidmeti-mongo mongosh --quiet \
	    --eval "db.adminCommand('ping').ok" >/dev/null 2>&1 \
	  && echo "✅ MongoDB  :27017" || echo "❌ MongoDB  :27017"
	@echo -n "  "; \
	  RP=$$(grep REDIS_PASSWORD .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]'); \
	  docker exec khidmeti-redis redis-cli -a "$$RP" ping >/dev/null 2>&1 \
	  && echo "✅ Redis    :6379" || echo "❌ Redis    :6379"
	@echo ""

ai-status:
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Statut IA v12.0 — llama.cpp:server direct"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "  Services :"
	@code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8011/health 2>/dev/null); \
	[ "$$code" = "200" ] && echo "  ✅ ai-text  :8011  (Qwen3-0.6B)" \
	                     || echo "  ⏳ ai-text  :8011  (téléchargement → make logs-ai-text)"
	@code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null); \
	[ "$$code" = "200" ] && echo "  ✅ ai-audio :8000  (Whisper large-v3-turbo)" \
	                     || echo "  ⏳ ai-audio :8000  (démarrage ou modèle absent)"
	@code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8012/health 2>/dev/null); \
	[ "$$code" = "200" ] && echo "  ✅ ai-vision:8012  (moondream2)" \
	                     || echo "  ⏳ ai-vision:8012  (téléchargement → make logs-ai-vision)"
	@echo ""
	@echo "  Modèles sur disque :"
	@_text_size=$$(du -sm docker/models/text 2>/dev/null | cut -f1); \
	if [ "$${_text_size:-0}" -gt 100 ]; then \
	  echo "  ✅ text/   Qwen3-0.6B cache   ($$(du -sh docker/models/text | cut -f1))"; \
	else \
	  echo "  ⏳ text/   Qwen3-0.6B         → téléchargé au 1er démarrage ai-text"; \
	fi
	@_vis_size=$$(du -sm docker/models/vision 2>/dev/null | cut -f1); \
	if [ "$${_vis_size:-0}" -gt 1000 ]; then \
	  echo "  ✅ vision/ moondream2 cache   ($$(du -sh docker/models/vision | cut -f1))"; \
	else \
	  echo "  ⏳ vision/ moondream2         → téléchargé au 1er démarrage ai-vision"; \
	  echo "            ou : make download-vision  (si container sans internet)"; \
	fi
	@_whisper_size=$$(du -sm docker/models/audio 2>/dev/null | cut -f1); \
	if [ "$${_whisper_size:-0}" -gt 100 ]; then \
	  echo "  ✅ audio/  Whisper turbo $$(du -sh docker/models/audio | cut -f1)"; \
	else \
	  echo "  ⏳ audio/  Whisper turbo → téléchargé au 1er démarrage ai-audio"; \
	  echo "             ou : make download-whisper  (si container sans internet)"; \
	fi
	@echo ""
	@free -h 2>/dev/null | awk '/^Mem:/{print "  RAM — Total: " $$2 "  Libre: " $$4}' \
	  || echo "  (info RAM non disponible)"
	@echo ""

status:
	@echo ""
	@docker ps -a --filter "name=khidmeti" \
	  --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@docker stats --no-stream \
	  --format "  {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null \
	  | grep khidmeti | sort || true
	@echo ""

dns:
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  URLs  [$(HOST)]"
	@echo "══════════════════════════════════════════════════════"
	@echo "  API     : http://$(HOST):3000"
	@echo "  nginx   : http://$(HOST):80"
	@echo "  Swagger : http://$(HOST):3000/api/docs"
	@echo "  Mongo   : http://$(HOST):8081"
	@echo "  Qdrant  : http://$(HOST):6333/dashboard"
	@echo "  MinIO   : http://$(HOST):9002"
	@echo "  ai-text : http://$(HOST):8011"
	@echo "  ai-audio: http://$(HOST):8000"
	@echo "  ai-vis  : http://$(HOST):8012"
	@echo ""
	@echo "  ── Flutter ──────────────────────────────────────────"
	@echo "  flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80"
	@NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "'); \
	if [ -n "$$NGROK_DOMAIN" ]; then \
	  echo ""; \
	  echo "  ngrok   : https://$$NGROK_DOMAIN"; \
	  echo "  flutter run --dart-define=API_BASE_URL=https://$$NGROK_DOMAIN"; \
	fi
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## TESTS IA
## ══════════════════════════════════════════════════════════════════════════════

test-ai:
	@echo ""
	@echo "  Test Qwen3 — Darija → JSON..."
	@curl -s http://localhost:8011/v1/chat/completions \
	  -H "Content-Type: application/json" \
	  -d '{"model":"qwen3-0.6b-q4_k_m","messages":[{"role":"system","content":"Réponds UNIQUEMENT en JSON: {\"profession\":null,\"is_urgent\":false,\"problem_description\":\"\",\"confidence\":0}"},{"role":"user","content":"عندي ماء ساقط من السقف"}],"temperature":0.05,"max_tokens":256,"stream":false}' \
	  | python3 -m json.tool 2>/dev/null \
	  || echo "  ❌ ai-text non disponible → make logs-ai-text"
	@echo ""

test-ai-audio:
	@echo ""
	@echo "  Test Whisper — santé..."
	@curl -s http://localhost:8000/health | python3 -m json.tool 2>/dev/null \
	  || echo "  ⏳ ai-audio en démarrage → make logs-ai-audio"
	@echo ""

test-ai-vision:
	@echo ""
	@echo "  Test moondream2 — santé..."
	@curl -sf http://localhost:8012/health > /dev/null 2>&1 \
	  && echo "  ✅ ai-vision :8012 opérationnel" \
	  || echo "  ❌ ai-vision non disponible → make logs-ai-vision"
	@echo ""

test-api:
	@echo ""
	@echo "  Health  :"; curl -s http://localhost:3000/health
	@echo ""
	@echo "  Swagger :"; curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:3000/api/docs
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## NGROK — Auto-installe ngrok si absent
## ══════════════════════════════════════════════════════════════════════════════

ngrok:
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Tunnel ngrok — Domaine permanent"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@if ! command -v ngrok &>/dev/null; then \
	  echo "  ngrok absent — installation automatique..."; \
	  if [ -f /etc/debian_version ] || grep -qi ubuntu /etc/os-release 2>/dev/null; then \
	    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
	      | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null 2>&1; \
	    echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
	      | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null 2>&1; \
	    sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y ngrok 2>/dev/null; \
	  elif command -v brew &>/dev/null; then \
	    brew install ngrok/ngrok/ngrok; \
	  else \
	    curl -sL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz \
	      | sudo tar xz -C /usr/local/bin; \
	  fi; \
	  echo "  ✅ ngrok installé !"; \
	fi
	@NGROK_TOKEN=$$(grep '^NGROK_AUTH_TOKEN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "'); \
	if [ -z "$$NGROK_TOKEN" ]; then \
	  echo "  https://dashboard.ngrok.com/get-started/your-authtoken"; \
	  read -p "  Auth Token : " NGROK_TOKEN; \
	  grep -q '^NGROK_AUTH_TOKEN=' .env 2>/dev/null \
	    && $(SED_I) "s|^NGROK_AUTH_TOKEN=.*|NGROK_AUTH_TOKEN=$$NGROK_TOKEN|" .env \
	    || echo "NGROK_AUTH_TOKEN=$$NGROK_TOKEN" >> .env; \
	  echo "  ✅ Sauvegardé."; \
	fi; \
	ngrok config add-authtoken "$$(grep '^NGROK_AUTH_TOKEN=' .env | cut -d= -f2- | tr -d ' "')" >/dev/null 2>&1; \
	NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "'); \
	if [ -z "$$NGROK_DOMAIN" ]; then \
	  echo "  https://dashboard.ngrok.com/domains"; \
	  read -p "  Domaine statique : " NGROK_DOMAIN; \
	  grep -q '^NGROK_DOMAIN=' .env 2>/dev/null \
	    && $(SED_I) "s|^NGROK_DOMAIN=.*|NGROK_DOMAIN=$$NGROK_DOMAIN|" .env \
	    || echo "NGROK_DOMAIN=$$NGROK_DOMAIN" >> .env; \
	  echo "  ✅ Sauvegardé."; \
	fi; \
	ND=$$(grep '^NGROK_DOMAIN=' .env | cut -d= -f2- | tr -d ' "'); \
	echo "  URL : https://$$ND"; \
	echo "  flutter run --dart-define=API_BASE_URL=https://$$ND"; \
	echo "  → Ctrl+C pour arrêter"; echo ""; \
	ngrok http --domain="$$ND" 80

ngrok-reset:
	@$(SED_I) '/^NGROK_AUTH_TOKEN=/d' .env 2>/dev/null
	@$(SED_I) '/^NGROK_DOMAIN=/d' .env 2>/dev/null
	@echo "✅ Config ngrok supprimée."

tunnel-quick:
	@cloudflared tunnel --url http://localhost:80 2>/dev/null \
	  || echo "cloudflared absent : sudo apt install cloudflared"

tunnel-stop:
	@pkill -f 'cloudflared tunnel' 2>/dev/null && echo "✅" || echo "Aucun tunnel."

tunnel-status:
	@ps aux | grep 'cloudflared tunnel' | grep -v grep || echo "Aucun tunnel."

flutter-run:
	@flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80

## ══════════════════════════════════════════════════════════════════════════════
## MINIO
## ══════════════════════════════════════════════════════════════════════════════

minio-buckets:
	@MK=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MS=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run --rm --network khidmeti-network minio/mc:latest sh -c \
	  "mc alias set local http://minio:9001 $$MK $$MS && \
	   mc mb --ignore-existing local/profile-images && \
	   mc mb --ignore-existing local/service-media && \
	   mc mb --ignore-existing local/audio-recordings && \
	   mc anonymous set download local/profile-images && echo '✅ Buckets OK'"

minio-console:
	@$(OPEN_CMD) http://localhost:9002 2>/dev/null || echo "→ http://localhost:9002"

minio-list:
	@MK=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MS=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run --rm --network khidmeti-network minio/mc:latest sh -c \
	  "mc alias set local http://minio:9001 $$MK $$MS && mc ls local/profile-images; mc ls local/service-media"

## ══════════════════════════════════════════════════════════════════════════════
## SCRIPTS
## ══════════════════════════════════════════════════════════════════════════════

scripts:
	@$(MAKE) scripts-migrations
	@$(MAKE) scripts-seeds

scripts-migrations:
	@echo ""
	@echo "  Migrations MongoDB"
	@MU=$$(grep '^MONGO_ROOT_USER' .env | cut -d= -f2 | tr -d '[:space:]'); \
	MP=$$(grep '^MONGO_ROOT_PASSWORD' .env | cut -d= -f2 | tr -d '[:space:]'); \
	C=0; F=0; shopt -s nullglob; FILES=(scripts/migrations/*.js); \
	if [ $${#FILES[@]} -eq 0 ]; then echo "  ⚪ Aucune migration."; \
	else \
	  for f in "$${FILES[@]}"; do \
	    echo "  → $$(basename $$f)"; \
	    docker exec -i khidmeti-mongo mongosh --quiet \
	      -u "$$MU" -p "$$MP" --authenticationDatabase admin khidmeti < "$$f" \
	    && { echo "  ✅"; C=$$((C+1)); } || { echo "  ❌"; F=$$((F+1)); }; \
	  done; echo "  ── $$C OK | $$F échec(s)"; [ $$F -gt 0 ] && exit 1 || true; fi
	@echo ""

scripts-seeds:
	@echo ""
	@echo "  Seeds TypeScript"
	@C=0; F=0; shopt -s nullglob; FILES=(apps/api/src/scripts/seeds/*.ts); \
	if [ $${#FILES[@]} -eq 0 ]; then echo "  ⚪ Aucun seed."; \
	else \
	  for f in "$${FILES[@]}"; do \
	    N=$$(basename "$$f"); echo "  → $$N $(ARGS)"; \
	    docker exec khidmeti-api npx ts-node --project tsconfig.json \
	      "src/scripts/seeds/$$N" $(ARGS) \
	    && { echo "  ✅"; C=$$((C+1)); } || { echo "  ❌"; F=$$((F+1)); }; \
	  done; echo "  ── $$C OK | $$F échec(s)"; [ $$F -gt 0 ] && exit 1 || true; fi
	@echo ""

scripts-%:
	@NAME=$*; \
	if [ -f "scripts/migrations/$$NAME.js" ]; then \
	  MU=$$(grep '^MONGO_ROOT_USER' .env | cut -d= -f2 | tr -d '[:space:]'); \
	  MP=$$(grep '^MONGO_ROOT_PASSWORD' .env | cut -d= -f2 | tr -d '[:space:]'); \
	  docker exec -i khidmeti-mongo mongosh --quiet \
	    -u "$$MU" -p "$$MP" --authenticationDatabase admin khidmeti \
	    < "scripts/migrations/$$NAME.js" \
	  && echo "✅ $$NAME OK" || exit 1; \
	elif [ -f "apps/api/src/scripts/seeds/$$NAME.ts" ]; then \
	  docker exec khidmeti-api npx ts-node --project tsconfig.json \
	    "src/scripts/seeds/$$NAME.ts" $(ARGS) \
	  && echo "✅ $$NAME OK" || exit 1; \
	else echo "❌ Script '$$NAME' introuvable."; exit 1; fi

## ══════════════════════════════════════════════════════════════════════════════
## SAUVEGARDE
## ══════════════════════════════════════════════════════════════════════════════

backup:
	@mkdir -p backups/mongodb/$(DATETIME)
	@MU=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MP=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongodump \
	  --username "$$MU" --password "$$MP" \
	  --authenticationDatabase admin --db khidmeti \
	  --out /tmp/bkp_$(DATETIME); \
	docker cp khidmeti-mongo:/tmp/bkp_$(DATETIME) backups/mongodb/$(DATETIME)
	@echo "✅ Sauvegarde → backups/mongodb/$(DATETIME)"

restore:
	@[ -n "$(BACKUP_DATE)" ] || { echo "Usage: make restore BACKUP_DATE=..."; exit 1; }
	@MU=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MP=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker cp backups/mongodb/$(BACKUP_DATE) khidmeti-mongo:/tmp/rst; \
	docker exec khidmeti-mongo mongorestore \
	  --username "$$MU" --password "$$MP" \
	  --authenticationDatabase admin --db khidmeti --drop /tmp/rst/khidmeti
	@echo "✅ Restauration terminée."

## ══════════════════════════════════════════════════════════════════════════════
## SHELLS
## ══════════════════════════════════════════════════════════════════════════════

shell-api:
	@docker exec -it khidmeti-api /bin/sh

shell-mongo:
	@MU=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MP=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec -it khidmeti-mongo mongosh -u "$$MU" -p "$$MP" \
	  --authenticationDatabase admin khidmeti

shell-redis:
	@RP=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec -it khidmeti-redis redis-cli -a "$$RP"

shell-minio:
	@MK=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MS=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run -it --rm --network khidmeti-network minio/mc:latest \
	  sh -c "mc alias set local http://minio:9001 $$MK $$MS && sh"

shell-qdrant:
	@$(OPEN_CMD) http://localhost:6333/dashboard 2>/dev/null || echo "→ http://localhost:6333/dashboard"

mongo-stats:
	@MU=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MP=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongosh -u "$$MU" -p "$$MP" \
	  --authenticationDatabase admin khidmeti --quiet --eval "db.stats()"

redis-info:
	@RP=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-redis redis-cli -a "$$RP" INFO server

redis-flush:
	@RP=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-redis redis-cli -a "$$RP" FLUSHALL
	@echo "✅ Redis vidé."

## ══════════════════════════════════════════════════════════════════════════════
## NETTOYAGE
## ══════════════════════════════════════════════════════════════════════════════

clean-logs:
	@find logs/ -name "*.log" -delete 2>/dev/null || true
	@echo "✅ Logs nettoyés."

clean:
	@echo ""
	@echo "  ⚠️  Supprime volumes MongoDB, Redis, Qdrant, MinIO."
	@echo "  ✅ Les modèles dans docker/models/ sont CONSERVÉS."
	@echo ""
	@read -p "  Confirmer ? [y/N] " C; \
	[ "$$C" = "y" ] || [ "$$C" = "Y" ] \
	  && docker compose down -v --remove-orphans \
	  && docker system prune -f \
	  && echo "✅ Nettoyage terminé. Modèles intacts dans docker/models/" \
	  || echo "Annulé."

## ══════════════════════════════════════════════════════════════════════════════
## PRODUCTION
## ══════════════════════════════════════════════════════════════════════════════

prod-start:
	@docker compose up -d && echo "✅ Production."

prod-update:
	@docker compose build --no-cache api
	@docker compose up -d --no-deps --build api
	@echo "✅ API mise à jour."

firewall:
	@echo "sudo ufw allow 80/tcp 3000/tcp 6333/tcp 8081/tcp 9001/tcp 9002/tcp 8011/tcp 8000/tcp 8012/tcp"
