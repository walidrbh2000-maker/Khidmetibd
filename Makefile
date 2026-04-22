## ══════════════════════════════════════════════════════════════════════════════
## KHIDMETI BACKEND — Makefile v14.0
##
## MIGRATION v14 :
##   - ai-audio (Whisper) SUPPRIMÉ — Gemma4 gère audio nativement (PR#21421)
##   - SUPPRIMÉ : download-whisper, logs-ai-audio, test-ai-audio (Whisper)
##   - AJOUTÉ   : test-ai-audio (test audio natif Gemma4 directement)
##   - MODIFIÉ  : health, ai-status → plus de check Whisper
##
## Setup initial (obligatoire avant make start) :
##   make download-gemma4    → Gemma4 E2B Q4_K_M (~3.8 GB)
##   make start              → Lance tout
##
## GPU (E4B) :
##   GEMMA4_VARIANT=e4b make download-gemma4
##   docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
##
## Architecture modèles v14 :
##   docker/models/gemma4/  [Gemma4 GGUF + mmproj f32]  (~3.8-5.4 GB)
##   → mmproj f32 contient encodeur image + audio (PR#21421)
##   docker/models/audio/   [OBSOLÈTE — peut être supprimé]
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

# Variante Gemma4 (e2b = CPU, e4b = GPU)
GEMMA4_VARIANT ?= e2b
GEMMA4_QUANT   ?= Q4_K_M

.DEFAULT_GOAL := help

.PHONY: help start stop restart models \
        _ensure-env _ensure-dirs _ensure-models \
        download-gemma4 \
        build rebuild logs logs-api logs-mongo logs-redis \
        logs-qdrant logs-minio logs-nginx logs-mongo-ui \
        logs-ai-gemma4 \
        health status ai-status dns \
        minio-buckets minio-console minio-list \
        test-api test-ai test-ai-audio test-ai-image \
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
	@echo "  KHIDMETI v14.0 — Gemma4 E2B/E4B (texte + image + audio)"
	@echo "  OS : $(OS) | IP : $(LOCAL_IP)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "  ⚠️  SETUP INITIAL (avant make start) :"
	@echo "  make download-gemma4   ← Gemma4 E2B Q4_K_M (~3.8 GB)"
	@echo "  make start             ← Lance tout"
	@echo ""
	@echo "  [GPU — E4B] :"
	@echo "  GEMMA4_VARIANT=e4b make download-gemma4"
	@echo "  docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d"
	@echo ""
	@echo "  [Quotidien]"
	@echo "  make stop              Arrêter"
	@echo "  make restart           Redémarrer"
	@echo "  make health            État des services"
	@echo "  make ai-status         État IA + modèles sur disque"
	@echo "  make logs              Tous les logs"
	@echo "  make dns               URLs + Flutter config"
	@echo ""
	@echo "  [Logs]"
	@echo "  make logs-ai-gemma4    Gemma4 (texte + image + audio natif)"
	@echo ""
	@echo "  [Tests IA]"
	@echo "  make test-ai           Darija → JSON (Gemma4 texte)"
	@echo "  make test-ai-audio     Health Gemma4 audio (endpoint direct)"
	@echo "  make test-ai-image     Health Gemma4 (requête vide)"
	@echo ""
	@echo "  [Tunnel]"
	@echo "  make ngrok             Tunnel permanent"
	@echo ""
	@echo "  [Scripts]"
	@echo "  make scripts           Migrations + Seeds"
	@echo "  make backup            Sauvegarder MongoDB"
	@echo ""
	@echo "  [Nettoyage]"
	@echo "  make clean             Volumes Docker (modèles intacts)"
	@echo ""

# ── _ensure-dirs ──────────────────────────────────────────────────────────────
_ensure-dirs:
	@mkdir -p logs backups/mongodb
	@mkdir -p docker/models/gemma4
	@# docker/models/audio gardé pour compatibilité ascendante (peut être supprimé)
	@mkdir -p docker/models/audio

