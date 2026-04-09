# ══════════════════════════════════════════════════════════════════════════════
# KHIDMETI BACKEND — PowerShell Script
# Usage:  .\scripts\khidmeti.ps1 [command]
# Alias:  Set-Alias kh .\scripts\khidmeti.ps1  (add to your $PROFILE)
#
# Requirements: Docker Desktop, PowerShell 5+
# ══════════════════════════════════════════════════════════════════════════════
param(
  [Parameter(Position=0)]
  [string]$Command = "help",
  [string]$Token   = "",
  [string]$File    = "",
  [string]$BackupDate = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Header([string]$text) {
  Write-Host "`n══════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  $text" -ForegroundColor White
  Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
}
function Write-Ok([string]$msg)   { Write-Host "  ✅ $msg" -ForegroundColor Green  }
function Write-Warn([string]$msg) { Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  ❌ $msg" -ForegroundColor Red    }
function Write-Info([string]$msg) { Write-Host "  $msg"    -ForegroundColor Gray   }

# ── Local IP detection ────────────────────────────────────────────────────────
function Get-LocalIp {
  $candidates = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp 2>$null |
    Where-Object { $_.IPAddress -match '^(192\.168|10\.|172\.(1[6-9]|2\d|3[01]))' } |
    Select-Object -First 1
  if ($candidates) { return $candidates.IPAddress }
  return "127.0.0.1"
}
$LOCAL_IP = Get-LocalIp

# ── .env reader ───────────────────────────────────────────────────────────────
function Get-EnvValue([string]$key) {
  if (-not (Test-Path ".env")) { return "" }
  $line = Get-Content ".env" | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
  if ($line) { return ($line -split "=", 2)[1].Trim() }
  return ""
}

# ── Health check helper ───────────────────────────────────────────────────────
function Test-Endpoint([string]$label, [string]$url) {
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
      Write-Ok "$label → HTTP $($resp.StatusCode)"
    } else {
      Write-Err "$label → HTTP $($resp.StatusCode)"
    }
  } catch {
    Write-Err "$label → OFFLINE"
  }
}

# ── COMMANDS ──────────────────────────────────────────────────────────────────

