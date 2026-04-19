# ══════════════════════════════════════════════════════════════════════════════
# KHIDMETI BACKEND — PowerShell Script
# Usage:  .\khidmeti.ps1 [command] [args]
# Alias:  Set-Alias kh .\khidmeti.ps1
#
# WORKFLOW :
#   .\khidmeti.ps1 start        → 1ère fois : pull modèle + démarrage
#   .\khidmeti.ps1 start        → fois suivantes : démarrage instantané (volume)
#   .\khidmeti.ps1 ollama-pull  → forcer re-pull avec progression visible
# ══════════════════════════════════════════════════════════════════════════════
param(
  [Parameter(Position=0)]
  [string]$Command = "help",

  [Parameter(Position=1, ValueFromRemainingArguments)]
  [string[]]$ScriptArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Couleurs ──────────────────────────────────────────────────────────────────
function Write-Header([string]$text) {
  Write-Host "`n══════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  $text" -ForegroundColor White
  Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
}
function Write-Ok([string]$msg)   { Write-Host "  ✅ $msg" -ForegroundColor Green  }
function Write-Warn([string]$msg) { Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  ❌ $msg" -ForegroundColor Red    }
function Write-Info([string]$msg) { Write-Host "  $msg"    -ForegroundColor Gray   }
function Write-Step([string]$msg) { Write-Host "  → $msg"  -ForegroundColor White  }

# ── IP locale ─────────────────────────────────────────────────────────────────
function Get-LocalIp {
  $ip = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp 2>$null |
    Where-Object { $_.IPAddress -match '^(192\.168|10\.|172\.(1[6-9]|2\d|3[01]))' } |
    Select-Object -First 1
  if ($ip) { return $ip.IPAddress }
  return "127.0.0.1"
}
$LOCAL_IP = Get-LocalIp

# ── Lire .env ─────────────────────────────────────────────────────────────────
function Get-EnvValue([string]$key) {
  if (-not (Test-Path ".env")) { return "" }
  $line = Get-Content ".env" | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
  if ($line) { return ($line -split "=", 2)[1].Trim() }
  return ""
}

function Set-EnvValue([string]$key, [string]$value) {
  if (-not (Test-Path ".env")) { return }
  $content = Get-Content ".env"
  if ($content | Where-Object { $_ -match "^$key=" }) {
    $content = $content -replace "^$key=.*", "$key=$value"
  } else {
    $content += "$key=$value"
  }
  $content | Set-Content ".env" -Encoding UTF8
}

function Remove-EnvValue([string]$key) {
  if (-not (Test-Path ".env")) { return }
  $content = Get-Content ".env" | Where-Object { $_ -notmatch "^$key=" }
  $content | Set-Content ".env" -Encoding UTF8
}

# ── Modèle Ollama ─────────────────────────────────────────────────────────────
$OllamaModel = Get-EnvValue "OLLAMA_MODEL"
if ($OllamaModel -eq "") { $OllamaModel = "gemma4:e2b" }

# ── Attendre Ollama ───────────────────────────────────────────────────────────
function Wait-Ollama {
  Write-Host "  ⏳ Attente que Ollama soit prêt..." -ForegroundColor Gray
  $ready = $false
  while (-not $ready) {
    try {
      $r = Invoke-WebRequest -Uri "http://localhost:11434/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
      if ($r.StatusCode -eq 200) { $ready = $true }
    } catch { Start-Sleep -Seconds 2 }
  }
  Write-Ok "Ollama prêt."
}

# ── Vérifier si modèle présent ────────────────────────────────────────────────
function Test-ModelPresent([string]$model) {
  $result = docker exec khidmeti-ollama ollama list 2>$null
  return ($result -match [regex]::Escape($model.Split(":")[0]))
}

# ── Pull avec progression visible ─────────────────────────────────────────────
function Invoke-OllamaPull([string]$model) {
  Write-Host ""
  Write-Host "  📥 Téléchargement en cours (progression ci-dessous) :" -ForegroundColor Yellow
  Write-Host "  ex: pulling abc123... ████████░░ 4.1 GB / 7.2 GB  32 MB/s  1m58s" -ForegroundColor Gray
  Write-Host ""
  # docker exec -it pour avoir le TTY et voir la barre de progression native d'Ollama
  docker exec -it khidmeti-ollama ollama pull $model
  if ($LASTEXITCODE -ne 0) {
    Write-Err "Pull échoué."
    exit 1
  }
  Write-Host ""
  Write-Ok "Modèle $model prêt."
}

# ── Health check ──────────────────────────────────────────────────────────────
function Test-Endpoint([string]$label, [string]$url) {
  try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
      Write-Ok "$label → HTTP $($resp.StatusCode)"
    } else {
      Write-Err "$label → HTTP $($resp.StatusCode)"
    }
  } catch {
    Write-Err "$label → HORS LIGNE"
  }
}

