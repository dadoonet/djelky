#!/usr/bin/env bash
# rename-gcs-buckets.sh
#
# Migrates episode audio files from the legacy flat layout to the default layout:
#   OLD: gs://djdadoo/2025-02-06-TouraineTech.mp3
#   NEW: gs://djelky/mixes/2025/2025-02-06-touraine-tech-2025.mp3
#
# For each content/mixes/YYYY/slug/index.md:
#   1. freezes the current RSS <guid> (= the old audio URL) in a `guid:` frontmatter field,
#      so podcast apps do not see the episodes as new;
#   2. COPIES the object from the old bucket to the new one (the old bucket is left
#      untouched; delete it manually once the migration is validated);
#   3. removes `audio_url` (the URL is derived from baseAudioURL + bundle path).
#      Exception: non-mp3 files (e.g. .m4a) keep an explicit `audio_url` to the new location.
#
# The script is idempotent: it can be re-run after a partial failure.
#
# Usage:
#   ./rename-gcs-buckets.sh           # dry-run (shows what would happen)
#   ./rename-gcs-buckets.sh --apply   # move files and update frontmatter

set -euo pipefail

OLD_BUCKET="djdadoo"
NEW_BUCKET="djelky"
OLD_BASE="https://storage.googleapis.com/${OLD_BUCKET}/"
NEW_BASE="https://storage.googleapis.com/${NEW_BUCKET}/"

CONTENT_DIR="$(cd "$(dirname "$0")" && pwd)/content/mixes"
DRY_RUN=true
[[ "${1:-}" == "--apply" ]] && DRY_RUN=false

# ── GCS helpers (gcloud storage preferred, gsutil as fallback) ────────────────
if command -v gcloud &>/dev/null; then
  gcs_exists() { gcloud storage ls "$1" &>/dev/null; }
  gcs_mv()     { gcloud storage cp "$1" "$2" >/dev/null; }
elif command -v gsutil &>/dev/null; then
  gcs_exists() { gsutil -q stat "$1" &>/dev/null; }
  gcs_mv()     { gsutil -q cp "$1" "$2"; }
else
  echo "ERROR  neither gcloud nor gsutil found. Install the Google Cloud SDK." >&2
  exit 1
fi

echo "==> Checking buckets..."
for b in "$OLD_BUCKET" "$NEW_BUCKET"; do
  if ! gcs_exists "gs://${b}/"; then
    echo "  ERROR  cannot access gs://${b}/ (does it exist? are you authenticated: gcloud auth login ?)" >&2
    exit 1
  fi
  echo "  OK     gs://${b}/"
done
echo

if $DRY_RUN; then
  echo "==> Dry-run mode — nothing will be changed. Pass --apply to execute."
else
  echo "==> Apply mode — files will be moved and frontmatter updated."
fi
echo

# ── Frontmatter rewrite ───────────────────────────────────────────────────────
# $1 = file, $2 = guid to add (empty = none), $3 = new audio_url ("" = remove it)
rewrite_frontmatter() {
  local file="$1" guid="$2" new_audio="$3"
  awk -v guid="$guid" -v new_audio="$new_audio" '
    BEGIN { fm = 0; done_guid = 0 }
    /^---[ \t]*$/ && fm < 2 { fm++; print; next }
    fm == 1 && /^audio_url:/ {
      if (new_audio != "") print "audio_url: \"" new_audio "\""
      next
    }
    { print }
    fm == 1 && /^date:/ && guid != "" && !done_guid {
      print "guid: \"" guid "\""
      done_guid = 1
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

moved=0; skipped=0; errors=0

while IFS= read -r index_md; do
  dir=$(dirname "$index_md")
  slug=$(basename "$dir")
  year=$(basename "$(dirname "$dir")")

  audio_url=$(grep -m1 '^audio_url:' "$index_md" | sed -E 's/^audio_url:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' || true)
  has_guid=$(grep -c '^guid:' "$index_md" || true)

  # Already migrated (explicit URL on the new host)
  if [[ -n "$audio_url" && "$audio_url" == "$NEW_BASE"* ]]; then
    echo "  SKIP    $slug (already migrated)"; skipped=$((skipped+1)); continue
  fi

  if [[ -n "$audio_url" ]]; then
    old_obj="${audio_url#"$OLD_BASE"}"
    if [[ "$old_obj" == "$audio_url" ]]; then
      echo "  ERROR   $slug: audio_url is not under $OLD_BASE ($audio_url)" >&2
      errors=$((errors+1)); continue
    fi
  else
    old_obj="mixes/${year}/${slug}.mp3"      # default path used by Hugo before migration
  fi

  ext="${old_obj##*.}"
  new_obj="mixes/${year}/${slug}.${ext}"
  guid_value=""
  [[ "$has_guid" -eq 0 ]] && guid_value="${OLD_BASE}${old_obj}"
  new_audio=""
  [[ "$ext" != "mp3" ]] && new_audio="${NEW_BASE}${new_obj}"

  # 1. GCS move
  if gcs_exists "gs://${NEW_BUCKET}/${new_obj}"; then
    echo "  EXISTS  gs://${NEW_BUCKET}/${new_obj}"
  elif gcs_exists "gs://${OLD_BUCKET}/${old_obj}"; then
    echo "  COPY    gs://${OLD_BUCKET}/${old_obj}  →  gs://${NEW_BUCKET}/${new_obj}"
    if ! $DRY_RUN && ! gcs_mv "gs://${OLD_BUCKET}/${old_obj}" "gs://${NEW_BUCKET}/${new_obj}"; then
      echo "  ERROR   copy failed for ${old_obj}" >&2; errors=$((errors+1)); continue
    fi
  else
    echo "  ERROR   $slug: gs://${OLD_BUCKET}/${old_obj} not found" >&2
    errors=$((errors+1)); continue
  fi

  # 2. Frontmatter
  [[ -n "$guid_value" ]] && echo "          + guid: $guid_value"
  [[ -n "$audio_url" && -z "$new_audio" ]] && echo "          - audio_url (now derived)"
  [[ -n "$new_audio" ]] && echo "          ~ audio_url: $new_audio (non-mp3 override kept)"
  $DRY_RUN || rewrite_frontmatter "$index_md" "$guid_value" "$new_audio"

  moved=$((moved+1))
done < <(find "$CONTENT_DIR" -name index.md | sort)

echo
echo "==> Summary: ${moved} to process/processed, ${skipped} already done, ${errors} errors."
$DRY_RUN && echo "    Run with --apply to execute."
[[ $errors -eq 0 ]]
