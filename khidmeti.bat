@echo off
:: ══════════════════════════════════════════════════════════════════════════════
:: KHIDMETI BACKEND — Windows CMD Script
:: Usage: scripts\khidmeti.bat [command]
::
:: Requirements: Docker Desktop, Git Bash (optional but recommended)
:: Recommended:  Run Docker Desktop as Administrator
::
:: Commands:
::   start          Start all services
::   stop           Stop all services
::   restart        Restart all services
::   build          Build NestJS image
::   health         Check service health
::   logs           Tail all logs
::   tunnel         Start Cloudflare Quick Tunnel
::   flutter-run    Launch Flutter with local IP
::   status         Show container status
::   clean          Remove all data (destructive)
::   help           Show this help
:: ══════════════════════════════════════════════════════════════════════════════
setlocal enabledelayedexpansion

:: ── Get local IP ──────────────────────────────────────────────────────────────
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /r "IPv4.*192\."') do (
  set LOCAL_IP=%%a
  set LOCAL_IP=!LOCAL_IP: =!
  goto :ip_found
)
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /r "IPv4.*10\."') do (
  set LOCAL_IP=%%a
  set LOCAL_IP=!LOCAL_IP: =!
  goto :ip_found
)
set LOCAL_IP=127.0.0.1
:ip_found

:: ── Route command ─────────────────────────────────────────────────────────────
set CMD=%1
if "%CMD%"=="" goto :help
if "%CMD%"=="help"        goto :help
if "%CMD%"=="start"       goto :start
if "%CMD%"=="stop"        goto :stop
if "%CMD%"=="restart"     goto :restart
if "%CMD%"=="build"       goto :build
if "%CMD%"=="rebuild"     goto :rebuild
if "%CMD%"=="health"      goto :health
if "%CMD%"=="status"      goto :status
if "%CMD%"=="logs"        goto :logs
if "%CMD%"=="logs-api"    goto :logs_api
if "%CMD%"=="tunnel"      goto :tunnel
if "%CMD%"=="flutter-run" goto :flutter_run
if "%CMD%"=="clean"       goto :clean
if "%CMD%"=="dns"         goto :dns
if "%CMD%"=="shell-api"   goto :shell_api
if "%CMD%"=="shell-mongo" goto :shell_mongo
if "%CMD%"=="test-api"    goto :test_api

echo Unknown command: %CMD%
echo Run: scripts\khidmeti.bat help
exit /b 1

:: ── HELP ──────────────────────────────────────────────────────────────────────
:help
echo.
echo ══════════════════════════════════════════════════════
echo   KHIDMETI — Windows CMD Commands
echo   Local IP detected: %LOCAL_IP%
echo ══════════════════════════════════════════════════════
echo.
echo   scripts\khidmeti.bat start          Start all services
echo   scripts\khidmeti.bat stop           Stop all services
echo   scripts\khidmeti.bat restart        Restart all services
echo   scripts\khidmeti.bat build          Build NestJS image
echo   scripts\khidmeti.bat rebuild        Rebuild + restart
echo   scripts\khidmeti.bat health         Check service health
echo   scripts\khidmeti.bat status         Container status
echo   scripts\khidmeti.bat logs           All logs (Ctrl+C to exit)
echo   scripts\khidmeti.bat logs-api       NestJS logs only
echo   scripts\khidmeti.bat dns            Show URLs + Flutter config
echo   scripts\khidmeti.bat tunnel         Cloudflare Quick Tunnel
echo   scripts\khidmeti.bat flutter-run    Launch Flutter with local IP
echo   scripts\khidmeti.bat shell-api      Shell in NestJS container
echo   scripts\khidmeti.bat shell-mongo    mongosh in MongoDB
echo   scripts\khidmeti.bat test-api       Test main endpoints
echo   scripts\khidmeti.bat clean          Remove all data (DESTRUCTIVE)
echo.
echo   Tip: use scripts\khidmeti.ps1 from PowerShell for colours
echo.
goto :eof

:: ── START ─────────────────────────────────────────────────────────────────────
:start
echo.
echo ══════════════════════════════════════════════
echo   Starting Khidmeti Backend...
echo ══════════════════════════════════════════════
if not exist ".env" (
  if exist ".env.example" (
    copy ".env.example" ".env" >nul
    echo WARNING: .env created from .env.example — configure it!
  )
)
if not exist "logs" mkdir logs
if not exist "backups\mongodb" mkdir backups\mongodb
if not exist "backups\minio"   mkdir backups\minio
if not exist "data\mongodb"    mkdir data\mongodb
if not exist "data\redis"      mkdir data\redis
if not exist "data\qdrant"     mkdir data\qdrant
if not exist "data\minio"      mkdir data\minio
docker compose up -d
echo.
echo   Waiting 15s for services to start...
timeout /t 15 /nobreak >nul
call :health
call :dns
goto :eof

:: ── STOP ──────────────────────────────────────────────────────────────────────
:stop
docker compose down
echo Services stopped.
goto :eof

:: ── RESTART ───────────────────────────────────────────────────────────────────
:restart
call :stop
timeout /t 3 /nobreak >nul
call :start
goto :eof

:: ── BUILD ─────────────────────────────────────────────────────────────────────
:build
docker compose build --no-cache api
echo Build done.
goto :eof

:rebuild
call :build
call :start
goto :eof