# ── Scripts ───────────────────────────────────────────────────────────────────
function Invoke-Migration([string]$filePath) {
  $mongoUser = Get-EnvValue "MONGO_ROOT_USER"
  $mongoPass = Get-EnvValue "MONGO_ROOT_PASSWORD"
  $name = Split-Path $filePath -Leaf
  Write-Step "Migration : $name"
  $content = Get-Content $filePath -Raw
  $content | docker exec -i khidmeti-mongo mongosh `
    --quiet -u $mongoUser -p $mongoPass `
    --authenticationDatabase admin khidmeti
  return $LASTEXITCODE -eq 0
}

function Invoke-Seed([string]$filePath, [string[]]$extraArgs = @()) {
  $name = Split-Path $filePath -Leaf
  Write-Step "Seed : $name $(if ($extraArgs.Count -gt 0) { $extraArgs -join ' ' })"
  docker exec khidmeti-api `
    npx ts-node --project tsconfig.json "src/scripts/seeds/$name" @extraArgs
  return $LASTEXITCODE -eq 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Détection commande scripts-<nom>
# ══════════════════════════════════════════════════════════════════════════════
if ($Command -like "scripts-*" -and
    $Command -ne "scripts-migrations" -and
    $Command -ne "scripts-seeds") {

  $scriptName = $Command.Substring(8)
  $migPath  = "scripts\migrations\$scriptName.js"
  $seedPath = "apps\api\src\scripts\seeds\$scriptName.ts"
  Write-Host ""

  if (Test-Path $migPath) {
    $ok = Invoke-Migration $migPath
    if ($ok) { Write-Ok "$scriptName.js OK" } else { Write-Err "ECHEC"; exit 1 }
  } elseif (Test-Path $seedPath) {
    $ok = Invoke-Seed $seedPath $ScriptArgs
    if ($ok) { Write-Ok "$scriptName.ts OK" } else { Write-Err "ECHEC"; exit 1 }
  } else {
    Write-Err "Script '$scriptName' introuvable."
    Get-ChildItem "scripts\migrations\*.js" -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Info "  migration: $($_.BaseName)" }
    Get-ChildItem "apps\api\src\scripts\seeds\*.ts" -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Info "  seed: $($_.BaseName)" }
    exit 1
  }
  Write-Host ""
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# COMMANDES
# ══════════════════════════════════════════════════════════════════════════════
switch ($Command.ToLower()) {

  # ── help ────────────────────────────────────────────────────────────────────
  "help" {
    Write-Header "KHIDMETI — Commandes PowerShell"
    Write-Host "  IP locale : $LOCAL_IP" -ForegroundColor Yellow
    Write-Host "  Modèle    : $OllamaModel" -ForegroundColor Yellow
    Write-Host ""
    @(
      @("[DÉMARRAGE]",            ""),
      @("start",                  "Démarrer + pull modèle si absent (progression visible)"),
      @("start-gpu",              "Démarrer avec GPU NVIDIA"),
      @("stop",                   "Arrêter (volumes conservés — modèle intact)"),
      @("restart",                "Redémarrer"),
      @("",                       ""),
      @("[OLLAMA]",               ""),
      @("ollama-pull",            "Pull / mise à jour du modèle (X GB / Y GB visible)"),
      @("",                       ""),
      @("[BUILD API]",            ""),
      @("build",                  "Builder l'image NestJS"),
      @("rebuild",                "Rebuild NestJS + redémarrage"),
      @("",                       ""),
      @("[LOGS]",                 ""),
      @("logs",                   "Tous les logs"),
      @("logs-api",               "Logs NestJS"),
      @("logs-ollama",            "Logs Ollama"),
      @("logs-whisper",           "Logs faster-whisper"),
      @("",                       ""),
      @("[DIAGNOSTIC]",           ""),
      @("health",                 "Santé de tous les services"),
      @("ai-status",              "Statut IA + modèles installés"),
      @("status",                 "Statut des conteneurs"),
      @("dns",                    "URLs + config Flutter"),
      @("",                       ""),
      @("[TUNNEL]",               ""),
      @("ngrok",                  "Tunnel ngrok PERMANENT — recommandé"),
      @("tunnel",                 "Cloudflare Quick Tunnel"),
      @("",                       ""),
      @("[SCRIPTS]",              ""),
      @("scripts",                "Tout exécuter (migrations + seeds)"),
      @("scripts-migrations",     "Migrations seulement"),
      @("scripts-seeds",          "Seeds seulement"),
      @("scripts-<nom>",          "Un script précis"),
      @("",                       ""),
      @("[DEBUG]",                ""),
      @("shell-api",              "Shell NestJS"),
      @("shell-mongo",            "mongosh"),
      @("test-api",               "Tester les endpoints"),
      @("test-ai",                "Tester extraction Darija"),
      @("",                       ""),
      @("[NETTOYAGE]",            ""),
      @("clean",                  "Supprimer tous les volumes (modèle inclus)")
    ) | ForEach-Object {
      if ($_[1] -eq "" -and $_[0] -ne "") {
        Write-Host "`n  $($_[0])" -ForegroundColor Cyan
      } elseif ($_[0] -ne "") {
        Write-Host ("  {0,-30} {1}" -f $_[0], $_[1]) -ForegroundColor Gray
      }
    }
    Write-Host ""
  }

  # ── ollama-pull ──────────────────────────────────────────────────────────────
  "ollama-pull" {
    Write-Header "Pull modèle Ollama"
    Write-Host "  Modèle : $OllamaModel" -ForegroundColor Yellow
    Wait-Ollama
    Invoke-OllamaPull $OllamaModel
  }

  # ── start ────────────────────────────────────────────────────────────────────
  "start" {
    Write-Header "Démarrage de Khidmeti"
    Write-Host "  Modèle IA : $OllamaModel" -ForegroundColor Yellow
    Write-Host ""

    @("logs","backups\mongodb","data\mongodb","data\redis","data\qdrant","data\minio") |
      ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
      }

    if (-not (Test-Path ".env")) {
      if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env"
        Write-Warn ".env créé depuis .env.example — configurez FIREBASE_*"
      }
    }

    Write-Host "  🚀 Démarrage des services..." -ForegroundColor White
    docker compose up -d
    Write-Host ""
    Write-Ok "Services démarrés."
    Write-Host ""

    Wait-Ollama
    Write-Host ""

    if (Test-ModelPresent $OllamaModel) {
      Write-Ok "Modèle $OllamaModel déjà présent — démarrage instantané."
      Write-Host ""
    } else {
      Write-Warn "Modèle absent du volume — téléchargement en cours..."
      Invoke-OllamaPull $OllamaModel
    }

    & $PSCommandPath health
    & $PSCommandPath dns
  }

  # ── start-gpu ────────────────────────────────────────────────────────────────
  "start-gpu" {
    Write-Header "Démarrage Khidmeti — GPU NVIDIA"
    Write-Host "  Modèle : $OllamaModel" -ForegroundColor Yellow
    Write-Host ""
    docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
    Write-Host ""
    Wait-Ollama
    if (-not (Test-ModelPresent $OllamaModel)) {
      Invoke-OllamaPull $OllamaModel
    } else {
      Write-Ok "Modèle $OllamaModel déjà présent."
    }
    & $PSCommandPath health
  }

  # ── stop ─────────────────────────────────────────────────────────────────────
  "stop" {
    docker compose down
    Write-Host ""
    Write-Ok "Services arrêtés."
    Write-Info "Le modèle Ollama est conservé dans le volume khidmeti-ollama-data."
    Write-Host ""
  }

  "restart" {
    & $PSCommandPath stop
    Start-Sleep -Seconds 3
    & $PSCommandPath start
  }

  # ── build ────────────────────────────────────────────────────────────────────
  "build" {
    docker compose build --no-cache api
    Write-Ok "Build NestJS terminé."
  }

  "rebuild" {
    & $PSCommandPath build
    & $PSCommandPath start
  }

  # ── logs ─────────────────────────────────────────────────────────────────────
  "logs"         { docker compose logs --tail=100 -f }
  "logs-api"     { docker compose logs -f api }
  "logs-mongo"   { docker compose logs -f mongo }
  "logs-redis"   { docker compose logs -f redis }
  "logs-ollama"  { docker compose logs -f ollama }
  "logs-whisper" { docker compose logs -f whisper }

  # ── health ───────────────────────────────────────────────────────────────────
  "health" {
    Write-Header "État des services"
    Test-Endpoint "NestJS API  (3000) " "http://localhost:3000/health"
    Test-Endpoint "nginx       (80)   " "http://localhost/health"
    Test-Endpoint "Qdrant      (6333) " "http://localhost:6333/healthz"
    Test-Endpoint "MinIO       (9001) " "http://localhost:9001/minio/health/live"
    Test-Endpoint "Ollama      (11434)" "http://localhost:11434/"
    Test-Endpoint "Whisper     (8000) " "http://localhost:8000/health"
    Write-Host ""
  }

  # ── ai-status ────────────────────────────────────────────────────────────────
  "ai-status" {
    Write-Header "Statut IA locale"
    Test-Endpoint "Ollama  (11434)" "http://localhost:11434/"
    Test-Endpoint "Whisper (8000) " "http://localhost:8000/health"
    Write-Host ""
    Write-Host "  Modèles installés :" -ForegroundColor Gray
    docker exec khidmeti-ollama ollama list 2>$null | ForEach-Object {
      Write-Host "   $_" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  Volume :" -ForegroundColor Gray
    docker volume inspect khidmeti-ollama-data `
      --format "   Chemin : {{.Mountpoint}}" 2>$null
    Write-Host ""
  }

  "status" {
    docker ps --filter "name=khidmeti" `
      --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}"
  }

  # ── dns ──────────────────────────────────────────────────────────────────────
  "dns" {
    Write-Header "URLs des services"
    Write-Host "  API REST       :  http://localhost:3000"           -ForegroundColor White
    Write-Host "  API via nginx  :  http://localhost:80"             -ForegroundColor White
    Write-Host "  Swagger docs   :  http://localhost:3000/api/docs"  -ForegroundColor White
    Write-Host "  Mongo Express  :  http://localhost:8081"           -ForegroundColor Gray
    Write-Host "  Qdrant UI      :  http://localhost:6333/dashboard" -ForegroundColor Gray
    Write-Host "  MinIO console  :  http://localhost:9002"           -ForegroundColor Gray
    Write-Host "  Ollama API     :  http://localhost:11434"          -ForegroundColor Gray
    Write-Host "  Whisper API    :  http://localhost:8000"           -ForegroundColor Gray
    Write-Host ""
    Write-Header "Config Flutter (même WiFi)"
    Write-Host "  IP locale : $LOCAL_IP" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  flutter run --dart-define=API_BASE_URL=http://$($LOCAL_IP):80" -ForegroundColor Cyan
    $ngrokDomain = Get-EnvValue "NGROK_DOMAIN"
    if ($ngrokDomain -ne "") {
      Write-Host ""
      Write-Host "  Tunnel ngrok : https://$ngrokDomain" -ForegroundColor Green
      Write-Host "  flutter run --dart-define=API_BASE_URL=https://$ngrokDomain" -ForegroundColor Cyan
    }
    Write-Host ""
  }

  # ── tunnel ───────────────────────────────────────────────────────────────────
  "tunnel" {
    Write-Header "Cloudflare Quick Tunnel"
    Write-Host "  Ctrl+C pour arrêter. URL permanente : .\khidmeti.ps1 ngrok" -ForegroundColor Gray
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
      Write-Err "cloudflared introuvable. https://github.com/cloudflare/cloudflared/releases/latest"
      exit 1
    }
    cloudflared tunnel --url http://localhost:80
  }

  # ── ngrok-install ─────────────────────────────────────────────────────────────
  "ngrok-install" {
    Write-Header "Installation de ngrok (Windows)"
    if (Get-Command ngrok -ErrorAction SilentlyContinue) {
      Write-Ok "ngrok déjà installé : $(ngrok --version)"
    } else {
      $zipPath  = "$env:TEMP\ngrok.zip"
      $destPath = "C:\ngrok"
      try {
        Invoke-WebRequest -Uri "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" `
          -OutFile $zipPath -UseBasicParsing
        if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath -Force | Out-Null }
        Expand-Archive -Path $zipPath -DestinationPath $destPath -Force
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        Write-Ok "ngrok extrait dans $destPath"
        Write-Warn "Ajoutez $destPath à votre PATH :"
        Write-Host '  [System.Environment]::SetEnvironmentVariable("PATH", $env:PATH+";C:\ngrok", "Machine")' -ForegroundColor Cyan
      } catch {
        Write-Err "Echec : $_"
        Write-Info "Téléchargez manuellement : https://ngrok.com/download"
      }
    }
    Write-Host ""
    Write-Info "Étapes : 1. https://dashboard.ngrok.com/signup"
    Write-Info "         2. https://dashboard.ngrok.com/get-started/your-authtoken"
    Write-Info "         3. https://dashboard.ngrok.com/domains"
    Write-Info "         4. .\khidmeti.ps1 ngrok"
    Write-Host ""
  }

  # ── ngrok ────────────────────────────────────────────────────────────────────
  "ngrok" {
    Write-Header "Tunnel ngrok — Domaine statique permanent"
    if (-not (Get-Command ngrok -ErrorAction SilentlyContinue)) {
      Write-Err "ngrok introuvable. Lancez : .\khidmeti.ps1 ngrok-install"
      exit 1
    }
    $ngrokToken = Get-EnvValue "NGROK_AUTH_TOKEN"
    if ($ngrokToken -eq "") {
      Write-Host "  https://dashboard.ngrok.com/get-started/your-authtoken" -ForegroundColor Gray
      $ngrokToken = Read-Host "  Auth Token"
      Set-EnvValue "NGROK_AUTH_TOKEN" $ngrokToken
      Write-Ok "Token sauvegardé dans .env"
    }
    ngrok config add-authtoken $ngrokToken 2>$null | Out-Null

    $ngrokDomain = Get-EnvValue "NGROK_DOMAIN"
    if ($ngrokDomain -eq "") {
      Write-Host "  https://dashboard.ngrok.com/domains" -ForegroundColor Gray
      $ngrokDomain = Read-Host "  Domaine statique"
      Set-EnvValue "NGROK_DOMAIN" $ngrokDomain
      Write-Ok "Domaine sauvegardé dans .env"
    }
    Write-Host ""
    Write-Host "  URL : https://$ngrokDomain" -ForegroundColor Green
    Write-Host "  flutter run --dart-define=API_BASE_URL=https://$ngrokDomain" -ForegroundColor Cyan
    Write-Host "  → Ctrl+C pour arrêter" -ForegroundColor Gray
    Write-Host ""
    ngrok http "--domain=$ngrokDomain" 80
  }

  "ngrok-reset" {
    Remove-EnvValue "NGROK_AUTH_TOKEN"
    Remove-EnvValue "NGROK_DOMAIN"
    Write-Ok "Config ngrok supprimée."
  }

  "flutter-run" {
    Write-Host ""
    Write-Host "  flutter run --dart-define=API_BASE_URL=http://$($LOCAL_IP):80" -ForegroundColor Cyan
    flutter run "--dart-define=API_BASE_URL=http://$($LOCAL_IP):80"
  }

  # ── shells ───────────────────────────────────────────────────────────────────
  "shell-api"   { docker exec -it khidmeti-api /bin/sh }

  "shell-mongo" {
    $user = Get-EnvValue "MONGO_ROOT_USER"
    $pass = Get-EnvValue "MONGO_ROOT_PASSWORD"
    docker exec -it khidmeti-mongo mongosh -u $user -p $pass --authenticationDatabase admin khidmeti
  }

  "shell-redis" {
    $pass = Get-EnvValue "REDIS_PASSWORD"
    docker exec -it khidmeti-redis redis-cli -a $pass
  }

  # ── tests ────────────────────────────────────────────────────────────────────
  "test-api" {
    Write-Header "Tests API"
    try { Write-Host "  Health : $((Invoke-WebRequest -Uri 'http://localhost:3000/health' -UseBasicParsing).Content)" }
    catch { Write-Err "HORS LIGNE" }
    try { Write-Ok "Swagger : HTTP $((Invoke-WebRequest -Uri 'http://localhost:3000/api/docs' -UseBasicParsing).StatusCode)" }
    catch { Write-Err "Swagger HORS LIGNE" }
    Write-Host ""
  }

  "test-ai" {
    Write-Header "Test Ollama — extraction Darija"
    $body = @{
      model    = $OllamaModel
      messages = @(
        @{ role="system"; content='Réponds UNIQUEMENT en JSON: {"profession":null,"is_urgent":false,"problem_description":"","confidence":0}' },
        @{ role="user";   content="عندي ماء ساقط من السقف" }
      )
      options     = @{ num_ctx=2048; think=$false }
      temperature = 0.05
      max_tokens  = 200
      stream      = $false
    } | ConvertTo-Json -Depth 5
    try {
      $resp = Invoke-RestMethod -Uri "http://localhost:11434/v1/chat/completions" `
        -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60
      Write-Host ($resp | ConvertTo-Json -Depth 5) -ForegroundColor Green
    } catch { Write-Err "Ollama non disponible : $_" }
    Write-Host ""
  }

  # ── scripts ──────────────────────────────────────────────────────────────────
  "scripts" {
    & $PSCommandPath scripts-migrations
    & $PSCommandPath scripts-seeds
  }

  "scripts-migrations" {
    Write-Header "Migrations MongoDB"
    $files = Get-ChildItem "scripts\migrations\*.js" -ErrorAction SilentlyContinue
    if (-not $files) { Write-Info "Aucune migration trouvée."; return }
    $ok = 0; $failed = 0
    foreach ($f in $files) {
      if (Invoke-Migration $f.FullName) { Write-Ok "$($f.Name) OK"; $ok++ }
      else { Write-Err "$($f.Name) ECHEC"; $failed++ }
    }
    Write-Info "Résultat : $ok OK  |  $failed échec(s)"
    Write-Host ""
    if ($failed -gt 0) { exit 1 }
  }

  "scripts-seeds" {
    Write-Header "Seeds TypeScript"
    $files = Get-ChildItem "apps\api\src\scripts\seeds\*.ts" -ErrorAction SilentlyContinue
    if (-not $files) { Write-Info "Aucun seed trouvé."; return }
    $ok = 0; $failed = 0
    foreach ($f in $files) {
      if (Invoke-Seed $f.FullName $ScriptArgs) { Write-Ok "$($f.Name) OK"; $ok++ }
      else { Write-Err "$($f.Name) ECHEC"; $failed++ }
    }
    Write-Info "Résultat : $ok OK  |  $failed échec(s)"
    Write-Host ""
    if ($failed -gt 0) { exit 1 }
  }

  # ── clean ────────────────────────────────────────────────────────────────────
  "clean" {
    Write-Host ""
    Write-Warn "Supprime TOUS les volumes : MongoDB, Redis, Qdrant, MinIO, Ollama."
    Write-Host "  Le modèle sera re-téléchargé au prochain : .\khidmeti.ps1 start" -ForegroundColor Gray
    $confirm = Read-Host "  Taper YES pour confirmer"
    if ($confirm -eq "YES") {
      docker compose down -v --remove-orphans
      @("data\mongodb","data\redis","data\qdrant","data\minio") |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Remove-Item -Recurse -Force $_ }
      Write-Ok "Nettoyage terminé."
    } else {
      Write-Info "Annulé."
    }
  }

  default {
    Write-Err "Commande inconnue : $Command"
    Write-Info "Utilisation : .\khidmeti.ps1 help"
    exit 1
  }
}
