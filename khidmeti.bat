@echo off
:: ══════════════════════════════════════════════════════════════════════════════
:: KHIDMETI BACKEND — Windows CMD Script
:: Usage: khidmeti.bat [command] [args]
::
:: Requirements: Docker Desktop
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
set ARGS=%2
if "%CMD%"==""                  goto :help
if /i "%CMD%"=="help"           goto :help
if /i "%CMD%"=="start"          goto :start
if /i "%CMD%"=="stop"           goto :stop
if /i "%CMD%"=="restart"        goto :restart
if /i "%CMD%"=="build"          goto :build
if /i "%CMD%"=="rebuild"        goto :rebuild
if /i "%CMD%"=="health"         goto :health
if /i "%CMD%"=="status"         goto :status
if /i "%CMD%"=="logs"           goto :logs
if /i "%CMD%"=="logs-api"       goto :logs_api
if /i "%CMD%"=="tunnel"         goto :tunnel
if /i "%CMD%"=="flutter-run"    goto :flutter_run
if /i "%CMD%"=="clean"          goto :clean
if /i "%CMD%"=="dns"            goto :dns
if /i "%CMD%"=="shell-api"      goto :shell_api
if /i "%CMD%"=="shell-mongo"    goto :shell_mongo
if /i "%CMD%"=="test-api"       goto :test_api
if /i "%CMD%"=="scripts"        goto :scripts
if /i "%CMD%"=="scripts-migrations" goto :scripts_migrations
if /i "%CMD%"=="scripts-seeds"  goto :scripts_seeds

:: Vérifier si la commande commence par "scripts-"
set PREFIX=%CMD:~0,8%
if /i "%PREFIX%"=="scripts-" (
  set SCRIPT_NAME=%CMD:~8%
  goto :scripts_one
)

echo Commande inconnue : %CMD%
echo Utilisation : khidmeti.bat help
exit /b 1

:: ── HELP ──────────────────────────────────────────────────────────────────────
:help
echo.
echo ══════════════════════════════════════════════════════
echo   KHIDMETI — Commandes Windows CMD
echo   IP locale : %LOCAL_IP%
echo ══════════════════════════════════════════════════════
echo.
echo   [SERVICES]
echo   khidmeti.bat start              Demarrer tous les services
echo   khidmeti.bat stop               Arreter tous les services
echo   khidmeti.bat restart            Redemarrer
echo   khidmeti.bat build              Builder l'image NestJS
echo   khidmeti.bat rebuild            Rebuild + redemarrage
echo   khidmeti.bat health             Verifier la sante des services
echo   khidmeti.bat status             Statut des conteneurs
echo   khidmeti.bat logs               Tous les logs (Ctrl+C pour quitter)
echo   khidmeti.bat logs-api           Logs NestJS uniquement
echo   khidmeti.bat dns                URLs + config Flutter
echo   khidmeti.bat tunnel             Cloudflare Quick Tunnel
echo   khidmeti.bat flutter-run        Lancer Flutter avec l'IP locale
echo   khidmeti.bat shell-api          Shell dans le conteneur NestJS
echo   khidmeti.bat shell-mongo        mongosh dans MongoDB
echo   khidmeti.bat test-api           Tester les endpoints
echo   khidmeti.bat clean              Supprimer toutes les donnees (DESTRUCTIF)
echo.
echo   [SCRIPTS — Migrations + Seeds]
echo   khidmeti.bat scripts                        Tout executer
echo   khidmeti.bat scripts-migrations             Migrations seulement
echo   khidmeti.bat scripts-seeds                  Seeds seulement
echo   khidmeti.bat scripts-001_phone_auth_indexes Une migration precise
echo   khidmeti.bat scripts-seed-workers           Un seed precis
echo   khidmeti.bat scripts-seed-workers --clear   Seed avec flag
echo.
echo   Structure attendue :
echo     scripts\migrations\*.js         ^(mongosh dans khidmeti-mongo^)
echo     apps\api\src\scripts\seeds\*.ts ^(ts-node dans khidmeti-api^)
echo.
goto :eof

