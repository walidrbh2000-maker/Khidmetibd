## ══════════════════════════════════════════════════════════════════════════════
## KHIDMETI BACKEND — Makefile
##
## Supported environments (POSIX shell required):
##   Linux native, macOS, WSL2, GitHub Codespaces
##
## Windows CMD / PowerShell users: use  scripts\khidmeti.bat  or  scripts\khidmeti.ps1
##
## ══════════════════════════════════════════════════════════════════════════════

SHELL := /bin/bash

## ── OS detection ──────────────────────────────────────────────────────────────
OS   := $(shell uname -s 2>/dev/null || echo Windows_NT)
ARCH := $(shell uname -m 2>/dev/null || echo unknown)

## ── Open-browser command (gracefully no-ops in headless Codespaces) ───────────
ifeq ($(OS),Darwin)
  OPEN_CMD := open
else ifeq ($(OS),Windows_NT)
  OPEN_CMD := start
else
  ## Linux / WSL / Codespaces — xdg-open may not exist in headless env
  OPEN_CMD := $(shell command -v xdg-open 2>/dev/null || echo "echo 🔗 Open manually: ")
endif

## ── Portable sed -i ───────────────────────────────────────────────────────────
## macOS sed requires  sed -i ''  (BSD), Linux/WSL/Codespaces use  sed -i  (GNU)
SED_I := $(shell \
  if sed --version 2>/dev/null | grep -q GNU; then \
    echo "sed -i"; \
  else \
    echo "sed -i ''"; \
  fi)

## ── Local IP (best-effort — used in dns target) ───────────────────────────────
LOCAL_IP := $(shell \
  ip route get 1 2>/dev/null | awk '{print $$7; exit}' || \
  ifconfig 2>/dev/null | awk '/inet /{print $$2}' | grep -v 127.0.0.1 | head -1 || \
  hostname -I 2>/dev/null | awk '{print $$1}' || \
  echo "127.0.0.1")

HOST     := $(shell hostname)
DATETIME := $(shell date +%Y%m%d-%H%M%S)

.DEFAULT_GOAL := help
.PHONY: help start start-local start-gpu stop restart build rebuild logs logs-api \
        logs-mongo logs-redis logs-qdrant logs-minio logs-nginx health status \
        ai-status dns ai-switch-gemini ai-switch-ollama ai-switch-vllm ollama-pull \
        minio-buckets minio-console minio-list test-api test-ai test-upload \
        firewall backup backup-mongo restore list-backups shell-api shell-mongo \
        shell-redis shell-minio shell-qdrant mongo-stats redis-info redis-flush \
        clean-logs clean prod-start prod-update \
        tunnel-install tunnel-quick tunnel-stop tunnel-status flutter-run

## ══════════════════════════════════════════════════════════════════════════════
## AIDE
## ══════════════════════════════════════════════════════════════════════════════

