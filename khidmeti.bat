@echo off
:: ══════════════════════════════════════════════════════════════════════════════
:: KHIDMETI BACKEND — Windows CMD Script
:: Usage: khidmeti.bat [command] [args]
::
:: WORKFLOW :
::   khidmeti.bat start       → 1ère fois : pull modèle + démarrage
::   khidmeti.bat start       → fois suivantes : démarrage instantané (volume)
::   khidmeti.bat ollama-pull → forcer re-pull avec progression visible
:: ══════════════════════════════════════════════════════════════════════════════
setlocal enabledelayedexpansion

:: ── IP locale ─────────────────────────────────────────────────────────────────
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

:: ── Lire OLLAMA_MODEL depuis .env ─────────────────────────────────────────────
set OLLAMA_MODEL_VAL=gemma4:e2b
for /f "tokens=2 delims==" %%a in ('findstr "^OLLAMA_MODEL=" .env 2^>nul') do (
  set OLLAMA_MODEL_VAL=%%a
  set OLLAMA_MODEL_VAL=!OLLAMA_MODEL_VAL: =!
)

:: ── Router la commande ────────────────────────────────────────────────────────
set CMD=%1
set ARGS=%2
if "%CMD%"==""                  goto :help
if /i "%CMD%"=="help"           goto :help
if /i "%CMD%"=="start"          goto :start
if /i "%CMD%"=="start-gpu"      goto :start_gpu
if /i "%CMD%"=="stop"           goto :stop
if /i "%CMD%"=="restart"        goto :restart
if /i "%CMD%"=="build"          goto :build
if /i "%CMD%"=="rebuild"        goto :rebuild
if /i "%CMD%"=="ollama-pull"    goto :ollama_pull
if /i "%CMD%"=="health"         goto :health
if /i "%CMD%"=="ai-status"      goto :ai_status
if /i "%CMD%"=="status"         goto :status
if /i "%CMD%"=="logs"           goto :logs
if /i "%CMD%"=="logs-api"       goto :logs_api
if /i "%CMD%"=="logs-ollama"    goto :logs_ollama
if /i "%CMD%"=="logs-whisper"   goto :logs_whisper
if /i "%CMD%"=="dns"            goto :dns
if /i "%CMD%"=="tunnel"         goto :tunnel
if /i "%CMD%"=="ngrok"          goto :ngrok
if /i "%CMD%"=="ngrok-install"  goto :ngrok_install
if /i "%CMD%"=="ngrok-reset"    goto :ngrok_reset
if /i "%CMD%"=="flutter-run"    goto :flutter_run
if /i "%CMD%"=="clean"          goto :clean
if /i "%CMD%"=="shell-api"      goto :shell_api
if /i "%CMD%"=="shell-mongo"    goto :shell_mongo
if /i "%CMD%"=="test-api"       goto :test_api
if /i "%CMD%"=="test-ai"        goto :test_ai
if /i "%CMD%"=="scripts"        goto :scripts
if /i "%CMD%"=="scripts-migrations" goto :scripts_migrations
if /i "%CMD%"=="scripts-seeds"  goto :scripts_seeds

set PREFIX=%CMD:~0,8%
if /i "%PREFIX%"=="scripts-" (
  set SCRIPT_NAME=%CMD:~8%
  goto :scripts_one
)

echo Commande inconnue : %CMD%
echo Utilisation : khidmeti.bat help
exit /b 1

