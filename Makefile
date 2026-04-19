## ══════════════════════════════════════════════════════════════════════════════
## KHIDMETI BACKEND — Makefile
##
## WORKFLOW :
##   make start       → 1ère fois : démarre tout + pull modèle avec progression
##   make start       → fois suivantes : démarrage instantané (modèle en volume)
##   make ollama-pull → forcer re-pull (changer de modèle)
## ══════════════════════════════════════════════════════════════════════════════

SHELL := /bin/bash

OS   := $(shell uname -s 2>/dev/null || echo Windows_NT)
ARCH := $(shell uname -m 2>/dev/null || echo unknown)

ifeq ($(OS),Darwin)
  OPEN_CMD := open
else ifeq ($(OS),Windows_NT)
  OPEN_CMD := start
else
  OPEN_CMD := $(shell command -v xdg-open 2>/dev/null || echo "echo 🔗 Ouvrez manuellement : ")
endif

SED_I := $(shell \
  if sed --version 2>/dev/null | grep -q GNU; then \
    echo "sed -i"; \
  else \
    echo "sed -i ''"; \
  fi)

LOCAL_IP := $(shell \
  ip route get 1 2>/dev/null | awk '{print $$7; exit}' || \
  ifconfig 2>/dev/null | awk '/inet /{print $$2}' | grep -v 127.0.0.1 | head -1 || \
  hostname -I 2>/dev/null | awk '{print $$1}' || \
  echo "127.0.0.1")

HOST     := $(shell hostname)
DATETIME := $(shell date +%Y%m%d-%H%M%S)
ARGS     ?=

_OLLAMA_MODEL := $(shell grep '^OLLAMA_MODEL' .env 2>/dev/null \
  | cut -d= -f2 | tr -d '[:space:]' || echo 'gemma4:e2b')

.DEFAULT_GOAL := help

.PHONY: help start start-gpu stop stop-gpu restart \
        build rebuild logs logs-api logs-mongo logs-redis \
        logs-qdrant logs-minio logs-nginx logs-mongo-ui \
        logs-ollama logs-whisper \
        health status ai-status dns \
        ollama-pull \
        minio-buckets minio-console minio-list \
        test-api test-ai firewall backup restore \
        shell-api shell-mongo shell-redis shell-minio shell-qdrant \
        mongo-stats redis-info redis-flush clean-logs clean \
        prod-start prod-update \
        tunnel-install tunnel-quick tunnel-stop tunnel-status \
        flutter-run ngrok ngrok-install ngrok-reset \
        scripts scripts-migrations scripts-seeds

## ══════════════════════════════════════════════════════════════════════════════
## AIDE
## ══════════════════════════════════════════════════════════════════════════════

help: ## Afficher l'aide
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  KHIDMETI — Commandes disponibles"
	@echo "  OS : $(OS) | Architecture : $(ARCH)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  [DÉMARRAGE]"
	@echo "  start              Démarrer + pull modèle si absent (progression visible)"
	@echo "  start-gpu          Démarrer avec GPU NVIDIA"
	@echo "  stop               Arrêter (volumes conservés)"
	@echo "  restart            Redémarrer"
	@echo ""
	@echo "  [OLLAMA]"
	@echo "  ollama-pull        Pull / mise à jour du modèle (progression visible)"
	@echo ""
	@echo "  [BUILD API]"
	@echo "  build              Builder l'image NestJS"
	@echo "  rebuild            Rebuild NestJS + redémarrage"
	@echo ""
	@echo "  [LOGS]"
	@echo "  logs               Tous les logs"
	@echo "  logs-api           Logs NestJS"
	@echo "  logs-ollama        Logs Ollama"
	@echo "  logs-whisper       Logs faster-whisper"
	@echo "  logs-mongo         Logs MongoDB"
	@echo ""
	@echo "  [DIAGNOSTIC]"
	@echo "  health             Santé de tous les services"
	@echo "  ai-status          Statut IA + modèles chargés"
	@echo "  status             Statut + mémoire des conteneurs"
	@echo "  dns                URLs + config Flutter"
	@echo ""
	@echo "  [TUNNEL]"
	@echo "  ngrok              Tunnel ngrok domaine PERMANENT"
	@echo "  tunnel-quick       Quick Tunnel Cloudflare (URL aléatoire)"
	@echo ""
	@echo "  [SCRIPTS]"
	@echo "  scripts            Toutes migrations + seeds"
	@echo "  scripts-migrations Migrations seulement"
	@echo "  scripts-seeds      Seeds seulement"
	@echo "  scripts-<nom>      Un script précis"
	@echo ""
	@echo "  [SAUVEGARDE]"
	@echo "  backup             Sauvegarder MongoDB"
	@echo "  restore            Restaurer (BACKUP_DATE=YYYYMMDD-HHMMSS)"
	@echo ""
	@echo "  [DEBUG]"
	@echo "  shell-api          Shell NestJS"
	@echo "  shell-mongo        mongosh"
	@echo ""
	@echo "  [NETTOYAGE]"
	@echo "  clean              Supprimer volumes + données"
	@echo "  clean-logs         Vider les logs"
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## OLLAMA — Pull avec progression visible
## ══════════════════════════════════════════════════════════════════════════════