:: ── START ─────────────────────────────────────────────────────────────────────
:start
echo.
echo ══════════════════════════════════════════════
echo   Demarrage de Khidmeti Backend...
echo ══════════════════════════════════════════════
if not exist ".env" (
  if exist ".env.example" (
    copy ".env.example" ".env" >nul
    echo ATTENTION : .env cree depuis .env.example — configurez FIREBASE_* et les cles IA
  )
)
if not exist "logs"              mkdir logs
if not exist "backups\mongodb"   mkdir backups\mongodb
if not exist "backups\minio"     mkdir backups\minio
if not exist "data\mongodb"      mkdir data\mongodb
if not exist "data\redis"        mkdir data\redis
if not exist "data\qdrant"       mkdir data\qdrant
if not exist "data\minio"        mkdir data\minio
docker compose up -d
echo.
echo   Attente 15s...
timeout /t 15 /nobreak >nul
call :health
call :dns
goto :eof

:: ── STOP ──────────────────────────────────────────────────────────────────────
:stop
docker compose down
echo Services arretes.
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
echo Build termine.
goto :eof

:rebuild
call :build
call :start
goto :eof

:: ── HEALTH ────────────────────────────────────────────────────────────────────
:health
echo.
echo ══════════════════════════════════════════════
echo   Etat des services
echo ══════════════════════════════════════════════
echo.
curl -s -o nul -w "  NestJS API  (3000) : HTTP %%{http_code}\n" http://localhost:3000/health     2>nul || echo   NestJS API  (3000) : HORS LIGNE
curl -s -o nul -w "  nginx       (80)   : HTTP %%{http_code}\n" http://localhost/health           2>nul || echo   nginx       (80)   : HORS LIGNE
curl -s -o nul -w "  Qdrant      (6333) : HTTP %%{http_code}\n" http://localhost:6333/healthz    2>nul || echo   Qdrant      (6333) : HORS LIGNE
curl -s -o nul -w "  MinIO API   (9001) : HTTP %%{http_code}\n" http://localhost:9001/minio/health/live 2>nul || echo   MinIO       (9001) : HORS LIGNE
echo.
echo   Pour MongoDB et Redis : docker ps --filter name=khidmeti
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
echo   URLs des services
echo ══════════════════════════════════════════════
echo.
echo   API REST       :  http://localhost:3000
echo   API via nginx  :  http://localhost:80
echo   Swagger docs   :  http://localhost:3000/api/docs
echo   Mongo Express  :  http://localhost:8081
echo   Qdrant UI      :  http://localhost:6333/dashboard
echo   MinIO console  :  http://localhost:9002
echo   MinIO API (S3) :  http://localhost:9001
echo.
echo ══════════════════════════════════════════════
echo   Config Flutter (meme WiFi)
echo   IP locale : %LOCAL_IP%
echo ══════════════════════════════════════════════
echo.
echo   flutter run --dart-define=API_BASE_URL=http://%LOCAL_IP%:80
echo.
echo   OU : collez l'URL Quick Tunnel dans Firebase Remote Config
echo        cle : api_base_url
echo.
goto :eof

:: ── TUNNEL ────────────────────────────────────────────────────────────────────
:tunnel
echo.
echo ══════════════════════════════════════════════════════
echo   Cloudflare Quick Tunnel (sans compte)
echo ══════════════════════════════════════════════════════
echo.
echo   1) Une URL aleatoire https://xxx.trycloudflare.com va apparaitre
echo   2) Copiez-la
echo   3) Firebase Console -> Remote Config -> api_base_url -> coller -> Publier
echo   4) Relancez l'application Flutter
echo.
echo   Ctrl+C pour arreter le tunnel.
echo ══════════════════════════════════════════════════════
echo.
where cloudflared >nul 2>&1
if %errorlevel% neq 0 (
  echo ERREUR : cloudflared introuvable.
  echo Telecharger : https://github.com/cloudflare/cloudflared/releases/latest
  echo Renommer cloudflared-windows-amd64.exe en cloudflared.exe et ajouter au PATH
  exit /b 1
)
cloudflared tunnel --url http://localhost:80
goto :eof