:: ═══════════════════════════════════════════════════════════════════════════════
:: HELP
:: ═══════════════════════════════════════════════════════════════════════════════
:help
echo.
echo ══════════════════════════════════════════════════════
echo   KHIDMETI — Commandes Windows CMD
echo   IP locale : %LOCAL_IP%
echo   Modele    : %OLLAMA_MODEL_VAL%
echo ══════════════════════════════════════════════════════
echo.
echo   [DEMARRAGE]
echo   khidmeti.bat start              Demarrer + pull modele si absent
echo   khidmeti.bat start-gpu          Demarrer avec GPU NVIDIA
echo   khidmeti.bat stop               Arreter (volumes conserves)
echo   khidmeti.bat restart            Redemarrer
echo.
echo   [OLLAMA]
echo   khidmeti.bat ollama-pull        Pull modele avec progression (X GB / Y GB)
echo.
echo   [BUILD API]
echo   khidmeti.bat build              Builder l'image NestJS
echo   khidmeti.bat rebuild            Rebuild + redemarrage
echo.
echo   [LOGS]
echo   khidmeti.bat logs               Tous les logs (Ctrl+C pour quitter)
echo   khidmeti.bat logs-api           Logs NestJS
echo   khidmeti.bat logs-ollama        Logs Ollama
echo   khidmeti.bat logs-whisper       Logs faster-whisper
echo.
echo   [DIAGNOSTIC]
echo   khidmeti.bat health             Sante de tous les services
echo   khidmeti.bat ai-status          Statut IA + modeles installes
echo   khidmeti.bat status             Statut des conteneurs
echo   khidmeti.bat dns                URLs + config Flutter
echo.
echo   [TUNNEL]
echo   khidmeti.bat ngrok              Tunnel ngrok PERMANENT (recommande)
echo   khidmeti.bat tunnel             Cloudflare Quick Tunnel
echo.
echo   [SCRIPTS]
echo   khidmeti.bat scripts                Tout executer
echo   khidmeti.bat scripts-migrations     Migrations seulement
echo   khidmeti.bat scripts-seeds          Seeds seulement
echo   khidmeti.bat scripts-seed-workers   Un script precis
echo.
echo   [DEBUG]
echo   khidmeti.bat shell-api          Shell NestJS
echo   khidmeti.bat shell-mongo        mongosh
echo   khidmeti.bat test-ai            Tester extraction Darija
echo.
echo   [NETTOYAGE]
echo   khidmeti.bat clean              Supprimer volumes (modele inclus)
echo.
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: OLLAMA PULL — progression visible
:: ═══════════════════════════════════════════════════════════════════════════════
:ollama_pull
echo.
echo ══════════════════════════════════════════════
echo   Pull modele Ollama
echo   Modele : %OLLAMA_MODEL_VAL%
echo ══════════════════════════════════════════════
echo.
echo   Attente que Ollama soit pret...
:ollama_pull_wait
curl -sf http://localhost:11434/ >nul 2>&1
if !errorlevel! neq 0 (
  timeout /t 2 /nobreak >nul
  goto :ollama_pull_wait
)
echo   OK Ollama pret.
echo.
echo   Telechargement en cours (progression ci-dessous) :
echo   ex: pulling abc123... 2.1 GB / 7.2 GB  32 MB/s
echo.
docker exec -it khidmeti-ollama ollama pull %OLLAMA_MODEL_VAL%
if !errorlevel! neq 0 (
  echo   ERREUR : pull echoue.
  exit /b 1
)
echo.
echo   OK Modele %OLLAMA_MODEL_VAL% pret.
echo.
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: START
:: ═══════════════════════════════════════════════════════════════════════════════
:start
echo.
echo ══════════════════════════════════════════════
echo   Demarrage de Khidmeti
echo   Modele IA : %OLLAMA_MODEL_VAL%
echo ══════════════════════════════════════════════
echo.

if not exist "logs"              mkdir logs
if not exist "backups\mongodb"   mkdir backups\mongodb
if not exist "data\mongodb"      mkdir data\mongodb
if not exist "data\redis"        mkdir data\redis
if not exist "data\qdrant"       mkdir data\qdrant
if not exist "data\minio"        mkdir data\minio

if not exist ".env" (
  if exist ".env.example" (
    copy ".env.example" ".env" >nul
    echo   ATTENTION : .env cree — configurez FIREBASE_* avant de continuer
    echo.
  )
)

echo   Demarrage des services...
docker compose up -d
echo.
echo   OK Services demarres.
echo.

