#!/usr/bin/env python3
"""
download_gemma4.py — Télécharge Gemma4 E2B ou E4B (model + mmproj BF16) depuis HuggingFace.

v14.1 correctifs :
  - Noms de fichiers standardisés bartowski (préfixe google_) :
      Avant : gemma-4-e2b-it-Q4_K_M.gguf
      Après : google_gemma-4-e2b-it-Q4_K_M.gguf
  - mmproj BF16 (recommandé PR#21421) au lieu de f32 :
      Avant : mmproj-gemma-4-e2b-it-f32.gguf
      Après : mmproj-google_gemma-4-e2b-it-bf16.gguf
  - Recherche bf16 en priorité, f16 en fallback, f32 en dernier recours
  - BF16 = optimal pour l'encodeur audio (conformer USM-style, PR#21421)
  - f32 et f16 fonctionnent mais qualité audio réduite vs BF16

Variables d'environnement :
  GEMMA4_VARIANT  "e2b" (défaut) ou "e4b"
  GEMMA4_QUANT    "Q4_K_M" (défaut) — ou Q6_K, Q8_0
  GEMMA4_DEST     Répertoire de destination (défaut : docker/models/gemma4)
  HF_TOKEN        Token HuggingFace (lu depuis .env si absent)

Repos HuggingFace utilisés :
  E2B : bartowski/google_gemma-4-E2B-it-GGUF
  E4B : bartowski/google_gemma-4-E4B-it-GGUF

Fichiers téléchargés (noms standardisés pour docker-compose + .env) :
  google_gemma-4-{e2b|e4b}-it-{QUANT}.gguf         → model principal
  mmproj-google_gemma-4-{e2b|e4b}-it-bf16.gguf      → mmproj BF16 (audio + image)

Budget RAM à titre indicatif :
  E2B Q4_K_M + mmproj BF16 : ~3.46 GB + ~1.00 GB = ~4.46 GB
  KV cache (ctx 4096 ×1)    :                        ~0.35 GB
  Infra NestJS + services    :                        ~1.50 GB
  ─────────────────────────────────────────────────────────────
  Total sur 8 GB RAM         :                        ~6.31 GB ✅

Utilisé par : Makefile → make download-gemma4
"""
import sys
import os

# ── Configuration ─────────────────────────────────────────────────────────────
VARIANT = os.environ.get("GEMMA4_VARIANT", "e2b").lower()
QUANT   = os.environ.get("GEMMA4_QUANT",   "Q4_K_M").upper()
DEST    = os.environ.get("GEMMA4_DEST",    "docker/models/gemma4")

os.makedirs(DEST, exist_ok=True)

# Nom du repo selon la variante (bartowski — noms en majuscules dans le repo)
REPO_MAP = {
    "e2b": "bartowski/google_gemma-4-E2B-it-GGUF",
    "e4b": "bartowski/google_gemma-4-E4B-it-GGUF",
}
if VARIANT not in REPO_MAP:
    print(f"  ❌ GEMMA4_VARIANT invalide : '{VARIANT}' — doit être 'e2b' ou 'e4b'", file=sys.stderr)
    sys.exit(1)

REPO_ID = REPO_MAP[VARIANT]

# ── Noms de fichiers de destination (v14.1 — convention bartowski) ─────────────
#
# bartowski utilise le préfixe "google_" dans les noms de fichiers.
# Les noms de destination correspondent EXACTEMENT à ce qui est dans le repo HF.
# Ils doivent correspondre aux variables GEMMA4_MODEL_FILE et GEMMA4_MMPROJ_FILE
# dans le fichier .env.
MODEL_DEST_NAME  = f"google_gemma-4-{VARIANT}-it-{QUANT}.gguf"
MMPROJ_DEST_NAME = f"mmproj-google_gemma-4-{VARIANT}-it-bf16.gguf"

# ── Vérification cache ────────────────────────────────────────────────────────
model_dest  = os.path.join(DEST, MODEL_DEST_NAME)
mmproj_dest = os.path.join(DEST, MMPROJ_DEST_NAME)

model_cached  = os.path.isfile(model_dest)  and os.path.getsize(model_dest)  > 100_000_000
mmproj_cached = os.path.isfile(mmproj_dest) and os.path.getsize(mmproj_dest) > 100_000_000

if model_cached and mmproj_cached:
    model_mb  = os.path.getsize(model_dest)  // (1024 * 1024)
    mmproj_mb = os.path.getsize(mmproj_dest) // (1024 * 1024)
    print(f"  ✅ Gemma4 {VARIANT.upper()} déjà en cache :")
    print(f"     model  : {MODEL_DEST_NAME} ({model_mb} MB)")
    print(f"     mmproj : {MMPROJ_DEST_NAME} ({mmproj_mb} MB) — BF16 (image + audio encoder)")
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
# Exclusion des mmproj et des fichiers bf16/f16 (modèles full-precision non quantifiés)
model_candidates = [
    f for f in gguf_files
    if QUANT in f
    and "mmproj" not in f.lower()
    and "bf16" not in f.lower()
    and "f16" not in f.lower()
    and "f32" not in f.lower()
]