:: ── FLUTTER RUN ───────────────────────────────────────────────────────────────
:flutter_run
echo.
echo   Lancement Flutter avec API_BASE_URL=http://%LOCAL_IP%:80
echo.
flutter run --dart-define=API_BASE_URL=http://%LOCAL_IP%:80
goto :eof

:: ── SHELL ─────────────────────────────────────────────────────────────────────
:shell_api
docker exec -it khidmeti-api /bin/sh
goto :eof

:shell_mongo
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_USER" .env') do set MONGO_USER=%%a
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_PASSWORD" .env') do set MONGO_PASS=%%a
docker exec -it khidmeti-mongo mongosh -u "%MONGO_USER%" -p "%MONGO_PASS%" --authenticationDatabase admin khidmeti
goto :eof

:: ── TEST API ──────────────────────────────────────────────────────────────────
:test_api
echo.
echo   [1] Health :
curl -s http://localhost:3000/health
echo.
echo   [2] Swagger (code HTTP) :
curl -s -o nul -w "%%{http_code}" http://localhost:3000/api/docs
echo.
echo   Endpoints proteges : jeton Firebase Bearer requis.
echo   Swagger UI : http://localhost:3000/api/docs
echo.
goto :eof

:: ══════════════════════════════════════════════════════════════════════════════
:: SCRIPTS — Migrations + Seeds
:: ══════════════════════════════════════════════════════════════════════════════

:: ── Tout executer ─────────────────────────────────────────────────────────────
:scripts
echo.
echo ══════════════════════════════════════════════
echo   Scripts : migrations + seeds
echo ══════════════════════════════════════════════
call :scripts_migrations
call :scripts_seeds
goto :eof

:: ── Toutes les migrations ──────────────────────────────────────────────────────
:scripts_migrations
echo.
echo ══════════════════════════════════════════════
echo   Migrations MongoDB
echo ══════════════════════════════════════════════
echo.

:: Lire les credentials MongoDB depuis .env
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_USER" .env 2^>nul') do set MIG_MONGO_USER=%%a
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_PASSWORD" .env 2^>nul') do set MIG_MONGO_PASS=%%a

set MIG_COUNT=0
set MIG_FAILED=0

if not exist "scripts\migrations\*.js" (
  echo   Aucune migration trouvee dans scripts\migrations\
  echo.
  goto :migrations_done
)

for %%f in (scripts\migrations\*.js) do (
  echo   ^> %%~nxf
  docker exec -i khidmeti-mongo mongosh --quiet ^
    -u "%MIG_MONGO_USER%" -p "%MIG_MONGO_PASS%" ^
    --authenticationDatabase admin khidmeti < "%%f"
  if !errorlevel! equ 0 (
    echo     OK %%~nxf
    set /a MIG_COUNT+=1
  ) else (
    echo     ECHEC %%~nxf
    set /a MIG_FAILED+=1
  )
  echo.
)

:migrations_done
echo   Resultat : %MIG_COUNT% OK  ^|  %MIG_FAILED% echec(s)
echo.
if %MIG_FAILED% gtr 0 exit /b 1
goto :eof

:: ── Tous les seeds ─────────────────────────────────────────────────────────────
:scripts_seeds
echo.
echo ══════════════════════════════════════════════
echo   Seeds TypeScript
echo ══════════════════════════════════════════════
echo.

set SEED_COUNT=0
set SEED_FAILED=0