:: Attendre Ollama
echo   Attente que Ollama soit pret...
:start_ollama_wait
curl -sf http://localhost:11434/ >nul 2>&1
if !errorlevel! neq 0 (
  timeout /t 2 /nobreak >nul
  goto :start_ollama_wait
)
echo   OK Ollama pret.
echo.

:: Vérifier si le modèle est déjà présent
docker exec khidmeti-ollama ollama list 2>nul | findstr /i "%OLLAMA_MODEL_VAL%" >nul 2>&1
if !errorlevel! equ 0 (
  echo   OK Modele %OLLAMA_MODEL_VAL% deja present — demarrage instantane.
  echo.
) else (
  echo   Modele absent du volume — telechargement en cours...
  echo   Progression (X GB / Y GB) :
  echo.
  docker exec -it khidmeti-ollama ollama pull %OLLAMA_MODEL_VAL%
  if !errorlevel! neq 0 (
    echo   ERREUR : pull du modele echoue.
    exit /b 1
  )
  echo.
  echo   OK Modele %OLLAMA_MODEL_VAL% pret.
  echo.
)

call :health
call :dns
goto :eof

:start_gpu
echo.
echo ══════════════════════════════════════════════
echo   Demarrage Khidmeti — GPU NVIDIA
echo   Modele : %OLLAMA_MODEL_VAL%
echo ══════════════════════════════════════════════
echo.
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
echo.
echo   Attente Ollama...
:start_gpu_wait
curl -sf http://localhost:11434/ >nul 2>&1
if !errorlevel! neq 0 ( timeout /t 2 /nobreak >nul & goto :start_gpu_wait )
echo   OK.
echo.
docker exec khidmeti-ollama ollama list 2>nul | findstr /i "%OLLAMA_MODEL_VAL%" >nul 2>&1
if !errorlevel! neq 0 (
  echo   Pull modele GPU...
  docker exec -it khidmeti-ollama ollama pull %OLLAMA_MODEL_VAL%
)
call :health
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: STOP / RESTART / BUILD
:: ═══════════════════════════════════════════════════════════════════════════════
:stop
docker compose down
echo.
echo   OK Services arretes. Volumes conserves (modele Ollama intact).
echo.
goto :eof

:restart
call :stop
timeout /t 3 /nobreak >nul
call :start
goto :eof

:build
docker compose build --no-cache api
echo Build NestJS termine.
goto :eof

:rebuild
call :build
call :start
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: HEALTH
:: ═══════════════════════════════════════════════════════════════════════════════
:health
echo.
echo ══════════════════════════════════════════════
echo   Etat des services
echo ══════════════════════════════════════════════
echo.
curl -s -o nul -w "  NestJS API  (3000) : HTTP %%{http_code}\n" http://localhost:3000/health     2>nul || echo   NestJS API  (3000) : HORS LIGNE
curl -s -o nul -w "  nginx       (80)   : HTTP %%{http_code}\n" http://localhost/health           2>nul || echo   nginx       (80)   : HORS LIGNE
curl -s -o nul -w "  Qdrant      (6333) : HTTP %%{http_code}\n" http://localhost:6333/healthz    2>nul || echo   Qdrant      (6333) : HORS LIGNE
curl -s -o nul -w "  MinIO       (9001) : HTTP %%{http_code}\n" http://localhost:9001/minio/health/live 2>nul || echo   MinIO       (9001) : HORS LIGNE
curl -s -o nul -w "  Ollama      (11434): HTTP %%{http_code}\n" http://localhost:11434/           2>nul || echo   Ollama      (11434): HORS LIGNE
curl -s -o nul -w "  Whisper     (8000) : HTTP %%{http_code}\n" http://localhost:8000/health     2>nul || echo   Whisper     (8000) : HORS LIGNE
echo.
goto :eof