help: ## Afficher l'aide
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  KHIDMETI — Commandes disponibles"
	@echo "  OS: $(OS) | Arch: $(ARCH)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  [SERVICES]"
	@echo "  start              Demarrer (AI=gemini par defaut)"
	@echo "  start-local        Demarrer avec Ollama (16GB RAM requis)"
	@echo "  start-gpu          Demarrer avec vLLM  (GPU NVIDIA requis)"
	@echo "  stop               Arreter tous les services"
	@echo "  restart            Redemarrer tous les services"
	@echo "  build              Builder l'image NestJS"
	@echo "  rebuild            Rebuild + redemarrer"
	@echo ""
	@echo "  [LOGS]"
	@echo "  logs               Tous les logs"
	@echo "  logs-api           Logs NestJS uniquement"
	@echo "  logs-mongo         Logs MongoDB"
	@echo "  logs-redis         Logs Redis"
	@echo "  logs-qdrant        Logs Qdrant"
	@echo "  logs-minio         Logs MinIO"
	@echo "  logs-nginx         Logs nginx"
	@echo ""
	@echo "  [DIAGNOSTIC]"
	@echo "  health             Verifier la sante des services"
	@echo "  status             Statut des conteneurs Docker"
	@echo "  ai-status          Provider AI actif"
	@echo "  dns                URLs + config Flutter"
	@echo ""
	@echo "  [TUNNEL — Codespaces / WiFi distant]"
	@echo "  tunnel-quick       Quick Tunnel (URL aleatoire trycloudflare.com)"
	@echo "  tunnel-install     Installer cloudflared"
	@echo "  tunnel-stop        Arreter le tunnel"
	@echo "  flutter-run        Lancer Flutter avec l'IP locale"
	@echo ""
	@echo "  [IA]"
	@echo "  ai-switch-gemini   Basculer sur Gemini API (defaut)"
	@echo "  ai-switch-ollama   Basculer sur Ollama (local)"
	@echo "  ai-switch-vllm     Basculer sur vLLM (GPU)"
	@echo "  ollama-pull        Telecharger les modeles Ollama"
	@echo ""
	@echo "  [MINIO]"
	@echo "  minio-buckets      Creer les buckets MinIO"
	@echo "  minio-console      Ouvrir la console MinIO"
	@echo ""
	@echo "  [TESTS]"
	@echo "  test-api           Tester les endpoints principaux"
	@echo "  test-ai            Tester l'extraction d'intention IA"
	@echo ""
	@echo "  [SAUVEGARDE]"
	@echo "  backup             Sauvegarder MongoDB + MinIO"
	@echo "  restore            Restaurer (BACKUP_DATE=YYYYMMDD-HHMMSS)"
	@echo ""
	@echo "  [DEBUG]"
	@echo "  shell-api          Shell dans le conteneur NestJS"
	@echo "  shell-mongo        mongosh dans MongoDB"
	@echo "  shell-redis        redis-cli dans Redis"
	@echo "  shell-minio        mc (MinIO client)"
	@echo ""
	@echo "  [NETTOYAGE]"
	@echo "  clean              Supprimer volumes + donnees (destructif!)"
	@echo "  clean-logs         Vider les logs"
	@echo ""
	@echo "  Windows CMD/PS:  scripts\\khidmeti.bat  or  scripts\\khidmeti.ps1"
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## GESTION DES SERVICES
## ══════════════════════════════════════════════════════════════════════════════

start: ## Demarrer (AI_PROVIDER=gemini par defaut)
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Demarrage de Khidmeti Backend..."
	@echo "══════════════════════════════════════════════"
	@mkdir -p logs backups/mongodb backups/minio data/mongodb data/redis data/qdrant data/minio
	@if [ ! -f .env ]; then \
		cp .env.example .env 2>/dev/null || true; \
		echo "⚠️  ATTENTION: .env cree — configurez FIREBASE_* et GEMINI_API_KEY"; \
	fi
	@docker compose up -d
	@echo ""
	@echo "  Attente du demarrage des services (15s)..."
	@sleep 15
	@$(MAKE) health
	@echo ""
	@$(MAKE) dns

start-local: ## Demarrer avec Ollama (16GB RAM requis)
	@echo "Demarrage avec Ollama (AI local)..."
	@docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
	@sleep 20
	@$(MAKE) ollama-pull
	@$(MAKE) health

start-gpu: ## Demarrer avec vLLM (GPU NVIDIA requis)
	@echo "Demarrage avec vLLM (GPU)..."
	@docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
	@$(MAKE) health

stop: ## Arreter tous les services
	@docker compose down
	@echo "✅ Services arretes."

stop-local:
	@docker compose -f docker-compose.yml -f docker-compose.local.yml down

stop-gpu:
	@docker compose -f docker-compose.yml -f docker-compose.gpu.yml down

restart: stop ## Redemarrer
	@sleep 3
	@$(MAKE) start

build: ## Builder l'image NestJS
	@docker compose build --no-cache api
	@echo "✅ Build termine."

rebuild: build start ## Rebuild complet + redemarrage

## ══════════════════════════════════════════════════════════════════════════════
## LOGS
## ══════════════════════════════════════════════════════════════════════════════