switch ($Command.ToLower()) {

  "help" {
    Write-Header "KHIDMETI — PowerShell Commands"
    Write-Host "  Local IP: $LOCAL_IP" -ForegroundColor Yellow
    Write-Host ""
    $cmds = @(
      @("start",       "Start all services (AI=gemini default)"),
      @("stop",        "Stop all services"),
      @("restart",     "Restart all services"),
      @("build",       "Build NestJS image"),
      @("rebuild",     "Rebuild + restart"),
      @("health",      "Check service health"),
      @("status",      "Show container status"),
      @("logs",        "Tail all logs (Ctrl+C to exit)"),
      @("logs-api",    "NestJS logs only"),
      @("dns",         "Show URLs + Flutter config"),
      @("tunnel",      "Start Cloudflare Quick Tunnel"),
      @("flutter-run", "Launch Flutter with local IP"),
      @("shell-api",   "Shell in NestJS container"),
      @("shell-mongo", "mongosh in MongoDB"),
      @("test-api",    "Test main endpoints"),
      @("clean",       "Remove ALL data (destructive!)")
    )
    foreach ($c in $cmds) {
      Write-Host ("  {0,-15} {1}" -f $c[0], $c[1]) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Info "Example: .\scripts\khidmeti.ps1 start"
    Write-Info "         .\scripts\khidmeti.ps1 flutter-run"
    Write-Host ""
  }

  "start" {
    Write-Header "Starting Khidmeti Backend..."
    @("logs","backups\mongodb","backups\minio","data\mongodb","data\redis","data\qdrant","data\minio") |
      ForEach-Object { if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null } }
    if (-not (Test-Path ".env")) {
      if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env"
        Write-Warn ".env created from .env.example — configure FIREBASE_* and GEMINI_API_KEY"
      }
    }
    docker compose up -d
    Write-Info "Waiting 15s for services..."
    Start-Sleep -Seconds 15
    & $PSCommandPath health
    & $PSCommandPath dns
  }

  "stop" {
    docker compose down
    Write-Ok "Services stopped."
  }

  "restart" {
    & $PSCommandPath stop
    Start-Sleep -Seconds 3
    & $PSCommandPath start
  }

  "build" {
    docker compose build --no-cache api
    Write-Ok "Build complete."
  }

  "rebuild" {
    & $PSCommandPath build
    & $PSCommandPath start
  }

  "health" {
    Write-Header "Service Health Check"
    Test-Endpoint "NestJS API  (3000)" "http://localhost:3000/health"
    Test-Endpoint "nginx       (80)  " "http://localhost/health"
    Test-Endpoint "Qdrant      (6333)" "http://localhost:6333/healthz"
    Test-Endpoint "MinIO API   (9001)" "http://localhost:9001/minio/health/live"
    Write-Info ""
    Write-Info "For MongoDB/Redis: docker ps --filter name=khidmeti"
    Write-Host ""
  }

  "status" {
    docker ps --filter "name=khidmeti" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  }

  "logs" {
    docker compose logs --tail=100 -f
  }

  "logs-api" {
    docker compose logs -f api
  }

  "dns" {
    Write-Header "Service URLs"
    Write-Host "  API REST:          http://localhost:3000"   -ForegroundColor White
    Write-Host "  API via nginx:     http://localhost:80"     -ForegroundColor White
    Write-Host "  Swagger docs:      http://localhost:3000/api/docs" -ForegroundColor White
    Write-Host "  Qdrant dashboard:  http://localhost:6333/dashboard" -ForegroundColor Gray
    Write-Host "  MinIO console:     http://localhost:9002"   -ForegroundColor Gray
    Write-Host ""
    Write-Header "Flutter Config (same WiFi)"
    Write-Host "  Local IP: $LOCAL_IP" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  flutter run --dart-define=API_BASE_URL=http://$($LOCAL_IP):80" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "OR: paste Quick Tunnel URL in Firebase Remote Config (key: api_base_url)"
    Write-Host ""
  }

  "tunnel" {
    Write-Header "Cloudflare Quick Tunnel (no account needed)"
    Write-Host ""
    Write-Host "  1) A random HTTPS URL will appear below" -ForegroundColor White
    Write-Host "     e.g. https://random-words.trycloudflare.com" -ForegroundColor Yellow
    Write-Host "  2) Copy it" -ForegroundColor White
    Write-Host "  3) Firebase Console → Remote Config → api_base_url → paste → Publish" -ForegroundColor White
    Write-Host "  4) Kill and relaunch Flutter app" -ForegroundColor White
    Write-Host ""
    Write-Host "  Press Ctrl+C to stop." -ForegroundColor Gray
    Write-Host ""
    $cf = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cf) {
      Write-Err "cloudflared not found."
      Write-Info "Download: https://github.com/cloudflare/cloudflared/releases/latest"
      Write-Info "Get cloudflared-windows-amd64.exe, rename to cloudflared.exe, add to PATH"
      exit 1
    }
    cloudflared tunnel --url http://localhost:80
  }

  "flutter-run" {
    Write-Host ""
    Write-Host "  Launching Flutter with API_BASE_URL=http://$($LOCAL_IP):80" -ForegroundColor Cyan
    Write-Host ""
    flutter run "--dart-define=API_BASE_URL=http://$($LOCAL_IP):80"
  }

  "shell-api" {
    docker exec -it khidmeti-api /bin/sh
  }

  "shell-mongo" {
    $user = Get-EnvValue "MONGO_ROOT_USER"
    $pass = Get-EnvValue "MONGO_ROOT_PASSWORD"
    docker exec -it khidmeti-mongo mongosh -u $user -p $pass --authenticationDatabase admin khidmeti
  }

  "test-api" {
    Write-Header "API Tests"
    Write-Host "  [1] Health:"
    try { (Invoke-WebRequest -Uri "http://localhost:3000/health" -UseBasicParsing).Content } catch { Write-Err "OFFLINE" }
    Write-Host ""
    Write-Host "  [2] Swagger:"
    try { Write-Ok "HTTP $((Invoke-WebRequest -Uri 'http://localhost:3000/api/docs' -UseBasicParsing).StatusCode)" } catch { Write-Err "OFFLINE" }
    Write-Host ""
    Write-Info "Protected endpoints require a Firebase Bearer token."
    Write-Info "Swagger UI: http://localhost:3000/api/docs"
    Write-Host ""
  }

  "clean" {
    Write-Host ""
    Write-Err "WARNING: This will DELETE ALL DATA (MongoDB, Redis, Qdrant, MinIO)"
    $confirm = Read-Host "  Type YES to confirm"
    if ($confirm -eq "YES") {
      docker compose down -v --remove-orphans
      @("data\mongodb","data\redis","data\qdrant","data\minio") |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Remove-Item -Recurse -Force $_ }
      Write-Ok "Cleanup complete."
    } else {
      Write-Info "Cancelled."
    }
  }

  default {
    Write-Err "Unknown command: $Command"
    Write-Info "Run: .\scripts\khidmeti.ps1 help"
    exit 1
  }
}