:ai_status
echo.
echo ══════════════════════════════════════════════
echo   Statut IA locale
echo ══════════════════════════════════════════════
echo.
curl -s -o nul -w "  Ollama  (11434) : HTTP %%{http_code}\n" http://localhost:11434/ 2>nul
curl -s -o nul -w "  Whisper (8000)  : HTTP %%{http_code}\n" http://localhost:8000/health 2>nul
echo.
echo   Modeles installes :
docker exec khidmeti-ollama ollama list 2>nul || echo   (Ollama non demarre)
echo.
goto :eof

:status
docker ps --filter "name=khidmeti" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: LOGS
:: ═══════════════════════════════════════════════════════════════════════════════
:logs
docker compose logs --tail=100 -f
goto :eof

:logs_api
docker compose logs -f api
goto :eof

:logs_ollama
docker compose logs -f ollama
goto :eof

:logs_whisper
docker compose logs -f whisper
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: DNS / URLS
:: ═══════════════════════════════════════════════════════════════════════════════
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
echo   Ollama API     :  http://localhost:11434
echo   Whisper API    :  http://localhost:8000
echo.
echo ══════════════════════════════════════════════
echo   Config Flutter (meme WiFi)
echo   IP locale : %LOCAL_IP%
echo ══════════════════════════════════════════════
echo.
echo   flutter run --dart-define=API_BASE_URL=http://%LOCAL_IP%:80
echo.
set NGROK_DOMAIN_DNS=
for /f "tokens=2 delims==" %%a in ('findstr "^NGROK_DOMAIN=" .env 2^>nul') do set NGROK_DOMAIN_DNS=%%a
if not "%NGROK_DOMAIN_DNS%"=="" (
  echo   Tunnel ngrok : https://%NGROK_DOMAIN_DNS%
  echo   flutter run --dart-define=API_BASE_URL=https://%NGROK_DOMAIN_DNS%
  echo.
)
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: TUNNELS
:: ═══════════════════════════════════════════════════════════════════════════════
:tunnel
echo.
echo   Ctrl+C pour arreter. URL aleatoire — change a chaque demarrage.
echo   Pour URL permanente : khidmeti.bat ngrok
echo.
where cloudflared >nul 2>&1
if %errorlevel% neq 0 (
  echo ERREUR : cloudflared introuvable.
  echo Telecharger : https://github.com/cloudflare/cloudflared/releases/latest
  exit /b 1
)
cloudflared tunnel --url http://localhost:80
goto :eof

:ngrok_install
echo.
echo ══════════════════════════════════════════════
echo   Installation de ngrok (Windows)
echo ══════════════════════════════════════════════
echo.
where ngrok >nul 2>&1
if %errorlevel% equ 0 (
  echo   ngrok deja installe.
  ngrok --version
  goto :eof
)
echo   Telechargement de ngrok...
curl -sL -o "%TEMP%\ngrok.zip" "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
if %errorlevel% neq 0 (
  echo   ERREUR : telechargement echoue.
  echo   Telechargez manuellement : https://ngrok.com/download
  goto :eof
)
powershell -Command "Expand-Archive -Path '%TEMP%\ngrok.zip' -DestinationPath 'C:\ngrok' -Force" >nul 2>&1
echo.
echo   ngrok extrait dans C:\ngrok\
echo   Ajoutez C:\ngrok\ a votre variable PATH puis :
echo   1. Compte : https://dashboard.ngrok.com/signup
echo   2. Token  : https://dashboard.ngrok.com/get-started/your-authtoken
echo   3. Domaine: https://dashboard.ngrok.com/domains
echo   4. khidmeti.bat ngrok
echo.
goto :eof

:ngrok
echo.
echo ══════════════════════════════════════════════
echo   Tunnel ngrok — Domaine statique permanent
echo ══════════════════════════════════════════════
echo.
where ngrok >nul 2>&1
if %errorlevel% neq 0 (
  echo   ERREUR : ngrok introuvable — khidmeti.bat ngrok-install
  exit /b 1
)