logs:       @docker compose logs --tail=100 -f
logs-api:   @docker compose logs -f api
logs-mongo: @docker compose logs -f mongo
logs-redis: @docker compose logs -f redis
logs-qdrant:@docker compose logs -f qdrant
logs-minio: @docker compose logs -f minio
logs-nginx: @docker compose logs -f nginx

## ══════════════════════════════════════════════════════════════════════════════
## DIAGNOSTIC
## ══════════════════════════════════════════════════════════════════════════════

health: ## Verifier la sante des services
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Etat des services Khidmeti"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo -n "  NestJS API  (port 3000) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE (HTTP $$code)"
	@echo -n "  nginx       (port 80)   : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost/health 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE (HTTP $$code)"
	@echo -n "  MongoDB     (port 27017): "; \
	  docker exec khidmeti-mongo mongosh --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1 \
	  && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Redis       (port 6379) : "; \
	  REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	  docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" ping >/dev/null 2>&1 \
	  && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  Qdrant      (port 6333) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:6333/healthz 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo -n "  MinIO API   (port 9001) : "; \
	  code=$$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9001/minio/health/live 2>/dev/null); \
	  [ "$$code" = "200" ] && echo "✅ OK" || echo "❌ HORS LIGNE"
	@echo ""

status: ## Statut des conteneurs
	@docker ps -a --filter "name=khidmeti" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

ai-status: ## Provider IA actif
	@docker exec khidmeti-api printenv AI_PROVIDER 2>/dev/null || echo "(conteneur non demarre)"

dns: ## Afficher les URLs + config Flutter
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  URLs des services  [host: $(HOST)]"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  API REST:          http://$(HOST):3000"
	@echo "  API via nginx:     http://$(HOST):80"
	@echo "  Swagger docs:      http://$(HOST):3000/api/docs"
	@echo "  Qdrant dashboard:  http://$(HOST):6333/dashboard"
	@echo "  MinIO console:     http://$(HOST):9002"
	@echo "  MinIO API (S3):    http://$(HOST):9001"
	@echo ""
	@echo "══════════════════════════════════════════════"
	@echo "  Config Flutter (meme WiFi)"
	@echo "══════════════════════════════════════════════"
	@echo ""
	@echo "  IP locale detectee: $(LOCAL_IP)"
	@echo ""
	@echo "  flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80"
	@echo ""
	@echo "  OU: collez l'URL Quick Tunnel dans Firebase Remote Config"
	@echo "      cle: api_base_url"
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## TUNNEL CLOUDFLARE — Quick Tunnel (pas de compte requis)
## ══════════════════════════════════════════════════════════════════════════════

tunnel-install: ## Installer cloudflared (Linux / WSL / Codespaces)
	@echo "Installation de cloudflared..."
	@if command -v cloudflared >/dev/null 2>&1; then \
		echo "✅ cloudflared deja installe: $$(cloudflared --version)"; \
	elif [ -f /etc/debian_version ] || grep -qi debian /etc/os-release 2>/dev/null || grep -qi ubuntu /etc/os-release 2>/dev/null; then \
		curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null 2>&1 || true; \
		curl -L --output /tmp/cloudflared.deb \
		  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb 2>/dev/null; \
		sudo dpkg -i /tmp/cloudflared.deb; \
		rm /tmp/cloudflared.deb; \
	elif [ "$(OS)" = "Darwin" ]; then \
		brew install cloudflared; \
	else \
		curl -L -o /usr/local/bin/cloudflared \
		  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; \
		chmod +x /usr/local/bin/cloudflared; \
	fi
	@cloudflared --version || echo "⚠️  Relancez votre terminal puis reessayez."
	@echo "✅ cloudflared installe."

tunnel-quick: ## Lancer un Quick Tunnel (URL aleatoire trycloudflare.com)
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Cloudflare Quick Tunnel — sans compte"
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "  1) Votre backend sera accessible via une URL HTTPS"
	@echo "     ex: https://random-words.trycloudflare.com"
	@echo ""
	@echo "  2) Copiez l'URL affichee ci-dessous"
	@echo ""
	@echo "  3) Firebase Console → Remote Config → api_base_url"
	@echo "     → collez l'URL → Publish"
	@echo ""
	@echo "  4) Tuez et relancez l'app Flutter"
	@echo ""
	@echo "  CTRL+C pour arreter le tunnel."
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@cloudflared tunnel --url http://localhost:80