if not exist "apps\api\src\scripts\seeds\*.ts" (
  echo   Aucun seed trouve dans apps\api\src\scripts\seeds\
  echo.
  goto :seeds_done
)

for %%f in (apps\api\src\scripts\seeds\*.ts) do (
  echo   ^> %%~nxf %ARGS%
  docker exec khidmeti-api ^
    npx ts-node --project tsconfig.json "src/scripts/seeds/%%~nxf" %ARGS%
  if !errorlevel! equ 0 (
    echo     OK %%~nxf
    set /a SEED_COUNT+=1
  ) else (
    echo     ECHEC %%~nxf
    set /a SEED_FAILED+=1
  )
  echo.
)

:seeds_done
echo   Resultat : %SEED_COUNT% OK  ^|  %SEED_FAILED% echec(s)
echo.
if %SEED_FAILED% gtr 0 exit /b 1
goto :eof

:: ── Script individuel ─────────────────────────────────────────────────────────
:scripts_one
echo.
:: Chercher d'abord dans migrations
if exist "scripts\migrations\%SCRIPT_NAME%.js" (
  echo   ^> Migration : %SCRIPT_NAME%.js
  echo.
  for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_USER" .env 2^>nul') do set ONE_USER=%%a
  for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_PASSWORD" .env 2^>nul') do set ONE_PASS=%%a
  docker exec -i khidmeti-mongo mongosh --quiet ^
    -u "%ONE_USER%" -p "%ONE_PASS%" ^
    --authenticationDatabase admin khidmeti < "scripts\migrations\%SCRIPT_NAME%.js"
  if !errorlevel! equ 0 (
    echo.
    echo   OK %SCRIPT_NAME%.js
  ) else (
    echo.
    echo   ECHEC %SCRIPT_NAME%.js
    exit /b 1
  )
  echo.
  goto :eof
)

:: Chercher dans seeds
if exist "apps\api\src\scripts\seeds\%SCRIPT_NAME%.ts" (
  echo   ^> Seed : %SCRIPT_NAME%.ts %ARGS%
  echo.
  docker exec khidmeti-api ^
    npx ts-node --project tsconfig.json "src/scripts/seeds/%SCRIPT_NAME%.ts" %ARGS%
  if !errorlevel! equ 0 (
    echo.
    echo   OK %SCRIPT_NAME%.ts
  ) else (
    echo.
    echo   ECHEC %SCRIPT_NAME%.ts
    exit /b 1
  )
  echo.
  goto :eof
)

:: Script non trouve
echo   ERREUR : Script '%SCRIPT_NAME%' introuvable.
echo.
echo   Cherche dans :
echo     scripts\migrations\%SCRIPT_NAME%.js
echo     apps\api\src\scripts\seeds\%SCRIPT_NAME%.ts
echo.
echo   Scripts disponibles :
echo   Migrations :
if exist "scripts\migrations\*.js" (
  for %%f in (scripts\migrations\*.js) do echo     %%~nf
) else (
  echo     (aucune)
)
echo   Seeds :
if exist "apps\api\src\scripts\seeds\*.ts" (
  for %%f in (apps\api\src\scripts\seeds\*.ts) do echo     %%~nf
) else (
  echo     (aucun)
)
echo.
exit /b 1

:: ── CLEAN ─────────────────────────────────────────────────────────────────────
:clean
echo.
echo   ATTENTION : suppression de TOUTES les donnees Khidmeti.
set /p CONFIRM="  Taper YES pour confirmer : "
if /i "%CONFIRM%"=="YES" (
  docker compose down -v --remove-orphans
  if exist "data\mongodb" rmdir /s /q data\mongodb
  if exist "data\redis"   rmdir /s /q data\redis
  if exist "data\qdrant"  rmdir /s /q data\qdrant
  if exist "data\minio"   rmdir /s /q data\minio
  echo Nettoyage termine.
) else (
  echo Annule.
)
goto :eof