set NGROK_TOKEN=
for /f "tokens=2 delims==" %%a in ('findstr "^NGROK_AUTH_TOKEN=" .env 2^>nul') do set NGROK_TOKEN=%%a
set NGROK_TOKEN=%NGROK_TOKEN: =%
if "%NGROK_TOKEN%"=="" (
  echo   Obtenez votre token : https://dashboard.ngrok.com/get-started/your-authtoken
  set /p NGROK_TOKEN="  Collez votre Auth Token : "
  findstr /v "^NGROK_AUTH_TOKEN=" .env > .env.tmp 2>nul
  echo NGROK_AUTH_TOKEN=!NGROK_TOKEN!>> .env.tmp
  move /y .env.tmp .env >nul
  echo   Token sauvegarde dans .env
  echo.
)
ngrok config add-authtoken %NGROK_TOKEN% >nul 2>&1

set NGROK_DOMAIN=
for /f "tokens=2 delims==" %%a in ('findstr "^NGROK_DOMAIN=" .env 2^>nul') do set NGROK_DOMAIN=%%a
set NGROK_DOMAIN=%NGROK_DOMAIN: =%
if "%NGROK_DOMAIN%"=="" (
  echo   Reservez un domaine : https://dashboard.ngrok.com/domains
  set /p NGROK_DOMAIN="  Entrez votre domaine statique : "
  findstr /v "^NGROK_DOMAIN=" .env > .env.tmp 2>nul
  echo NGROK_DOMAIN=!NGROK_DOMAIN!>> .env.tmp
  move /y .env.tmp .env >nul
  echo   Domaine sauvegarde dans .env
  echo.
)

echo   URL permanente : https://%NGROK_DOMAIN%
echo   flutter run --dart-define=API_BASE_URL=https://%NGROK_DOMAIN%
echo   Ctrl+C pour arreter
echo.
ngrok http --domain=%NGROK_DOMAIN% 80
goto :eof

:ngrok_reset
findstr /v "^NGROK_AUTH_TOKEN=" .env > .env.tmp 2>nul
move /y .env.tmp .env >nul
findstr /v "^NGROK_DOMAIN=" .env > .env.tmp 2>nul
move /y .env.tmp .env >nul
echo Config ngrok supprimee.
goto :eof

:flutter_run
flutter run --dart-define=API_BASE_URL=http://%LOCAL_IP%:80
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: SHELLS / DEBUG
:: ═══════════════════════════════════════════════════════════════════════════════
:shell_api
docker exec -it khidmeti-api /bin/sh
goto :eof

:shell_mongo
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_USER" .env') do set MONGO_USER=%%a
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_PASSWORD" .env') do set MONGO_PASS=%%a
docker exec -it khidmeti-mongo mongosh -u "%MONGO_USER%" -p "%MONGO_PASS%" --authenticationDatabase admin khidmeti
goto :eof

:test_api
echo.
echo   [1] Health :
curl -s http://localhost:3000/health
echo.
echo   [2] Swagger :
curl -s -o nul -w "%%{http_code}" http://localhost:3000/api/docs
echo.
goto :eof

:test_ai
echo.
echo   Test Ollama — extraction Darija...
echo.
curl -s http://localhost:11434/v1/chat/completions ^
  -H "Content-Type: application/json" ^
  -d "{\"model\":\"%OLLAMA_MODEL_VAL%\",\"messages\":[{\"role\":\"system\",\"content\":\"Reponds UNIQUEMENT en JSON: {\\\"profession\\\":null,\\\"is_urgent\\\":false,\\\"problem_description\\\":\\\"\\\",\\\"confidence\\\":0}\"},{\"role\":\"user\",\"content\":\"عندي ماء ساقط من السقف\"}],\"options\":{\"num_ctx\":2048,\"think\":false},\"temperature\":0.05,\"max_tokens\":200,\"stream\":false}"
echo.
goto :eof

:: ═══════════════════════════════════════════════════════════════════════════════
:: SCRIPTS
:: ═══════════════════════════════════════════════════════════════════════════════
:scripts
call :scripts_migrations
call :scripts_seeds
goto :eof