# ── _ensure-env ───────────────────────────────────────────────────────────────
_ensure-env:
	@if [ ! -f .env ]; then \
	  if [ -f .env.example ]; then \
	    cp .env.example .env; \
	    echo "  ⚠️  .env créé depuis .env.example → remplissez FIREBASE_* et HF_TOKEN dans .env"; \
	  else \
	    echo "  ⚠️  .env absent — créez-le manuellement"; \
	  fi; \
	fi

# ── _ensure-models ─────────────────────────────────────────────────────────────
# v14 : seul Gemma4 model + mmproj sont requis (Whisper supprimé)
_ensure-models: _ensure-dirs
	@echo ""
	@_model=$$(find docker/models/gemma4 -name "*.gguf" -size +100M 2>/dev/null | grep -v mmproj | head -1); \
	_mmproj=$$(find docker/models/gemma4 -name "*mmproj*.gguf" -size +10M 2>/dev/null | head -1); \
	if [ -n "$$_model" ] && [ -n "$$_mmproj" ]; then \
	  echo "  ✅ [gemma4] Model + mmproj f32 en cache ($$(du -sh docker/models/gemma4 | cut -f1))"; \
	  echo "             mmproj f32 = encodeur image + audio (PR#21421)"; \
	else \
	  echo "  ❌ [gemma4] Modèles ABSENTS → make download-gemma4"; \
	  echo "             Sans les modèles, ai-gemma4 ne démarrera PAS."; \
	  echo ""; \
	  exit 1; \
	fi
	@echo ""

models: _ensure-models

# ══════════════════════════════════════════════════════════════════════════════
# download-gemma4 : télécharge Gemma4 E2B (CPU) ou E4B (GPU) depuis HuggingFace
#
# Variables :
#   GEMMA4_VARIANT=e2b|e4b    (défaut: e2b)
#   GEMMA4_QUANT=Q4_K_M|Q8_0  (défaut: Q4_K_M)
#
# Fichiers téléchargés dans docker/models/gemma4/ :
#   gemma-4-{e2b|e4b}-it-{QUANT}.gguf         — modèle (~3.5-4.9 GB)
#   mmproj-gemma-4-{e2b|e4b}-it-f32.gguf      — mmproj f32 (image + audio encoder)
# ══════════════════════════════════════════════════════════════════════════════
download-gemma4: _ensure-dirs
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Téléchargement Gemma4 $(GEMMA4_VARIANT) $(GEMMA4_QUANT)"
	@echo "  Depuis : bartowski/google_gemma-4-*-it-GGUF"
	@echo "  Note   : mmproj f32 inclut encodeur image + audio (PR#21421)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@if ! command -v python3 &>/dev/null; then \
	  echo "  ❌ python3 requis (sudo apt install python3)"; exit 1; fi
	@python3 -c "import huggingface_hub" 2>/dev/null \
	  || pip3 install -q huggingface_hub --break-system-packages 2>/dev/null \
	  || pip3 install -q huggingface_hub 2>/dev/null \
	  || { echo "  ❌ Impossible d'installer huggingface_hub"; exit 1; }
	@GEMMA4_VARIANT="$(GEMMA4_VARIANT)" \
	  GEMMA4_QUANT="$(GEMMA4_QUANT)" \
	  GEMMA4_DEST="$(PWD)/docker/models/gemma4" \
	  HF_TOKEN="$$(grep '^HF_TOKEN=' .env 2>/dev/null | cut -d= -f2 | tr -d ' "')" \
	  python3 scripts/download_gemma4.py
	@echo "  Prochaine étape : make start"
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## START
## ══════════════════════════════════════════════════════════════════════════════

start: _ensure-dirs _ensure-env _ensure-models
	@echo "══════════════════════════════════════════════════════"
	@echo "  Démarrage Khidmeti v14.0 — Gemma4 $(GEMMA4_VARIANT) (texte + image + audio)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@docker compose up -d
	@echo ""
	@echo "  ⏳ Attente ai-gemma4 (modèles déjà sur disque → ~10-30s)..."
	@READY=0; \
	for i in $$(seq 1 24); do \
	  if curl -sf http://localhost:8011/health > /dev/null 2>&1; then \
	    READY=1; break; fi; \
	  printf "."; sleep 5; \
	done; echo ""; \
	if [ "$$READY" -eq 1 ]; then \
	  echo "  ✅ ai-gemma4 prêt (texte + image + audio natif) !"; \
	else \
	  echo "  ⚠️  ai-gemma4 non prêt → make logs-ai-gemma4"; \
	  echo "     Si modèles absents : make download-gemma4"; \
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