ollama-pull: ## Pull du modèle avec progression en temps réel (X GB / Y GB)
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Pull modèle Ollama"
	@echo "  Modèle : $(_OLLAMA_MODEL)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  ⏳ Attente que Ollama soit prêt..."
	@until curl -sf http://localhost:11434/ > /dev/null 2>&1; do \
	  printf "."; sleep 2; \
	done
	@echo ""
	@echo "  📥 Téléchargement en cours — progression ci-dessous :"
	@echo "  (ex: pulling abc123... ████░░░░ 2.1 GB / 7.2 GB  28 MB/s  3m12s)"
	@echo ""
	@docker exec -it khidmeti-ollama ollama pull $(_OLLAMA_MODEL)
	@echo ""
	@echo "  ✅ Modèle $(_OLLAMA_MODEL) prêt."
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## GESTION DES SERVICES
## ══════════════════════════════════════════════════════════════════════════════

start: ## Démarrer tous les services + pull modèle Ollama si absent
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Démarrage de Khidmeti"
	@echo "  Modèle IA : $(_OLLAMA_MODEL)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@mkdir -p logs backups/mongodb data/mongodb data/redis data/qdrant data/minio
	@if [ ! -f .env ]; then \
		cp .env.example .env 2>/dev/null || true; \
		echo "  ⚠️  .env créé — configurez FIREBASE_* avant de continuer"; echo ""; \
	fi
	@echo "  🚀 Démarrage des services..."
	@docker compose up -d
	@echo ""
	@echo "  ✅ Services démarrés."
	@echo ""
	@echo "  ⏳ Attente que Ollama soit prêt..."
	@until curl -sf http://localhost:11434/ > /dev/null 2>&1; do \
	  printf "."; sleep 2; \
	done
	@echo ""
	@echo ""
	@if docker exec khidmeti-ollama ollama list 2>/dev/null | grep -q "$(_OLLAMA_MODEL)"; then \
	  echo "  ✅ Modèle $(_OLLAMA_MODEL) déjà présent — démarrage instantané."; \
	  echo ""; \
	else \
	  echo "  ℹ️  Modèle absent du volume — téléchargement en cours..."; \
	  echo "  📥 Progression (X GB / Y GB) :"; \
	  echo ""; \
	  docker exec -it khidmeti-ollama ollama pull $(_OLLAMA_MODEL); \
	  echo ""; \
	  echo "  ✅ Modèle $(_OLLAMA_MODEL) prêt."; \
	  echo ""; \
	fi
	@$(MAKE) health
	@$(MAKE) dns

start-gpu: ## Démarrer avec GPU NVIDIA
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Démarrage Khidmeti — GPU NVIDIA"
	@echo "  Modèle : $(_OLLAMA_MODEL)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
	@echo ""
	@echo "  ⏳ Attente Ollama..."
	@until curl -sf http://localhost:11434/ > /dev/null 2>&1; do printf "."; sleep 2; done
	@echo ""
	@if ! docker exec khidmeti-ollama ollama list 2>/dev/null | grep -q "$(_OLLAMA_MODEL)"; then \
	  echo "  📥 Pull modèle GPU..."; \
	  docker exec -it khidmeti-ollama ollama pull $(_OLLAMA_MODEL); \
	fi
	@$(MAKE) health