if not model_candidates:
    print(f"  ❌ Aucun fichier {QUANT} trouvé dans {REPO_ID}", file=sys.stderr)
    non_mmproj = [f for f in gguf_files if "mmproj" not in f.lower()]
    print(f"     Fichiers disponibles : {non_mmproj}", file=sys.stderr)
    sys.exit(1)

model_src = model_candidates[0]

# ── Sélection du mmproj — priorité BF16 > F16 > F32 ─────────────────────────
#
# v14.1 : BF16 est recommandé par PR#21421 pour l'encodeur audio Gemma4.
# L'encodeur audio (conformer USM-style) fonctionne mieux avec une précision
# élevée. Les mmproj quantifiés (Q4/Q8) dégradent fortement la qualité audio.
#
# Ordre de priorité :
#   1. BF16 → qualité maximale (audio + image) ✅ recommandé
#   2. F16  → qualité proche de BF16, compatible avec tous les backends
#   3. F32  → plus gros mais même qualité que BF16 sur CPU
#   4. autres → non recommandé
#
mmproj_files = [f for f in gguf_files if "mmproj" in f.lower()]

mmproj_bf16 = [f for f in mmproj_files if "bf16" in f.lower()]
mmproj_f16  = [f for f in mmproj_files if "f16"  in f.lower() and "bf16" not in f.lower()]
mmproj_f32  = [f for f in mmproj_files if "f32"  in f.lower()]

if mmproj_bf16:
    mmproj_src = mmproj_bf16[0]
    print(f"  ℹ️  mmproj BF16 sélectionné — optimal pour audio + image (PR#21421)")
elif mmproj_f16:
    mmproj_src = mmproj_f16[0]
    print(f"  ⚠️  mmproj BF16 non trouvé — utilisation du F16 : {mmproj_src}")
    print(f"     Qualité audio légèrement réduite vs BF16")
elif mmproj_f32:
    mmproj_src = mmproj_f32[0]
    print(f"  ⚠️  mmproj BF16/F16 non trouvés — utilisation du F32 : {mmproj_src}")
    print(f"     F32 fonctionne mais est plus volumineux (~300 MB) que BF16")
else:
    print(f"  ❌ Aucun fichier mmproj trouvé dans {REPO_ID}", file=sys.stderr)
    print(f"     Fichiers GGUF disponibles : {gguf_files}", file=sys.stderr)
    sys.exit(1)

# ── Affichage du plan ─────────────────────────────────────────────────────────
print(f"  Fichiers à télécharger :")
print(f"  → {model_src}")
print(f"     sauvé sous : {MODEL_DEST_NAME}")
print(f"  → {mmproj_src}")
print(f"     sauvé sous : {MMPROJ_DEST_NAME} (BF16 — image + audio encoder)")
print()

# Estimation taille selon variante + quantization
size_estimates = {
    "e2b_Q4_K_M": ("~3.5 GB", "~1.0 GB"),
    "e2b_Q8_0":   ("~5.0 GB", "~1.0 GB"),
    "e4b_Q4_K_M": ("~4.9 GB", "~1.0 GB"),
    "e4b_Q8_0":   ("~7.0 GB", "~1.0 GB"),
}
model_est, mmproj_est = size_estimates.get(f"{VARIANT}_{QUANT}", ("~3-7 GB", "~1.0 GB"))
print(f"  ⏱  Taille estimée : model {model_est}, mmproj BF16 {mmproj_est}")
print(f"  ⏱  Durée estimée  : 15-40 min selon connexion\n")

# ── Téléchargement ────────────────────────────────────────────────────────────
def download_file(src_name: str, dest_path: str, label: str) -> None:
    """
    Télécharge un fichier depuis HuggingFace et le place à dest_path.
    Idempotent : si le fichier est déjà présent et > 1 MB, skip.
    """
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
        # hf_hub_download peut placer le fichier dans un sous-dossier de cache HF.
        # On déplace le fichier vers le chemin de destination standardisé.
        if os.path.realpath(tmp_path) != os.path.realpath(dest_path):
            os.replace(tmp_path, dest_path)

        size_mb = os.path.getsize(dest_path) // (1024 * 1024)
        print(f"  ✅ {label} : {size_mb} MB → {os.path.basename(dest_path)}")
    except Exception as e:
        print(f"  ❌ Échec téléchargement {src_name} : {e}", file=sys.stderr)
        sys.exit(1)


download_file(model_src,  model_dest,  "Model")
download_file(mmproj_src, mmproj_dest, "MMProj BF16 (audio + image encoder)")

# ── Résumé ────────────────────────────────────────────────────────────────────
total_mb = sum(
    os.path.getsize(os.path.join(DEST, f)) // (1024 * 1024)
    for f in [MODEL_DEST_NAME, MMPROJ_DEST_NAME]
    if os.path.isfile(os.path.join(DEST, f))
)

print()
print(f"  ✅ Gemma4 {VARIANT.upper()} téléchargé → {total_mb} MB dans {DEST}/")
print()
print(f"  mmproj BF16 = encodeur image + audio (recommandé PR#21421)")
print(f"  Fichiers configurés dans .env :")
print(f"    GEMMA4_MODEL_FILE={MODEL_DEST_NAME}")
print(f"    GEMMA4_MMPROJ_FILE={MMPROJ_DEST_NAME}")
print()
print(f"  Prochaine étape : make start")
print()
