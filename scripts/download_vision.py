#!/usr/bin/env python3
"""
download_vision.py — Télécharge les modèles moondream2 via huggingface_hub.

Variables d'environnement :
  HF_HOME          Répertoire de cache HuggingFace (défaut : docker/models/vision)

Fichiers téléchargés :
  moondream2-text-Q8_0.gguf   (~1.7 GB)  — modèle de vision principal
  moondream2-mmproj-f16.gguf  (~100 MB)  — projecteur multimodal CLIP

Utilisé par : Makefile → cible download-vision
"""
import sys
import os

# HF_HOME est positionné par le Makefile ; on force aussi ici pour le
# cas d'un appel direct au script.
hf_home = os.environ.get("HF_HOME", os.path.join(os.getcwd(), "docker/models/vision"))
os.environ["HF_HOME"] = hf_home

try:
    from huggingface_hub import hf_hub_download
except ImportError:
    print("  ❌ huggingface_hub non installé.", file=sys.stderr)
    print("     Lancez : pip3 install huggingface_hub --break-system-packages", file=sys.stderr)
    sys.exit(1)

REPO_ID  = "vikhyatk/moondream2"
DEST_DIR = os.environ.get("_VISION_DEST", "docker/models/vision")
FILES    = [
    "moondream2-text-Q8_0.gguf",   # ~1.7 GB
    "moondream2-mmproj-f16.gguf",  # ~100 MB
]

os.makedirs(DEST_DIR, exist_ok=True)

for filename in FILES:
    dest_path = os.path.join(DEST_DIR, filename)

    # Skip si déjà présent et non-vide (évite re-téléchargement)
    if os.path.isfile(dest_path) and os.path.getsize(dest_path) > 0:
        size_mb = os.path.getsize(dest_path) // (1024 * 1024)
        print(f"  ⏭  {filename} déjà présent ({size_mb} MB) — skip")
        continue

    print(f"  → Téléchargement de {filename}...")
    try:
        path = hf_hub_download(
            repo_id=REPO_ID,
            filename=filename,
            local_dir=DEST_DIR,
        )
        size_mb = os.path.getsize(path) // (1024 * 1024)
        print(f"  ✅ {filename} — {size_mb} MB → {path}")
    except Exception as e:
        print(f"  ❌ Échec pour {filename} : {e}", file=sys.stderr)
        sys.exit(1)

print("")
print("  ✅ Modèles vision prêts dans docker/models/vision/")
print("  Prochaine étape : make restart")
