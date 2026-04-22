#!/usr/bin/env python3
"""
download_gemma4.py — Télécharge Gemma4 E2B ou E4B (model + mmproj f32) depuis HuggingFace.

v14 : Le mmproj f32 contient l'encodeur image ET l'encodeur audio (conformer USM-style).
      Aucun fichier supplémentaire nécessaire pour le support audio natif (PR#21421).

Variables d'environnement :
  GEMMA4_VARIANT  "e2b" (défaut) ou "e4b"
  GEMMA4_QUANT    "Q4_K_M" (défaut) — ou Q6_K, Q8_0
  GEMMA4_DEST     Répertoire de destination (défaut : docker/models/gemma4)
  HF_TOKEN        Token HuggingFace (lu depuis .env si absent)

Repos HuggingFace utilisés :
  E2B : bartowski/google_gemma-4-E2B-it-GGUF  (GGUF quantifiés)
  E4B : bartowski/google_gemma-4-E4B-it-GGUF

Fichiers téléchargés (noms standardisés pour le docker-compose) :
  gemma-4-{e2b|e4b}-it-{QUANT}.gguf      → model principal (texte + décodeur)
  mmproj-gemma-4-{e2b|e4b}-it-f32.gguf   → mmproj f32 (encodeur image + AUDIO)
    ↑ f32 = format optimal pour audio conformer encoder (PR#21421)
    ↑ Ne pas utiliser mmproj quantifié (Q4/Q8) → qualité audio dégradée

Utilisé par : Makefile → make download-gemma4
"""
import sys
import os

# ── Configuration ─────────────────────────────────────────────────────────────
VARIANT = os.environ.get("GEMMA4_VARIANT", "e2b").lower()
QUANT   = os.environ.get("GEMMA4_QUANT",   "Q4_K_M").upper()
DEST    = os.environ.get("GEMMA4_DEST",    "docker/models/gemma4")

os.makedirs(DEST, exist_ok=True)

# Nom du repo selon la variante
REPO_MAP = {
    "e2b": "bartowski/google_gemma-4-E2B-it-GGUF",
    "e4b": "bartowski/google_gemma-4-E4B-it-GGUF",
}
if VARIANT not in REPO_MAP:
    print(f"  ❌ GEMMA4_VARIANT invalide : '{VARIANT}' — doit être 'e2b' ou 'e4b'", file=sys.stderr)
    sys.exit(1)

REPO_ID = REPO_MAP[VARIANT]

# Noms de fichiers standardisés dans le docker-compose
MODEL_DEST_NAME  = f"gemma-4-{VARIANT}-it-{QUANT}.gguf"
MMPROJ_DEST_NAME = f"mmproj-gemma-4-{VARIANT}-it-f32.gguf"

# ── Vérification cache ────────────────────────────────────────────────────────
model_dest  = os.path.join(DEST, MODEL_DEST_NAME)
mmproj_dest = os.path.join(DEST, MMPROJ_DEST_NAME)

model_cached  = os.path.isfile(model_dest)  and os.path.getsize(model_dest)  > 100_000_000
mmproj_cached = os.path.isfile(mmproj_dest) and os.path.getsize(mmproj_dest) > 10_000_000

if model_cached and mmproj_cached:
    model_mb  = os.path.getsize(model_dest)  // (1024 * 1024)
    mmproj_mb = os.path.getsize(mmproj_dest) // (1024 * 1024)
    print(f"  ✅ Gemma4 {VARIANT.upper()} déjà en cache :")
    print(f"     model  : {MODEL_DEST_NAME} ({model_mb} MB)")
    print(f"     mmproj : {MMPROJ_DEST_NAME} ({mmproj_mb} MB) — image + audio encoder (f32)")
    print(f"  → make restart pour recharger le container")
    sys.exit(0)

# ── Vérification Python deps ──────────────────────────────────────────────────
try:
    from huggingface_hub import hf_hub_download, login, list_repo_files
except ImportError:
    print("  ❌ huggingface_hub non installé.", file=sys.stderr)
    print("     pip3 install huggingface_hub --break-system-packages", file=sys.stderr)
    sys.exit(1)

# ── Auth HuggingFace ──────────────────────────────────────────────────────────
hf_token = (
    os.environ.get("HF_TOKEN")
    or os.popen("grep '^HF_TOKEN=' .env 2>/dev/null | cut -d= -f2 | tr -d ' \"'").read().strip()
)
if hf_token:
    try:
        login(token=hf_token, add_to_git_credential=False)
        print("  🔑 HuggingFace token configuré")
    except Exception as e:
        print(f"  ⚠️  Token invalide : {e} — tentative anonyme")
else:
    print("  ⚠️  Aucun HF_TOKEN — téléchargement anonyme (peut être limité)")

# ── Listage des fichiers du repo ──────────────────────────────────────────────
print(f"\n  📋 Repo : {REPO_ID}")
print(f"  📦 Quant : {QUANT} | Variant : {VARIANT.upper()}")
print(f"  📁 Destination : {DEST}/\n")