stop: ## Arrêter tous les services (volumes conservés — modèle intact)
	@docker compose down
	@echo ""
	@echo "  ✅ Services arrêtés."
	@echo "  ℹ️  Le modèle Ollama est conservé dans le volume khidmeti-ollama-data."
	@echo ""

stop-gpu: ## Arrêter les services GPU
	@docker compose -f docker-compose.yml -f docker-compose.gpu.yml down
	@echo "✅ Services GPU arrêtés."

restart: stop ## Redémarrer
	@sleep 3
	@$(MAKE) start

build: ## Builder l'image NestJS
	@docker compose build --no-cache api
	@echo "✅ Build NestJS terminé."

rebuild: build start ## Rebuild NestJS + redémarrage

## ══════════════════════════════════════════════════════════════════════════════
## LOGS
## ══════════════════════════════════════════════════════════════════════════════

logs:          @docker compose logs --tail=100 -f
logs-api:      @docker compose logs -f api
logs-mongo:    @docker compose logs -f mongo
logs-mongo-ui: @docker compose logs -f mongo-express
logs-redis:    @docker compose logs -f redis
logs-qdrant:   @docker compose logs -f qdrant
logs-minio:    @docker compose logs -f minio
logs-nginx:    @docker compose logs -f nginx
logs-ollama:   @docker compose logs -f ollama
logs-whisper:  @docker compose logs -f whisper

## ══════════════════════════════════════════════════════════════════════════════
## DIAGNOSTIC
## ══════════════════════════════════════════════════════════════════════════════

health: ## Vérifier la santé de tous les services
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  État des services Khidmeti"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo -n "  NestJS API  (3000) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE (HTTP $$code)"
	@echo -n "  nginx       (80)   : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE (HTTP $$code)"
	@echo -n "  MongoDB     (27017): "; \
	  docker exec khidmeti-mongo mongosh --quiet \
	    --eval "db.adminCommand('ping').ok" >/dev/null 2>&1 \
	  && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Redis       (6379) : "; \
	  REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	  docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" ping >/dev/null 2>&1 \
	  && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Qdrant      (6333) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:6333/healthz 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  MinIO       (9001) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9001/minio/health/live 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Ollama      (11434): "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:11434/ 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Whisper     (8000) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo ""

status: ## Statut + consommation mémoire des conteneurs
	@echo ""
	@docker ps -a --filter "name=khidmeti" \
	  --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
	@echo ""
	@echo "  Mémoire :"
	@docker stats --no-stream \
	  --format "  {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null \
	  | grep khidmeti | sort || true
	@echo ""

ai-status: ## Statut IA + modèles disponibles dans Ollama
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Statut IA locale"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo -n "  Ollama  (11434) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:11434/ 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Whisper (8000)  : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo ""
	@echo "  Modèles installés (docker exec ollama list) :"
	@docker exec khidmeti-ollama ollama list 2>/dev/null || echo "   (Ollama non démarré)"
	@echo ""
	@echo "  Volume :"
	@docker volume inspect khidmeti-ollama-data \
	  --format "   Chemin : {{.Mountpoint}}" 2>/dev/null || echo "   (volume absent)"
	@echo ""

dns: ## Afficher les URLs + config Flutter
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  URLs des services  [hôte : $(HOST)]"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  API REST       :  http://$(HOST):3000"
	@echo "  API via nginx  :  http://$(HOST):80"
	@echo "  Swagger docs   :  http://$(HOST):3000/api/docs"
	@echo "  Mongo Express  :  http://$(HOST):8081"
	@echo "  Qdrant UI      :  http://$(HOST):6333/dashboard"
	@echo "  MinIO console  :  http://$(HOST):9002"
	@echo "  Ollama API     :  http://$(HOST):11434"
	@echo "  Whisper API    :  http://$(HOST):8000"
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Config Flutter (même WiFi)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  IP locale : $(LOCAL_IP)"
	@echo ""
	@echo "  flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80"
	@echo ""
	@NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env 2>/dev/null \
	  | cut -d= -f2- | tr -d '[:space:]' | tr -d '"'); \
	if [ -n "$$NGROK_DOMAIN" ]; then \
		echo "  Tunnel ngrok : https://$$NGROK_DOMAIN"; \
		echo "  flutter run --dart-define=API_BASE_URL=https://$$NGROK_DOMAIN"; \
		echo ""; \
	fi

