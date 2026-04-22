#!/usr/bin/env python3
"""
download_vision.py — Télécharge moondream2 via huggingface_hub.
Utilisé par : Makefile → cible download-vision (fallback manuel)

Le téléchargement normal se fait via LLAMA_ARG_HF_REPO dans docker-compose.yml.
Ce script n'est nécessaire que si le container n'a pas accès à internet.
"""
import sys
import os

# HF_HOME est positionné par le Makefile ; on force aussi ici pour le
# cas d'un appel direct au script.
hf_home = os.environ.get("HF_HOME", os.path.join(os.getcwd(), "docker/models/vision"))
os.environ["HF_HOME"] = hf_home

try:
    from huggingface_hub import hf_hub_download, login, list_repo_files
except ImportError:
    print("  ❌ huggingface_hub non installé.", file=sys.stderr)
    print("     pip3 install huggingface_hub --break-system-packages", file=sys.stderr)
    sys.exit(1)

# Auth — lève les rate-limits HuggingFace
hf_token = (
    os.environ.get("HF_TOKEN")
    or os.popen("grep '^HF_TOKEN=' .env 2>/dev/null | cut -d= -f2").read().strip()
)
if hf_token:
    login(token=hf_token, add_to_git_credential=False)
    print("  🔑 HuggingFace token configuré")
else:
    print("  ⚠️  Aucun HF_TOKEN — téléchargement anonyme (peut échouer)")

# FIX v12.0 : repo officiel llama.cpp-compatible
# vikhyatk/moondream2 ne contient PAS moondream2-text-Q8_0.gguf (404)
# ggml-org corrige aussi le chat_template manquant dans le repo original
REPO_ID  = "ggml-org/moondream2-20250414-GGUF"
DEST_DIR = os.environ.get("_VISION_DEST", "docker/models/vision")
os.makedirs(DEST_DIR, exist_ok=True)

# Lister les fichiers disponibles dans le repo
print(f"  🔍 Fichiers disponibles dans {REPO_ID} :")
try:
    available = list(list_repo_files(REPO_ID, token=hf_token or None))
except Exception as e:
    print(f"  ❌ Impossible de lister le repo {REPO_ID} : {e}", file=sys.stderr)
    sys.exit(1)

gguf_files = [f for f in available if f.endswith(".gguf")]
for f in gguf_files:
    print(f"     • {f}")

# Sélection : Q4_K_M pour le texte, mmproj F16
text_file = next((f for f in gguf_files if "Q4_K_M" in f and "mmproj" not in f), None)
mmproj    = next((f for f in gguf_files if "mmproj" in f.lower()), None)

if not text_file or not mmproj:
    print(f"  ❌ Fichiers Q4_K_M ou mmproj introuvables dans {REPO_ID}", file=sys.stderr)
    print(f"     Fichiers trouvés : {gguf_files}", file=sys.stderr)
    sys.exit(1)

for filename in [text_file, mmproj]:
    dest_path = os.path.join(DEST_DIR, os.path.basename(filename))
    if os.path.isfile(dest_path) and os.path.getsize(dest_path) > 1_000_000:
        size_mb = os.path.getsize(dest_path) // (1024 * 1024)
        print(f"  ⏭  {os.path.basename(filename)} déjà présent ({size_mb} MB) — skip")
        continue
    print(f"  → Téléchargement de {filename}...")
    try:
        path = hf_hub_download(
            repo_id=REPO_ID,
            filename=filename,
            local_dir=DEST_DIR,
            token=hf_token or None,
        )
        size_mb = os.path.getsize(path) // (1024 * 1024)
        print(f"  ✅ {os.path.basename(filename)} — {size_mb} MB")
    except Exception as e:
        print(f"  ❌ Échec : {e}", file=sys.stderr)
        sys.exit(1)

print("")
print("  ✅ Vision prête → make restart")