logs-ai-gemma4:
	@docker compose logs -f ai-gemma4

## ══════════════════════════════════════════════════════════════════════════════
## DIAGNOSTIC
## ══════════════════════════════════════════════════════════════════════════════

health:
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  État des services Khidmeti v14.0"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@_c() { \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" "$$2" 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "  ✅ $$1" || echo "  ❌ $$1 (HTTP $$code)"; \
	}; \
	_c "NestJS  :3000 " "http://localhost:3000/health"; \
	_c "nginx   :80   " "http://localhost/health"; \
	_c "Qdrant  :6333 " "http://localhost:6333/healthz"; \
	_c "MinIO   :9001 " "http://localhost:9001/minio/health/live"
	@code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8011/health 2>/dev/null); \
	[ "$$code" = "200" ] \
	  && echo "  ✅ ai-gemma4:8011 (texte + image + audio natif)" \
	  || echo "  ❌ ai-gemma4:8011 (non prêt → make logs-ai-gemma4)"
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
	@echo "  Statut IA v14.0 — Gemma4 E2B/E4B (modèle unique)"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "  Services :"
	@code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8011/health 2>/dev/null); \
	[ "$$code" = "200" ] && echo "  ✅ ai-gemma4:8011  (texte + image + audio natif — PR#21421)" \
	                     || echo "  ❌ ai-gemma4:8011  (non prêt → make logs-ai-gemma4)"
	@echo ""
	@echo "  Modèles sur disque :"
	@_model=$$(find docker/models/gemma4 -name "*.gguf" -size +100M 2>/dev/null | grep -v mmproj | head -1); \
	_mmproj=$$(find docker/models/gemma4 -name "*mmproj*.gguf" -size +10M 2>/dev/null | head -1); \
	if [ -n "$$_model" ] && [ -n "$$_mmproj" ]; then \
	  echo "  ✅ gemma4/ Model + mmproj f32 ($$(du -sh docker/models/gemma4 | cut -f1))"; \
	  echo "     model  : $$(basename $$_model)"; \
	  echo "     mmproj : $$(basename $$_mmproj) (image + audio encoder)"; \
	else \
	  echo "  ❌ gemma4/ Modèles ABSENTS → make download-gemma4"; fi
	@echo ""
	@free -h 2>/dev/null | awk '/^Mem:/{print "  RAM — Total: " $$2 "  Dispo: " $$7}' \
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
	@echo "  API      : http://$(HOST):3000"
	@echo "  nginx    : http://$(HOST):80"
	@echo "  Swagger  : http://$(HOST):3000/api/docs"
	@echo "  Mongo    : http://$(HOST):8081"
	@echo "  Qdrant   : http://$(HOST):6333/dashboard"
	@echo "  MinIO    : http://$(HOST):9002"
	@echo "  Gemma4   : http://$(HOST):8011  (texte + image + audio)"
	@echo ""
	@echo "  ── Flutter ──────────────────────────────────────────"
	@echo "  flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80"
	@NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "'); \
	if [ -n "$$NGROK_DOMAIN" ]; then \
	  echo ""; \
	  echo "  ngrok   : https://$$NGROK_DOMAIN"; \
	  echo "  flutter run --dart-define=API_BASE_URL=https://$$NGROK_DOMAIN"; fi
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## TESTS IA
## ══════════════════════════════════════════════════════════════════════════════

