#!/usr/bin/env python3
"""
download_whisper.py — Télécharge le modèle Whisper via huggingface_hub.

Variables d'environnement :
  _WHISPER_MODEL   ID du modèle HuggingFace (défaut : Systran/faster-whisper-large-v3-turbo)
  HF_HOME          Répertoire de cache HuggingFace (défaut : docker/models/audio)

Utilisé par : Makefile → cible download-whisper
"""
import sys
import os

# HF_HOME est déjà positionné par le Makefile via l'environnement ;
# on le force aussi ici pour garantir la cohérence si le script est
# lancé directement.
hf_home = os.environ.get("HF_HOME", os.path.join(os.getcwd(), "docker/models/audio"))
os.environ["HF_HOME"] = hf_home

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print("  ❌ huggingface_hub non installé.", file=sys.stderr)
    print("     Lancez : pip3 install huggingface_hub --break-system-packages", file=sys.stderr)
    sys.exit(1)

model_id = os.environ.get("_WHISPER_MODEL", "Systran/faster-whisper-large-v3-turbo")
print(f"  → Téléchargement de {model_id}...")

try:
    path = snapshot_download(
        repo_id=model_id,
        local_files_only=False,
        ignore_patterns=["*.msgpack", "*.h5", "flax_model*", "tf_model*"],
    )
    print(f"  ✅ Modèle téléchargé : {path}")
except Exception as e:
    print(f"  ❌ Erreur : {e}", file=sys.stderr)
    sys.exit(1)
