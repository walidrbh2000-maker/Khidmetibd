## ══════════════════════════════════════════════════════════════════════════════
## KHIDMETI BACKEND — Makefile additions (append to existing Makefile)
## ══════════════════════════════════════════════════════════════════════════════
##
## CLOUDFLARE NAMED TUNNEL — one-time setup (see tunnel-setup below)
## Once configured, the URL  https://khidmeti-dev.YOUR_DOMAIN.com  never changes.
## Your phone always uses the same URL. No IP, no hostname, no rebuild.
## ══════════════════════════════════════════════════════════════════════════════

.PHONY: tunnel tunnel-setup tunnel-stop tunnel-status tunnel-install

## ── Install cloudflared ───────────────────────────────────────────────────────
tunnel-install: ## Install cloudflared CLI (Linux / Codespaces)
	@echo "Installing cloudflared..."
	@curl -L --output cloudflared.deb \
	  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
	@sudo dpkg -i cloudflared.deb
	@rm cloudflared.deb
	@cloudflared --version
	@echo "✅ cloudflared installed."

## ── ONE-TIME SETUP (run only once per machine/account) ───────────────────────
tunnel-setup: ## Create the named tunnel "khidmeti" (run ONCE, then commit credentials)
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Cloudflare Named Tunnel — One-Time Setup"
	@echo "  You need a Cloudflare account and a domain on it."
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@echo "Step 1/4 — Login to Cloudflare (opens browser):"
	@cloudflared tunnel login
	@echo ""
	@echo "Step 2/4 — Create named tunnel:"
	@cloudflared tunnel create khidmeti
	@echo ""
	@echo "Step 3/4 — Route DNS (replace YOUR_DOMAIN with your domain):"
	@echo "  Run: cloudflared tunnel route dns khidmeti api-dev.YOUR_DOMAIN.com"
	@echo "  (this creates a CNAME in Cloudflare DNS automatically)"
	@echo ""
	@echo "Step 4/4 — Create config file (replace YOUR_DOMAIN):"
	@mkdir -p ~/.cloudflared
	@echo "tunnel: khidmeti"                                    > ~/.cloudflared/config.yml
	@echo "credentials-file: ~/.cloudflared/TUNNEL_ID.json"   >> ~/.cloudflared/config.yml
	@echo "ingress:"                                            >> ~/.cloudflared/config.yml
	@echo "  - hostname: api-dev.YOUR_DOMAIN.com"              >> ~/.cloudflared/config.yml
	@echo "    service: http://localhost:80"                    >> ~/.cloudflared/config.yml
	@echo "  - service: http_status:404"                       >> ~/.cloudflared/config.yml
	@echo ""
	@echo "Edit ~/.cloudflared/config.yml with your real tunnel ID and domain."
	@echo "Then update app_config.dart:  _compileFallback = 'https://api-dev.YOUR_DOMAIN.com'"
	@echo "And Firebase Remote Config:   api_base_url = 'https://api-dev.YOUR_DOMAIN.com'"
	@echo ""
	@echo "✅ Setup guide complete. Run 'make tunnel' to start."

## ── START TUNNEL ─────────────────────────────────────────────────────────────
tunnel: ## Start Cloudflare tunnel (run alongside: make start)
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo "  Starting Cloudflare Named Tunnel 'khidmeti'..."
	@echo "  Your backend will be reachable at the configured URL."
	@echo "  Keep this terminal open while testing with the phone."
	@echo "══════════════════════════════════════════════════════"
	@echo ""
	@cloudflared tunnel run khidmeti

## ── START EVERYTHING ─────────────────────────────────────────────────────────
start-with-tunnel: ## Start backend + tunnel in parallel (requires tmux or 2 terminals)
	@echo "Starting backend..."
	@$(MAKE) start &
	@sleep 18
	@echo "Starting tunnel..."
	@$(MAKE) tunnel

## ── STOP TUNNEL ──────────────────────────────────────────────────────────────
tunnel-stop: ## Stop the tunnel (Ctrl+C in tunnel terminal, or kill the process)
	@pkill -f 'cloudflared tunnel' 2>/dev/null && echo "✅ Tunnel stopped." || echo "Tunnel not running."

## ── STATUS ───────────────────────────────────────────────────────────────────
tunnel-status: ## Show tunnel status
	@echo ""
	@cloudflared tunnel info khidmeti 2>/dev/null || echo "Tunnel 'khidmeti' not found. Run: make tunnel-setup"
	@echo ""