try:
    available = list(list_repo_files(REPO_ID, token=hf_token or None))
except Exception as e:
    print(f"  ❌ Impossible d'accéder au repo {REPO_ID} : {e}", file=sys.stderr)
    sys.exit(1)

gguf_files = [f for f in available if f.endswith(".gguf")]

# ── Sélection du fichier model ────────────────────────────────────────────────
model_candidates = [f for f in gguf_files if QUANT in f and "mmproj" not in f.lower()]

if not model_candidates:
    print(f"  ❌ Aucun fichier {QUANT} trouvé dans {REPO_ID}", file=sys.stderr)
    print(f"     Fichiers disponibles : {[f for f in gguf_files if 'mmproj' not in f.lower()]}", file=sys.stderr)
    sys.exit(1)

model_src = model_candidates[0]

# ── Sélection du mmproj f32 ───────────────────────────────────────────────────
# IMPORTANT v14 : on cherche spécifiquement le mmproj f32 (pas Q4/Q8)
# Le mmproj f32 est requis pour l'encodeur audio (PR#21421).
# Les versions quantifiées (Q4_K, Q8_0) dégradent la qualité audio.
mmproj_candidates_f32 = [f for f in gguf_files if "mmproj" in f.lower() and "f32" in f.lower()]
mmproj_candidates_all = [f for f in gguf_files if "mmproj" in f.lower()]

if mmproj_candidates_f32:
    mmproj_src = mmproj_candidates_f32[0]
    print(f"  ℹ️  mmproj f32 sélectionné — optimal pour image + audio encoder")
elif mmproj_candidates_all:
    mmproj_src = mmproj_candidates_all[0]
    print(f"  ⚠️  mmproj f32 non trouvé, utilisation de : {mmproj_src}")
    print(f"     Qualité audio potentiellement réduite vs mmproj f32")
else:
    print(f"  ❌ Aucun fichier mmproj trouvé dans {REPO_ID}", file=sys.stderr)
    print(f"     Fichiers GGUF disponibles : {gguf_files}", file=sys.stderr)
    sys.exit(1)

# ── Affichage du plan ─────────────────────────────────────────────────────────
print(f"  Fichiers à télécharger :")
print(f"  → {model_src}")
print(f"     sauvé sous : {MODEL_DEST_NAME}")
print(f"  → {mmproj_src}")
print(f"     sauvé sous : {MMPROJ_DEST_NAME} (image + audio encoder f32)")
print()

size_estimates = {"e2b_Q4_K_M": "~3.5 GB", "e2b_Q8_0": "~5.0 GB", "e4b_Q4_K_M": "~4.9 GB"}
est = size_estimates.get(f"{VARIANT}_{QUANT}", "~3-5 GB")
print(f"  ⏱  Taille estimée : model {est}, mmproj f32 ~300-500 MB")
print(f"  ⏱  Durée estimée  : 10-30 min selon connexion\n")

# ── Téléchargement ────────────────────────────────────────────────────────────
def download_file(src_name: str, dest_path: str, label: str) -> None:
    """Télécharge un fichier et le renomme selon le nom standardisé."""
    if os.path.isfile(dest_path) and os.path.getsize(dest_path) > 1_000_000:
        size_mb = os.path.getsize(dest_path) // (1024 * 1024)
        print(f"  ⏭  {label} déjà présent ({size_mb} MB) — skip")
        return

    print(f"  📥 Téléchargement : {src_name} ...")
    try:
        tmp_path = hf_hub_download(
            repo_id=REPO_ID,
            filename=src_name,
            local_dir=DEST,
            token=hf_token or None,
        )
        if os.path.realpath(tmp_path) != os.path.realpath(dest_path):
            os.replace(tmp_path, dest_path)

        size_mb = os.path.getsize(dest_path) // (1024 * 1024)
        print(f"  ✅ {label} : {size_mb} MB → {os.path.basename(dest_path)}")
    except Exception as e:
        print(f"  ❌ Échec téléchargement {src_name} : {e}", file=sys.stderr)
        sys.exit(1)


download_file(model_src,  model_dest,  "Model")
download_file(mmproj_src, mmproj_dest, "MMProj f32 (image + audio encoder)")

# ── Résumé ────────────────────────────────────────────────────────────────────
total_mb = sum(
    os.path.getsize(os.path.join(DEST, f)) // (1024 * 1024)
    for f in [MODEL_DEST_NAME, MMPROJ_DEST_NAME]
    if os.path.isfile(os.path.join(DEST, f))
)

print()
print(f"  ✅ Gemma4 {VARIANT.upper()} téléchargé → {total_mb} MB dans {DEST}/")
print()
print(f"  mmproj f32 = encodeur image + audio (llama.cpp PR#21421)")
print(f"  Audio natif : texte + image + audio dans un seul service ai-gemma4")
print()
print(f"  Prochaine étape : make start")
print()
