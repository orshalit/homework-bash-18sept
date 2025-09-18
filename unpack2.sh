#!/usr/bin/env bash
# unpack2 — like unpack.sh, with extra best-practice hardening and documentation.
#
# Summary
# - Detect archive type strictly via `file -b --mime-type` (ignore extensions)
# - Unpack into the same directory; overwrite existing outputs
# - Keep originals intact
# - Exit with the exact number of files NOT decompressed
# - -v: print Unpacking/Ignoring and Failed lines
# - -r: recurse into subdirectories
#
# Enhancements over unpack.sh
# - Error visibility: trap ERR with line number
# - Locale stability: enforce C locale for consistent tool output
# - Atomic writes for stream decompressors: write to temp then mv over target
# - Clear comments and function structure

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

trap 'printf "Error: %s at line %d\n" "$BASH_COMMAND" "$LINENO" >&2' ERR

VERBOSE=0
RECURSIVE=0
decompressed_count=0
not_decompressed_count=0

# Registry mapping MIME types -> handler function names.
declare -A UNPACK_HANDLER_BY_MIME=()

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

# Optional: add .xz support as an example of easy extensibility
derive_out_xz()      { derive_out_from_suffix "$1" ".xz" ".XZ"; }

# Atomic write helper: write to temp file in target directory, then mv -f over
write_atomic() {
  local target="$1"; shift
  local dir tmp
  dir=$(dirname -- "$target")
  tmp=$(mktemp --tmpdir="$dir" .unpack2.XXXXXXXX)
  # shellcheck disable=SC2068
  "$@" > "$tmp"
  mv -f -- "$tmp" "$target"
}

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
  write_atomic "$out" gzip -cd -- "$f"
}

unpack_bzip2() {
  local f="$1" out
  out=$(derive_out_bzip2 "$f")
  require_cmd bzip2 || return 1
  write_atomic "$out" bzip2 -cd -- "$f"
}

unpack_compress() {
  local f="$1" out
  out=$(derive_out_compress "$f")
  if require_cmd uncompress; then
    write_atomic "$out" uncompress -c -- "$f"
  elif require_cmd gzip; then
    write_atomic "$out" gzip -cd -- "$f"
  else
    return 1
  fi
}

unpack_xz() {
  local f="$1" out
  out=$(derive_out_xz "$f")
  require_cmd xz || return 1
  write_atomic "$out" xz -cd -- "$f"
}

process_file() {
  local f="$1" mime handler
  mime=$(mime_of "$f")
  handler=${UNPACK_HANDLER_BY_MIME[$mime]:-}
  if [[ -n "$handler" ]]; then
    log_unpack "$f"
    if "$handler" "$f"; then
      ((++decompressed_count))
    else
      ((++not_decompressed_count))
      (( VERBOSE )) && printf 'Failed %s\n' "$(basename -- "$f")"
    fi
  else
    log_ignore "$f"
    ((++not_decompressed_count))
  fi
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
    log_ignore "$p"
    ((++not_decompressed_count))
  fi
}

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

# Register supported formats (simple to extend):
# zip
UNPACK_HANDLER_BY_MIME[application/zip]=unpack_zip
UNPACK_HANDLER_BY_MIME[application/x-zip]=unpack_zip
UNPACK_HANDLER_BY_MIME[application/x-zip-compressed]=unpack_zip
# gzip
UNPACK_HANDLER_BY_MIME[application/gzip]=unpack_gzip
UNPACK_HANDLER_BY_MIME[application/x-gzip]=unpack_gzip
# bzip2
UNPACK_HANDLER_BY_MIME[application/x-bzip2]=unpack_bzip2
UNPACK_HANDLER_BY_MIME[application/bzip2]=unpack_bzip2
# UNIX compress (.Z)
UNPACK_HANDLER_BY_MIME[application/x-compress]=unpack_compress
UNPACK_HANDLER_BY_MIME[application/compress]=unpack_compress
# Example new format: xz
UNPACK_HANDLER_BY_MIME[application/x-xz]=unpack_xz

for arg in "$@"; do
  process_path "$arg"
done

printf 'Decompressed %d archive(s)\n' "$decompressed_count"
exit $(( not_decompressed_count & 255 ))