## ══════════════════════════════════════════════════════════════════════════════
## TUNNELS
## ══════════════════════════════════════════════════════════════════════════════

tunnel-install: ## Installer cloudflared
	@if command -v cloudflared >/dev/null 2>&1; then \
		echo "✅ cloudflared déjà installé : $$(cloudflared --version)"; \
	elif [ -f /etc/debian_version ] || grep -qi ubuntu /etc/os-release 2>/dev/null; then \
		curl -L --output /tmp/cloudflared.deb \
		  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb; \
		sudo dpkg -i /tmp/cloudflared.deb; \
	else \
		curl -L -o /usr/local/bin/cloudflared \
		  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; \
		chmod +x /usr/local/bin/cloudflared; \
	fi

tunnel-quick: ## Quick Tunnel Cloudflare (URL aléatoire)
	@echo "  CTRL+C pour arrêter. URL permanente : make ngrok"
	@cloudflared tunnel --url http://localhost:80

tunnel-stop: ## Arrêter le tunnel Cloudflare
	@pkill -f 'cloudflared tunnel' 2>/dev/null \
	  && echo "✅ Tunnel arrêté." || echo "Aucun tunnel actif."

tunnel-status: ## État du tunnel Cloudflare
	@ps aux | grep 'cloudflared tunnel' | grep -v grep || echo "Aucun tunnel actif."

flutter-run: ## Lancer Flutter avec l'IP locale
	@flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80

ngrok-install: ## Installer ngrok
	@if command -v ngrok >/dev/null 2>&1; then \
		echo "✅ ngrok déjà installé : $$(ngrok --version)"; \
	elif [ -f /etc/debian_version ] || grep -qi ubuntu /etc/os-release 2>/dev/null; then \
		curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
		  | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null; \
		echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
		  | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null; \
		sudo apt-get update -qq && sudo apt-get install -y ngrok; \
	elif command -v brew >/dev/null 2>&1; then \
		brew install ngrok/ngrok/ngrok; \
	else \
		curl -sL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz \
		  | sudo tar xz -C /usr/local/bin; \
	fi

ngrok: ## Tunnel ngrok domaine statique permanent
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Tunnel ngrok — Domaine permanent"
	@echo "══════════════════════════════════════════════"
	@if ! command -v ngrok >/dev/null 2>&1; then \
		echo "❌ ngrok introuvable. Lancez : make ngrok-install"; exit 1; \
	fi
	@NGROK_TOKEN=$$(grep '^NGROK_AUTH_TOKEN=' .env 2>/dev/null \
	  | cut -d= -f2- | tr -d '[:space:]' | tr -d '"'); \
	if [ -z "$$NGROK_TOKEN" ]; then \
		echo "  → https://dashboard.ngrok.com/get-started/your-authtoken"; \
		read -p "  Auth Token : " NGROK_TOKEN; \
		grep -q '^NGROK_AUTH_TOKEN=' .env 2>/dev/null \
		  && $(SED_I) "s|^NGROK_AUTH_TOKEN=.*|NGROK_AUTH_TOKEN=$$NGROK_TOKEN|" .env \
		  || echo "NGROK_AUTH_TOKEN=$$NGROK_TOKEN" >> .env; \
	fi; \
	ngrok config add-authtoken "$$NGROK_TOKEN" 2>/dev/null; \
	NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env 2>/dev/null \
	  | cut -d= -f2- | tr -d '[:space:]' | tr -d '"'); \
	if [ -z "$$NGROK_DOMAIN" ]; then \
		echo "  → https://dashboard.ngrok.com/domains"; \
		read -p "  Domaine statique : " NGROK_DOMAIN; \
		grep -q '^NGROK_DOMAIN=' .env 2>/dev/null \
		  && $(SED_I) "s|^NGROK_DOMAIN=.*|NGROK_DOMAIN=$$NGROK_DOMAIN|" .env \
		  || echo "NGROK_DOMAIN=$$NGROK_DOMAIN" >> .env; \
	fi; \
	NGROK_DOMAIN=$$(grep '^NGROK_DOMAIN=' .env | cut -d= -f2- | tr -d '[:space:]' | tr -d '"'); \
	echo ""; \
	echo "  URL : https://$$NGROK_DOMAIN"; \
	echo "  flutter run --dart-define=API_BASE_URL=https://$$NGROK_DOMAIN"; \
	echo "  → Ctrl+C pour arrêter"; echo ""; \
	ngrok http --domain="$$NGROK_DOMAIN" 80