tunnel-stop: ## Arreter le(s) tunnel(s) actif(s)
	@pkill -f 'cloudflared tunnel' 2>/dev/null && echo "✅ Tunnel(s) arretes." || echo "Aucun tunnel actif."

tunnel-status: ## Etat du tunnel
	@ps aux | grep 'cloudflared tunnel' | grep -v grep || echo "Aucun tunnel actif."

## ══════════════════════════════════════════════════════════════════════════════
## FLUTTER — raccourci avec IP locale
## ══════════════════════════════════════════════════════════════════════════════

flutter-run: ## Lance Flutter avec l'IP locale (Layer 2 fallback)
	@echo ""
	@echo "  Lancement Flutter avec:"
	@echo "  API_BASE_URL=http://$(LOCAL_IP):80"
	@echo ""
	@flutter run --dart-define=API_BASE_URL=http://$(LOCAL_IP):80

## ══════════════════════════════════════════════════════════════════════════════
## GESTION DE L'IA
## ══════════════════════════════════════════════════════════════════════════════

ai-switch-gemini: ## Basculer sur Gemini
	@$(SED_I) 's/^AI_PROVIDER=.*/AI_PROVIDER=gemini/' .env
	@docker compose up -d --no-deps api
	@echo "✅ Provider IA: GEMINI"

ai-switch-ollama: ## Basculer sur Ollama
	@$(SED_I) 's/^AI_PROVIDER=.*/AI_PROVIDER=ollama/' .env
	@docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
	@echo "✅ Provider IA: OLLAMA"

ai-switch-vllm: ## Basculer sur vLLM
	@$(SED_I) 's/^AI_PROVIDER=.*/AI_PROVIDER=vllm/' .env
	@docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
	@echo "✅ Provider IA: VLLM"

ollama-pull: ## Telecharger les modeles Ollama
	@docker exec khidmeti-ollama ollama pull gemma4:e2b
	@docker exec khidmeti-ollama ollama pull nomic-embed-text
	@echo "✅ Modeles telecharges."

## ══════════════════════════════════════════════════════════════════════════════
## MINIO
## ══════════════════════════════════════════════════════════════════════════════

minio-buckets: ## Creer les buckets MinIO manuellement
	@MINIO_ACCESS_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET_KEY=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-minio-init /bin/sh -c "\
		mc alias set local http://minio:9001 $$MINIO_ACCESS_KEY $$MINIO_SECRET_KEY && \
		mc mb --ignore-existing local/profile-images && \
		mc mb --ignore-existing local/service-media && \
		mc mb --ignore-existing local/audio-recordings && \
		mc anonymous set download local/profile-images && \
		echo '✅ Buckets crees.'"

minio-console: ## Ouvrir la console MinIO
	@$(OPEN_CMD) http://localhost:9002 2>/dev/null || echo "  → http://localhost:9002"

minio-list: ## Lister les fichiers MinIO
	@MINIO_ACCESS_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET_KEY=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run --rm --network khidmeti-network minio/mc:latest sh -c \
	  "mc alias set local http://minio:9001 $$MINIO_ACCESS_KEY $$MINIO_SECRET_KEY && \
	   mc ls local/profile-images; mc ls local/service-media"

## ══════════════════════════════════════════════════════════════════════════════
## TESTS API
## ══════════════════════════════════════════════════════════════════════════════

test-api: ## Tester les endpoints principaux
	@echo ""
	@echo "  [1] Health:"; curl -s http://localhost:3000/health
	@echo ""
	@echo "  [2] Swagger (HTTP code):"; curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/docs
	@echo ""
	@echo "  NOTE: Endpoints proteges requierent un token Firebase Bearer."