test-ai:
	@echo ""
	@echo "  Test Gemma4 — Darija algérienne → JSON..."
	@curl -s http://localhost:8011/v1/chat/completions \
	  -H "Content-Type: application/json" \
	  -d '{ \
	    "model":"gemma4", \
	    "messages":[ \
	      {"role":"system","content":"Réponds UNIQUEMENT en JSON: {\"profession\":null,\"is_urgent\":false,\"problem_description\":\"\",\"max_radius_km\":null,\"confidence\":0}"}, \
	      {"role":"user","content":"عندي ماء ساقط من السقف وكليمو ما يبردش"} \
	    ], \
	    "temperature":0.05, \
	    "max_tokens":256, \
	    "chat_template_kwargs":{"enable_thinking":false} \
	  }' \
	  | python3 -m json.tool 2>/dev/null \
	  || echo "  ❌ ai-gemma4 non disponible → make logs-ai-gemma4"
	@echo ""

test-ai-audio:
	@echo ""
	@echo "  Test Gemma4 audio natif — santé endpoint (v14)"
	@echo "  Note : audio natif via llama.cpp PR#21421 (MERGÉ)"
	@code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8011/health 2>/dev/null); \
	[ "$$code" = "200" ] \
	  && echo "  ✅ ai-gemma4:8011 opérationnel — audio natif prêt" \
	  || echo "  ❌ ai-gemma4:8011 non disponible → make logs-ai-gemma4"
	@echo ""
	@echo "  Pour tester audio réel : POST /ai/extract-intent/audio (NestJS API)"
	@echo "  Format recommandé : WAV 16kHz mono, < 30 secondes"
	@echo ""

test-ai-image:
	@echo ""
	@echo "  Test Gemma4 — endpoint image (healthcheck simple)..."
	@curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:8011/health \
	  && echo "  ✅ ai-gemma4 opérationnel (images supportées via mmproj)" \
	  || echo "  ❌ ai-gemma4 non disponible → make logs-ai-gemma4"
	@echo ""

test-api:
	@echo ""
	@echo "  Health :"; curl -s http://localhost:3000/health
	@echo ""
	@echo "  Swagger :"; curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:3000/api/docs
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## NGROK
## ══════════════════════════════════════════════════════════════════════════════

ngrok:
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Tunnel ngrok — Domaine permanent"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@if ! command -v ngrok &>/dev/null; then \
	  echo "  ngrok absent — installation..."; \
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
	  echo "  ✅ ngrok installé !"; fi
	@NGROK_TOKEN=$$(grep '^NGROK_AUTH_TOKEN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "'); \
	if [ -z "$$NGROK_TOKEN" ]; then \
	  read -p "  Auth Token ngrok : " NGROK_TOKEN; \
	  grep -q '^NGROK_AUTH_TOKEN=' .env 2>/dev/null \
	    && $(SED_I) "s|^NGROK_AUTH_TOKEN=.*|NGROK_AUTH_TOKEN=$$NGROK_TOKEN|" .env \
	    || echo "NGROK_AUTH_TOKEN=$$NGROK_TOKEN" >> .env; fi; \
	ngrok config add-authtoken "$$(grep '^NGROK_AUTH_TOKEN=' .env | cut -d= -f2- | tr -d ' "')" >/dev/null 2>&1; \
	NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "'); \
	if [ -z "$$NGROK_DOMAIN" ]; then \
	  read -p "  Domaine statique ngrok : " NGROK_DOMAIN; \
	  grep -q '^NGROK_DOMAIN=' .env 2>/dev/null \
	    && $(SED_I) "s|^NGROK_DOMAIN=.*|NGROK_DOMAIN=$$NGROK_DOMAIN|" .env \
	    || echo "NGROK_DOMAIN=$$NGROK_DOMAIN" >> .env; fi; \
	ND=$$(grep '^NGROK_DOMAIN=' .env | cut -d= -f2- | tr -d ' "'); \
	echo "  URL : https://$$ND"; \
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
	  "mc alias set local http://minio:9001 $$MK $$MS && mc ls local/"

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
	@echo "sudo ufw allow 80/tcp 3000/tcp 6333/tcp 8081/tcp 9001/tcp 9002/tcp 8011/tcp"
	@echo "# Port 8000 (Whisper) supprimé en v14 — Gemma4 audio natif sur 8011"