ngrok-reset: ## Réinitialiser la config ngrok
	@$(SED_I) '/^NGROK_AUTH_TOKEN=/d' .env 2>/dev/null
	@$(SED_I) '/^NGROK_DOMAIN=/d' .env 2>/dev/null
	@echo "✅ Config ngrok supprimée."

## ══════════════════════════════════════════════════════════════════════════════
## SCRIPTS — Migrations + Seeds
## ══════════════════════════════════════════════════════════════════════════════

scripts: ## Exécuter toutes les migrations puis tous les seeds
	@$(MAKE) scripts-migrations
	@$(MAKE) scripts-seeds

scripts-migrations: ## Exécuter toutes les migrations MongoDB
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Migrations MongoDB"
	@echo "══════════════════════════════════════════════"
	@MONGO_USER=$$(grep '^MONGO_ROOT_USER' .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep '^MONGO_ROOT_PASSWORD' .env | cut -d= -f2 | tr -d '[:space:]'); \
	COUNT=0; FAILED=0; \
	shopt -s nullglob; \
	FILES=(scripts/migrations/*.js); \
	if [ $${#FILES[@]} -eq 0 ]; then \
	  echo "  ⚪ Aucune migration trouvée."; \
	else \
	  for f in "$${FILES[@]}"; do \
	    echo "  → $$(basename $$f)"; \
	    docker exec -i khidmeti-mongo mongosh \
	      --quiet -u "$$MONGO_USER" -p "$$MONGO_PASS" \
	      --authenticationDatabase admin khidmeti < "$$f" \
	    && { echo "  ✅ $$(basename $$f) OK"; COUNT=$$((COUNT+1)); } \
	    || { echo "  ❌ $$(basename $$f) FAILED"; FAILED=$$((FAILED+1)); }; \
	  done; \
	  echo ""; \
	  echo "  ✅ $$COUNT OK  |  ❌ $$FAILED échec(s)"; \
	  [ $$FAILED -gt 0 ] && exit 1 || true; \
	fi
	@echo ""

scripts-seeds: ## Exécuter tous les seeds TypeScript
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Seeds TypeScript"
	@echo "══════════════════════════════════════════════"
	@COUNT=0; FAILED=0; \
	shopt -s nullglob; \
	FILES=(apps/api/src/scripts/seeds/*.ts); \
	if [ $${#FILES[@]} -eq 0 ]; then \
	  echo "  ⚪ Aucun seed trouvé."; \
	else \
	  for f in "$${FILES[@]}"; do \
	    NAME=$$(basename "$$f"); \
	    echo "  → $$NAME $(ARGS)"; \
	    docker exec khidmeti-api \
	      npx ts-node --project tsconfig.json "src/scripts/seeds/$$NAME" $(ARGS) \
	    && { echo "  ✅ $$NAME OK"; COUNT=$$((COUNT+1)); } \
	    || { echo "  ❌ $$NAME FAILED"; FAILED=$$((FAILED+1)); }; \
	  done; \
	  echo ""; \
	  echo "  ✅ $$COUNT OK  |  ❌ $$FAILED échec(s)"; \
	  [ $$FAILED -gt 0 ] && exit 1 || true; \
	fi
	@echo ""

scripts-%:
	@NAME=$*; \
	if [ -f "scripts/migrations/$$NAME.js" ]; then \
	  MONGO_USER=$$(grep '^MONGO_ROOT_USER' .env | cut -d= -f2 | tr -d '[:space:]'); \
	  MONGO_PASS=$$(grep '^MONGO_ROOT_PASSWORD' .env | cut -d= -f2 | tr -d '[:space:]'); \
	  docker exec -i khidmeti-mongo mongosh \
	    --quiet -u "$$MONGO_USER" -p "$$MONGO_PASS" \
	    --authenticationDatabase admin khidmeti < "scripts/migrations/$$NAME.js" \
	  && echo "  ✅ $$NAME.js OK" || { echo "  ❌ FAILED"; exit 1; }; \
	elif [ -f "apps/api/src/scripts/seeds/$$NAME.ts" ]; then \
	  docker exec khidmeti-api \
	    npx ts-node --project tsconfig.json "src/scripts/seeds/$$NAME.ts" $(ARGS) \
	  && echo "  ✅ $$NAME.ts OK" || { echo "  ❌ FAILED"; exit 1; }; \
	else \
	  echo "❌ Script '$$NAME' introuvable."; \
	  ls scripts/migrations/*.js 2>/dev/null | xargs -I{} basename {} .js \
	    | sed 's/^/  migration: /' || true; \
	  ls apps/api/src/scripts/seeds/*.ts 2>/dev/null | xargs -I{} basename {} .ts \
	    | sed 's/^/  seed: /' || true; \
	  exit 1; \
	fi

## ══════════════════════════════════════════════════════════════════════════════
## MINIO
## ══════════════════════════════════════════════════════════════════════════════

minio-buckets: ## Recréer les buckets MinIO
	@MINIO_ACCESS_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET_KEY=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run --rm --network khidmeti-network minio/mc:latest sh -c \
	  "mc alias set local http://minio:9001 $$MINIO_ACCESS_KEY $$MINIO_SECRET_KEY && \
	   mc mb --ignore-existing local/profile-images && \
	   mc mb --ignore-existing local/service-media && \
	   mc mb --ignore-existing local/audio-recordings && \
	   mc anonymous set download local/profile-images && \
	   echo '✅ Buckets créés.'"

minio-console: ## Ouvrir la console MinIO
	@$(OPEN_CMD) http://localhost:9002 2>/dev/null || echo "  → http://localhost:9002"

minio-list: ## Lister les fichiers MinIO
	@MINIO_ACCESS_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET_KEY=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run --rm --network khidmeti-network minio/mc:latest sh -c \
	  "mc alias set local http://minio:9001 $$MINIO_ACCESS_KEY $$MINIO_SECRET_KEY && \
	   mc ls local/profile-images; mc ls local/service-media"

## ══════════════════════════════════════════════════════════════════════════════
## TESTS
## ══════════════════════════════════════════════════════════════════════════════

test-api: ## Tester les endpoints principaux
	@echo ""
	@echo "  [1] Health :"; curl -s http://localhost:3000/health
	@echo ""
	@echo "  [2] Swagger :"; curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/docs
	@echo ""

test-ai: ## Tester l'extraction d'intention Darija
	@echo ""
	@echo "  Test Ollama — extraction Darija..."
	@echo ""
	@curl -s http://localhost:11434/v1/chat/completions \
	  -H "Content-Type: application/json" \
	  -d "{\"model\":\"$(_OLLAMA_MODEL)\",\"messages\":[{\"role\":\"system\",\"content\":\"Réponds UNIQUEMENT en JSON: {\\\"profession\\\":null,\\\"is_urgent\\\":false,\\\"problem_description\\\":\\\"\\\",\\\"confidence\\\":0}\"},{\"role\":\"user\",\"content\":\"عندي ماء ساقط من السقف\"}],\"options\":{\"num_ctx\":2048,\"think\":false},\"temperature\":0.05,\"max_tokens\":200,\"stream\":false}" \
	  | python3 -m json.tool 2>/dev/null || echo "  ❌ Ollama non disponible"
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## SAUVEGARDE
## ══════════════════════════════════════════════════════════════════════════════

backup: ## Sauvegarder MongoDB
	@mkdir -p backups/mongodb/$(DATETIME)
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongodump \
	  --username "$$MONGO_USER" --password "$$MONGO_PASS" \
	  --authenticationDatabase admin --db khidmeti \
	  --out /tmp/backup_$(DATETIME); \
	docker cp khidmeti-mongo:/tmp/backup_$(DATETIME) backups/mongodb/$(DATETIME)
	@echo "  ✅ Sauvegarde → backups/mongodb/$(DATETIME)"

restore: ## Restaurer (BACKUP_DATE=YYYYMMDD-HHMMSS)
	@if [ -z "$(BACKUP_DATE)" ]; then \
		echo "Usage : make restore BACKUP_DATE=20250101-120000"; exit 1; \
	fi
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker cp backups/mongodb/$(BACKUP_DATE) khidmeti-mongo:/tmp/restore_$(BACKUP_DATE); \
	docker exec khidmeti-mongo mongorestore \
	  --username "$$MONGO_USER" --password "$$MONGO_PASS" \
	  --authenticationDatabase admin --db khidmeti --drop \
	  /tmp/restore_$(BACKUP_DATE)/khidmeti
	@echo "✅ Restauration terminée."

## ══════════════════════════════════════════════════════════════════════════════
## SHELLS
## ══════════════════════════════════════════════════════════════════════════════

shell-api: ## Shell dans NestJS
	@docker exec -it khidmeti-api /bin/sh

shell-mongo: ## mongosh dans MongoDB
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec -it khidmeti-mongo mongosh -u "$$MONGO_USER" -p "$$MONGO_PASS" \
	  --authenticationDatabase admin khidmeti

shell-redis: ## redis-cli
	@REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec -it khidmeti-redis redis-cli -a "$$REDIS_PASS"

shell-minio: ## mc client MinIO
	@MINIO_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run -it --rm --network khidmeti-network minio/mc:latest \
	  sh -c "mc alias set local http://minio:9001 $$MINIO_KEY $$MINIO_SECRET && sh"

shell-qdrant: ## Dashboard Qdrant
	@$(OPEN_CMD) http://localhost:6333/dashboard 2>/dev/null \
	  || echo "  → http://localhost:6333/dashboard"

mongo-stats: ## Stats MongoDB
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongosh -u "$$MONGO_USER" -p "$$MONGO_PASS" \
	  --authenticationDatabase admin khidmeti --quiet --eval "db.stats()"

redis-info: ## Stats Redis
	@REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" INFO server

redis-flush: ## Vider Redis
	@REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" FLUSHALL
	@echo "✅ Cache Redis vidé."

## ══════════════════════════════════════════════════════════════════════════════
## NETTOYAGE
## ══════════════════════════════════════════════════════════════════════════════

clean-logs: ## Vider les logs
	@find logs/ -name "*.log" -delete 2>/dev/null || true
	@echo "✅ Logs nettoyés."

clean: ## Supprimer volumes + données (y compris le modèle Ollama)
	@echo ""
	@echo "  ⚠️  Supprime : MongoDB, Redis, Qdrant, MinIO ET le modèle Ollama."
	@echo "  Le modèle sera re-téléchargé au prochain : make start"
	@echo ""
	@read -p "  Confirmer ? [y/N] " CONFIRM; \
	if [ "$$CONFIRM" = "y" ] || [ "$$CONFIRM" = "Y" ]; then \
		docker compose down -v --remove-orphans; \
		docker system prune -f; \
		rm -rf data/mongodb data/redis data/qdrant data/minio; \
		echo "✅ Nettoyage terminé."; \
	else echo "Annulé."; fi

## ══════════════════════════════════════════════════════════════════════════════
## PRODUCTION
## ══════════════════════════════════════════════════════════════════════════════

prod-start: ## Démarrer en production
	@docker compose up -d
	@echo "✅ Mode production actif."

prod-update: ## Mettre à jour l'API sans downtime
	@docker compose build --no-cache api
	@docker compose up -d --no-deps --build api
	@echo "✅ API mise à jour."

firewall: ## Commandes pare-feu
	@echo "  sudo ufw allow 80/tcp 3000/tcp 6333/tcp 8081/tcp 9001/tcp 9002/tcp 11434/tcp 8000/tcp"