test-ai: ## Tester l'extraction d'intention IA (make test-ai TOKEN=xxx)
	@if [ -z "$(TOKEN)" ]; then \
		echo "Usage: make test-ai TOKEN=<firebase_id_token>"; \
	else \
		curl -s -X POST http://localhost:3000/ai/extract-intent \
		  -H "Authorization: Bearer $(TOKEN)" \
		  -H "Content-Type: application/json" \
		  -d '{"text": "jai une fuite deau sous levier"}'; \
	fi

test-upload: ## Tester l'upload d'image (make test-upload TOKEN=xxx FILE=/path/image.jpg)
	@if [ -z "$(TOKEN)" ] || [ -z "$(FILE)" ]; then \
		echo "Usage: make test-upload TOKEN=xxx FILE=/path/image.jpg"; \
	else \
		curl -s -X POST http://localhost:3000/media/upload/image \
		  -H "Authorization: Bearer $(TOKEN)" -F "file=@$(FILE)"; \
	fi

## ══════════════════════════════════════════════════════════════════════════════
## PARE-FEU
## ══════════════════════════════════════════════════════════════════════════════

firewall: ## Afficher les commandes pare-feu
	@echo ""
	@echo "  OS detecte: $(OS)"
	@echo ""
ifeq ($(OS),Linux)
	@echo "  # Ubuntu/Debian (ufw):"
	@echo "  sudo ufw allow 80/tcp 3000/tcp 6333/tcp 9001/tcp 9002/tcp"
else ifeq ($(OS),Darwin)
	@echo "  # macOS: Docker Desktop expose les ports automatiquement."
else
	@echo "  # Codespaces: onglet PORTS dans VS Code → forwarder 80, 3000, 9001."
	@echo "  # WSL: les ports sont automatiquement accessibles depuis Windows."
endif
	@echo ""

## ══════════════════════════════════════════════════════════════════════════════
## SAUVEGARDE
## ══════════════════════════════════════════════════════════════════════════════

backup: ## Sauvegarder MongoDB + MinIO
	@echo "Sauvegarde — $(DATETIME)"
	@mkdir -p backups/mongodb/$(DATETIME) backups/minio/$(DATETIME)
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongodump \
	  --username "$$MONGO_USER" --password "$$MONGO_PASS" \
	  --authenticationDatabase admin --db khidmeti \
	  --out /tmp/backup_$(DATETIME); \
	docker cp khidmeti-mongo:/tmp/backup_$(DATETIME) backups/mongodb/$(DATETIME); \
	echo "  ✅ MongoDB → backups/mongodb/$(DATETIME)"
	@MINIO_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run --rm --network khidmeti-network \
	  -v "$$(pwd)/backups/minio/$(DATETIME):/backup" minio/mc:latest \
	  sh -c "mc alias set local http://minio:9001 $$MINIO_KEY $$MINIO_SECRET \
	    && mc mirror local/profile-images /backup/profile-images \
	    && mc mirror local/service-media   /backup/service-media"; \
	echo "  ✅ MinIO → backups/minio/$(DATETIME)"

backup-mongo: ## Sauvegarder MongoDB uniquement
	@mkdir -p backups/mongodb/$(DATETIME)
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongodump \
	  --username "$$MONGO_USER" --password "$$MONGO_PASS" \
	  --authenticationDatabase admin --db khidmeti \
	  --out /tmp/backup_$(DATETIME); \
	docker cp khidmeti-mongo:/tmp/backup_$(DATETIME) backups/mongodb/$(DATETIME); \
	echo "✅ MongoDB sauvegarde: backups/mongodb/$(DATETIME)"

restore: ## Restaurer (BACKUP_DATE=YYYYMMDD-HHMMSS)
	@if [ -z "$(BACKUP_DATE)" ]; then \
		echo "Usage: make restore BACKUP_DATE=20250101-120000"; \
		echo "Sauvegardes: $$(ls backups/mongodb/ 2>/dev/null || echo aucune)"; \
		exit 1; \
	fi
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker cp backups/mongodb/$(BACKUP_DATE) khidmeti-mongo:/tmp/restore_$(BACKUP_DATE); \
	docker exec khidmeti-mongo mongorestore \
	  --username "$$MONGO_USER" --password "$$MONGO_PASS" \
	  --authenticationDatabase admin --db khidmeti --drop \
	  /tmp/restore_$(BACKUP_DATE)/khidmeti
	@echo "✅ Restauration terminee."