:: ── HEALTH ────────────────────────────────────────────────────────────────────
:health
echo.
echo ══════════════════════════════════════════════
echo   Service Health Check
echo ══════════════════════════════════════════════
echo.
curl -s -o nul -w "  NestJS API  (3000): HTTP %%{http_code}\n" http://localhost:3000/health 2>nul || echo   NestJS API  (3000): OFFLINE
curl -s -o nul -w "  nginx       (80):   HTTP %%{http_code}\n" http://localhost/health       2>nul || echo   nginx       (80):   OFFLINE
curl -s -o nul -w "  Qdrant      (6333): HTTP %%{http_code}\n" http://localhost:6333/healthz 2>nul || echo   Qdrant      (6333): OFFLINE
curl -s -o nul -w "  MinIO API   (9001): HTTP %%{http_code}\n" http://localhost:9001/minio/health/live 2>nul || echo   MinIO API   (9001): OFFLINE
echo.
echo   For MongoDB and Redis, run: docker ps
echo.
goto :eof

:: ── STATUS ────────────────────────────────────────────────────────────────────
:status
docker ps --filter "name=khidmeti" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
goto :eof

:: ── LOGS ──────────────────────────────────────────────────────────────────────
:logs
docker compose logs --tail=100 -f
goto :eof

:logs_api
docker compose logs -f api
goto :eof

:: ── DNS / URLs ────────────────────────────────────────────────────────────────
:dns
echo.
echo ══════════════════════════════════════════════
echo   Service URLs
echo ══════════════════════════════════════════════
echo.
echo   API REST:          http://localhost:3000
echo   API via nginx:     http://localhost:80
echo   Swagger docs:      http://localhost:3000/api/docs
echo   Qdrant dashboard:  http://localhost:6333/dashboard
echo   MinIO console:     http://localhost:9002
echo   MinIO API (S3):    http://localhost:9001
echo.
echo ══════════════════════════════════════════════
echo   Flutter config (same WiFi)
echo   Local IP: %LOCAL_IP%
echo ══════════════════════════════════════════════
echo.
echo   flutter run --dart-define=API_BASE_URL=http://%LOCAL_IP%:80
echo.
echo   OR: paste Quick Tunnel URL in Firebase Remote Config (key: api_base_url)
echo.
goto :eof

:: ── TUNNEL ────────────────────────────────────────────────────────────────────
:tunnel
echo.
echo ══════════════════════════════════════════════════════
echo   Cloudflare Quick Tunnel (no account needed)
echo ══════════════════════════════════════════════════════
echo.
echo   1) A random https://xxx.trycloudflare.com URL will appear below
echo   2) Copy it
echo   3) Firebase Console → Remote Config → api_base_url → paste → Publish
echo   4) Kill and relaunch Flutter app
echo.
echo   Press Ctrl+C to stop the tunnel.
echo ══════════════════════════════════════════════════════
echo.
where cloudflared >nul 2>&1
if %errorlevel% neq 0 (
  echo ERROR: cloudflared not found.
  echo Download from: https://github.com/cloudflare/cloudflared/releases/latest
  echo Download: cloudflared-windows-amd64.exe → rename to cloudflared.exe → add to PATH
  exit /b 1
)
cloudflared tunnel --url http://localhost:80
goto :eof

:: ── FLUTTER RUN ───────────────────────────────────────────────────────────────
:flutter_run
echo.
echo   Launching Flutter with:
echo   API_BASE_URL=http://%LOCAL_IP%:80
echo.
flutter run --dart-define=API_BASE_URL=http://%LOCAL_IP%:80
goto :eof

:: ── SHELL ─────────────────────────────────────────────────────────────────────
:shell_api
docker exec -it khidmeti-api /bin/sh
goto :eof

:shell_mongo
for /f "tokens=2 delims==" %%a in ('findstr "MONGO_ROOT_USER" .env') do set MONGO_USER=%%a
for /f "tokens=2 delims==" %%a in ('findstr "MONGO_ROOT_PASSWORD" .env') do set MONGO_PASS=%%a
docker exec -it khidmeti-mongo mongosh -u "%MONGO_USER%" -p "%MONGO_PASS%" --authenticationDatabase admin khidmeti
goto :eof

:: ── TEST API ──────────────────────────────────────────────────────────────────
:test_api
echo.
echo   [1] Health check:
curl -s http://localhost:3000/health
echo.
echo   [2] Swagger (HTTP code):
curl -s -o nul -w "%%{http_code}" http://localhost:3000/api/docs
echo.
echo   NOTE: Protected endpoints require a Firebase Bearer token.
echo   Swagger UI: http://localhost:3000/api/docs
echo.
goto :eof

:: ── CLEAN ─────────────────────────────────────────────────────────────────────
:clean
echo.
echo   WARNING: This will DELETE ALL DATA (MongoDB, Redis, Qdrant, MinIO)
set /p CONFIRM="   Type YES to confirm: "
if /i "%CONFIRM%"=="YES" (
  docker compose down -v --remove-orphans
  if exist "data\mongodb" rmdir /s /q data\mongodb
  if exist "data\redis"   rmdir /s /q data\redis
  if exist "data\qdrant"  rmdir /s /q data\qdrant
  if exist "data\minio"   rmdir /s /q data\minio
  echo Done.
) else (
  echo Cancelled.
)
goto :eof