:scripts_migrations
echo.
echo ══════════════════════════════════════════════
echo   Migrations MongoDB
echo ══════════════════════════════════════════════
echo.
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_USER" .env 2^>nul') do set MIG_USER=%%a
for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_PASSWORD" .env 2^>nul') do set MIG_PASS=%%a
set MIG_OK=0
set MIG_FAIL=0
if not exist "scripts\migrations\*.js" (
  echo   Aucune migration trouvee.
  goto :migrations_done
)
for %%f in (scripts\migrations\*.js) do (
  echo   ^> %%~nxf
  docker exec -i khidmeti-mongo mongosh --quiet ^
    -u "%MIG_USER%" -p "%MIG_PASS%" ^
    --authenticationDatabase admin khidmeti < "%%f"
  if !errorlevel! equ 0 (
    echo     OK
    set /a MIG_OK+=1
  ) else (
    echo     ECHEC
    set /a MIG_FAIL+=1
  )
)
:migrations_done
echo.
echo   Resultat : %MIG_OK% OK  ^|  %MIG_FAIL% echec(s)
echo.
if %MIG_FAIL% gtr 0 exit /b 1
goto :eof

:scripts_seeds
echo.
echo ══════════════════════════════════════════════
echo   Seeds TypeScript
echo ══════════════════════════════════════════════
echo.
set SEED_OK=0
set SEED_FAIL=0
if not exist "apps\api\src\scripts\seeds\*.ts" (
  echo   Aucun seed trouve.
  goto :seeds_done
)
for %%f in (apps\api\src\scripts\seeds\*.ts) do (
  echo   ^> %%~nxf %ARGS%
  docker exec khidmeti-api ^
    npx ts-node --project tsconfig.json "src/scripts/seeds/%%~nxf" %ARGS%
  if !errorlevel! equ 0 (
    echo     OK
    set /a SEED_OK+=1
  ) else (
    echo     ECHEC
    set /a SEED_FAIL+=1
  )
)
:seeds_done
echo.
echo   Resultat : %SEED_OK% OK  ^|  %SEED_FAIL% echec(s)
echo.
if %SEED_FAIL% gtr 0 exit /b 1
goto :eof

:scripts_one
echo.
if exist "scripts\migrations\%SCRIPT_NAME%.js" (
  for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_USER" .env 2^>nul') do set ONE_USER=%%a
  for /f "tokens=2 delims==" %%a in ('findstr "^MONGO_ROOT_PASSWORD" .env 2^>nul') do set ONE_PASS=%%a
  echo   ^> Migration : %SCRIPT_NAME%.js
  docker exec -i khidmeti-mongo mongosh --quiet ^
    -u "%ONE_USER%" -p "%ONE_PASS%" ^
    --authenticationDatabase admin khidmeti < "scripts\migrations\%SCRIPT_NAME%.js"
  if !errorlevel! equ 0 ( echo   OK ) else ( echo   ECHEC & exit /b 1 )
  goto :eof
)
if exist "apps\api\src\scripts\seeds\%SCRIPT_NAME%.ts" (
  echo   ^> Seed : %SCRIPT_NAME%.ts %ARGS%
  docker exec khidmeti-api ^
    npx ts-node --project tsconfig.json "src/scripts/seeds/%SCRIPT_NAME%.ts" %ARGS%
  if !errorlevel! equ 0 ( echo   OK ) else ( echo   ECHEC & exit /b 1 )
  goto :eof
)
echo   ERREUR : Script '%SCRIPT_NAME%' introuvable.
exit /b 1

:: ═══════════════════════════════════════════════════════════════════════════════
:: CLEAN
:: ═══════════════════════════════════════════════════════════════════════════════
:clean
echo.
echo   ATTENTION : suppression de tous les volumes (MongoDB, Redis, Qdrant, MinIO, Ollama).
echo   Le modele Ollama sera re-telecharge au prochain : khidmeti.bat start
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