list-backups: ## Lister les sauvegardes
	@echo "MongoDB:"; ls backups/mongodb/ 2>/dev/null || echo "  (aucune)"
	@echo "MinIO:";   ls backups/minio/   2>/dev/null || echo "  (aucune)"

## ══════════════════════════════════════════════════════════════════════════════
## SHELL ET DEBUG
## ══════════════════════════════════════════════════════════════════════════════

shell-api: ## Shell dans le conteneur NestJS
	@docker exec -it khidmeti-api /bin/sh

shell-mongo: ## mongosh dans MongoDB
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec -it khidmeti-mongo mongosh -u "$$MONGO_USER" -p "$$MONGO_PASS" \
	  --authenticationDatabase admin khidmeti

shell-redis: ## redis-cli dans Redis
	@REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec -it khidmeti-redis redis-cli -a "$$REDIS_PASS"

shell-minio: ## mc client MinIO
	@MINIO_KEY=$$(grep MINIO_ACCESS_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	MINIO_SECRET=$$(grep MINIO_SECRET_KEY .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker run -it --rm --network khidmeti-network minio/mc:latest \
	  sh -c "mc alias set local http://minio:9001 $$MINIO_KEY $$MINIO_SECRET && sh"

shell-qdrant: ## Ouvrir le dashboard Qdrant
	@$(OPEN_CMD) http://localhost:6333/dashboard 2>/dev/null || echo "  → http://localhost:6333/dashboard"

mongo-stats: ## Stats MongoDB
	@MONGO_USER=$$(grep MONGO_ROOT_USER .env | cut -d= -f2 | tr -d '[:space:]'); \
	MONGO_PASS=$$(grep MONGO_ROOT_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-mongo mongosh -u "$$MONGO_USER" -p "$$MONGO_PASS" \
	  --authenticationDatabase admin khidmeti --quiet --eval "db.stats()"

redis-info: ## Stats Redis
	@REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" INFO server; \
	echo "Cles en cache:"; \
	docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" DBSIZE

redis-flush: ## Vider le cache Redis
	@REDIS_PASS=$$(grep REDIS_PASSWORD .env | cut -d= -f2 | tr -d '[:space:]'); \
	docker exec khidmeti-redis redis-cli -a "$$REDIS_PASS" FLUSHALL
	@echo "✅ Cache Redis vide."

## ══════════════════════════════════════════════════════════════════════════════
## NETTOYAGE
## ══════════════════════════════════════════════════════════════════════════════

clean-logs: ## Vider les logs
	@find logs/ -name "*.log" -delete 2>/dev/null || true
	@echo "✅ Logs nettoyes."

clean: ## Supprimer volumes + donnees (DESTRUCTIF)
	@echo ""
	@echo "  ⚠️  ATTENTION: suppression de TOUTES les donnees."
	@read -p "  Confirmer? [y/N] " CONFIRM; \
	if [ "$$CONFIRM" = "y" ] || [ "$$CONFIRM" = "Y" ]; then \
		docker compose down -v --remove-orphans; \
		docker system prune -f; \
		rm -rf data/mongodb data/redis data/qdrant data/minio; \
		echo "✅ Nettoyage termine."; \
	else \
		echo "Annule."; \
	fi

## ══════════════════════════════════════════════════════════════════════════════
## PRODUCTION
## ══════════════════════════════════════════════════════════════════════════════

prod-start: ## Demarrer en mode production
	@docker compose up -d
	@echo "✅ Mode production actif."

prod-update: ## Mettre a jour l'API sans downtime
	@docker compose build --no-cache api
	@docker compose up -d --no-deps --build api
	@echo "✅ API mise a jour."
