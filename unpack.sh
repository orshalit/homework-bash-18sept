#!/usr/bin/env bash
# unpack.sh — unpack multiple archives (optionally recursively), using `file` for type detection.
#
# High-level behavior
# - Accepts files and/or directories. For directories: processes one level, or all subdirectories with -r.
# - Detects archive type strictly via `file -b --mime-type` (never by filename extensions).
# - Unpacks into the same directory as the source archive. Original archives are never deleted/modified.
# - Overwrites any existing output automatically.
# - Exits with the exact number of items that were NOT decompressed (non-archives or failed attempts).
# - In verbose mode (-v): prints one line per input processed: "Unpacking <name>..." or "Ignoring <name>";
#   if an unpack attempt fails, prints "Failed <name>".
#
# Design notes
# - `set -Eeuo pipefail` for robust error handling; increments use pre-increment form to avoid set -e traps.
# - Archive handlers are split into small functions to make adding formats straightforward.
# - Uses MIME types to branch logic, so adding a new format usually means adding a case + small unpack_* helper.
#
# Usage: unpack [-r] [-v] file [files...]

set -Eeuo pipefail
IFS=$'\n\t'

VERBOSE=0
RECURSIVE=0
decompressed_count=0
not_decompressed_count=0

usage() {
  echo "Usage: unpack [-r] [-v] file [files...]" >&2
}

log_unpack() { if (( VERBOSE )); then printf 'Unpacking %s...\n' "$(basename -- "$1")"; fi; }
log_ignore() { if (( VERBOSE )); then printf 'Ignoring %s\n'   "$(basename -- "$1")"; fi; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

mime_of() {
  file -b --mime-type -- "$1" 2>/dev/null || echo "application/octet-stream"
}

# Derive an output filename next to the source:
# - If one of the provided suffixes matches, strip it to produce the stem
# - Otherwise, append .out to the basename
derive_out_from_suffix() {
  local f="$1"; shift
  local dir base stem
  dir=$(dirname -- "$f")
  base=$(basename -- "$f")
  stem="$base"

  for sfx in "$@"; do
    if [[ "$base" == *"$sfx" ]]; then
      stem="${base%"$sfx"}"
      break
    fi
  done

  if [[ "$stem" == "$base" ]]; then
    stem="${base}.out"
  fi

  printf '%s/%s' "$dir" "$stem"
}

derive_out_gzip()     { derive_out_from_suffix "$1" ".gz" ".GZ" ".z" ".Z"; }
derive_out_bzip2()    { derive_out_from_suffix "$1" ".bz2" ".BZ2" ".bz" ".BZ"; }
derive_out_compress() { derive_out_from_suffix "$1" ".Z" ".z"; }

unpack_zip() {
  local f="$1" dir
  dir=$(dirname -- "$f")
  require_cmd unzip || return 1
  unzip -o -q -- "$f" -d "$dir"
}

unpack_gzip() {
  local f="$1" out
  out=$(derive_out_gzip "$f")
  require_cmd gzip || return 1
  gzip -cd -- "$f" > "$out"
}

unpack_bzip2() {
  local f="$1" out
  out=$(derive_out_bzip2 "$f")
  require_cmd bzip2 || return 1
  bzip2 -cd -- "$f" > "$out"
}

unpack_compress() {
  local f="$1" out
  out=$(derive_out_compress "$f")
  if require_cmd uncompress; then
    uncompress -c -- "$f" > "$out"
  elif require_cmd gzip; then
    # Fallback: gzip can usually decompress .Z
    gzip -cd -- "$f" > "$out"
  else
    return 1
  fi
}

process_file() {
  local f="$1" mime
  mime=$(mime_of "$f")

  case "$mime" in
    application/zip|application/x-zip|application/x-zip-compressed)
      log_unpack "$f"; if unpack_zip "$f";    then ((++decompressed_count)); else ((++not_decompressed_count)); (( VERBOSE )) && printf 'Failed %s\n' "$(basename -- "$f")"; fi ;;
    application/gzip|application/x-gzip)
      log_unpack "$f"; if unpack_gzip "$f";   then ((++decompressed_count)); else ((++not_decompressed_count)); (( VERBOSE )) && printf 'Failed %s\n' "$(basename -- "$f")"; fi ;;
    application/x-bzip2|application/bzip2)
      log_unpack "$f"; if unpack_bzip2 "$f";  then ((++decompressed_count)); else ((++not_decompressed_count)); (( VERBOSE )) && printf 'Failed %s\n' "$(basename -- "$f")"; fi ;;
    application/x-compress|application/compress)
      log_unpack "$f"; if unpack_compress "$f"; then ((++decompressed_count)); else ((++not_decompressed_count)); (( VERBOSE )) && printf 'Failed %s\n' "$(basename -- "$f")"; fi ;;
    *)
      log_ignore "$f"; ((++not_decompressed_count)) ;;
  esac
}

process_directory() {
  local d="$1"
  if (( RECURSIVE )); then
    while IFS= read -r -d '' f; do process_file "$f"; done < <(find "$d" -type f -print0)
  else
    while IFS= read -r -d '' f; do process_file "$f"; done < <(find "$d" -maxdepth 1 -type f -print0)
  fi
}

process_path() {
  local p="$1"
  if [[ -f "$p" ]]; then
    process_file "$p"
  elif [[ -d "$p" ]]; then
    process_directory "$p"
  else
    # Not a regular file or directory → count as not decompressed
    log_ignore "$p"
    ((not_decompressed_count++))
  fi
}

# ---- main ----
while getopts ":rv" opt; do
  case "$opt" in
    r) RECURSIVE=1 ;;
    v) VERBOSE=1 ;;
    \?) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if (( $# < 1 )); then usage; exit 2; fi
require_cmd file || { echo "Error: 'file' command is required." >&2; exit 2; }

for arg in "$@"; do
  process_path "$arg"
done

printf 'Decompressed %d archive(s)\n' "$decompressed_count"
# Exit with the exact number of files NOT decompressed (cap to 0..255 for portability)
exit $(( not_decompressed_count & 255 ))

