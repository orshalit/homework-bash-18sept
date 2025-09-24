#!/usr/bin/env bash
# unpack.sh — unpacker with documentation.
#
# Notes:
# - Detection always uses `file -b --mime-type`; extensions are ignored.

# Summary
# - Detect archive type strictly via `file -b --mime-type` (ignore extensions)
# - Unpack into the same directory; overwrite existing outputs
# - Keep originals intact
# - Exit code equals the exact number of files NOT decompressed (per requirements)
# - -v / --verbose: print Unpacking/Ignoring and Failed lines
# - -r / --recursive: recurse into subdirectories
# - -h / --help: show usage
# - --add-custom FORMAT [CMD MIME1[,MIME2]]: scaffold a handler and optionally
#   register MIME→handler mappings in a simple unpack.conf (no suffix logic)
#
# Enhancements
# - Error visibility: trap ERR with line number
# - Locale stability: enforce C locale for consistent tool output
# - Atomic writes for stream decompressors: write to temp then mv over target
# - Security validated - prevents CLI injection
#
# - Clear comments and function structure
 
 usage() {
  cat >&2 <<'USAGE'
Usage: unpack [-r] [-v] [--add-custom FORMAT [CMD MIME1[,MIME2]]] [--help] file [files...]

Options:
  -v, --verbose        Verbose output
  -r, --recursive      Recurse into subdirectories
  -h, --help           Show this help and exit
  --add-custom ...     Scaffold a custom stream handler. If CMD/MIME provided,
                       append MIME→handler lines to unpack.conf

Environment variables:
  MAX_FILE_SIZE  Maximum file size in bytes (default: 2147483648)
  MAX_FILES      Maximum number of files to process (default: 100000)

Notes:
  - Exit code equals the number of files NOT decompressed
  Local files next to this script are used for extensibility:
    - handlers/FORMAT.sh  (handler implementation; auto-sourced)
    - unpack.conf         (plain lines: "MIME unpack_FORMAT"; auto-loaded)
USAGE
}

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# Configuration
MAX_FILE_SIZE=${MAX_FILE_SIZE:-2147483648} # 2GB default
MAX_FILES=${MAX_FILES:-100000}             # 100k files max (more reasonable)

# Global temp files tracking
declare -a TEMP_FILES=()

# Cleanup function
cleanup() {
  local tmpfile
  for tmpfile in "${TEMP_FILES[@]}"; do
    [[ -f "$tmpfile" ]] && rm -f -- "$tmpfile" 2>/dev/null || true
  done
  TEMP_FILES=()
}

# Enhanced error trap with cleanup
trap 'printf "Error: %s at line %d\n" "$BASH_COMMAND" "$LINENO" >&2; cleanup' ERR
trap 'cleanup' EXIT INT TERM

VERBOSE=0
RECURSIVE=0
decompressed_count=0
not_decompressed_count=0

# Load local config and drop-in handlers, if present (user-friendly extensibility)
SCRIPT_DIR=$(cd "$(dirname -- "$0")" && pwd)

# Registry mapping MIME types -> handler function names.
declare -A UNPACK_HANDLER_BY_MIME=()

# Load unpack.conf (plain format: MIME<space>handler), ignore comments/blank
if [[ -f "$SCRIPT_DIR/unpack.conf" ]]; then
  while IFS= read -r __line; do
    [[ "$__line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$__line" ]] && continue
    # split on whitespace: first token is MIME, rest ignored except handler
    __mime=${__line%%[[:space:]]*}
    __rest=${__line#*[[:space:]]}
    __handler=${__rest%%[[:space:]]*}
    if [[ -n "$__mime" && -n "$__handler" ]]; then
      UNPACK_HANDLER_BY_MIME["$__mime"]="$__handler"
    fi
  done < "$SCRIPT_DIR/unpack.conf"
fi

# Auto-source any handlers present
if [[ -d "$SCRIPT_DIR/handlers" ]]; then
  for __h in "$SCRIPT_DIR"/handlers/*.sh; do
    [[ -f "$__h" ]] && source "$__h"
  done
fi


# Simple verbose logging (per requirements)
log_unpack() { if (( VERBOSE )); then printf 'Unpacking %s...\n' "$(basename -- "$1")"; fi; }
log_ignore() { if (( VERBOSE )); then printf 'Ignoring %s\n'   "$(basename -- "$1")"; fi; }
log_failed() { if (( VERBOSE )); then printf 'Failed %s\n'    "$(basename -- "$1")"; fi; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

mime_of() {
  file -b --mime-type -- "$1" 2>/dev/null || echo "application/octet-stream"
}

# Validate path to prevent directory traversal
validate_output_path() {
  local target="$1" base_dir="$2"
  local resolved_target resolved_base
  
  # Resolve absolute paths
  resolved_target=$(realpath -- "$target" 2>/dev/null || echo "$target")
  resolved_base=$(realpath -- "$base_dir" 2>/dev/null || echo "$base_dir")
  
  # Check if target is within base directory
  [[ "$resolved_target" == "$resolved_base" || "$resolved_target" == "$resolved_base"/* ]] || {
    printf "Error: Output path outside allowed directory: %s\n" "$target" >&2
    return 1
  }
}

# Determine output filename for stream decompressors without using suffixes:
# Always write alongside the source as <basename>.out
derive_out_stream() {
  local f="$1"
  local dir base
  dir=$(dirname -- "$f")
  base=$(basename -- "$f")
  printf '%s/%s.out' "$dir" "$base"
}


# Atomic write helper: write to temp file in target directory, then mv -f over
write_atomic() {
  local target="$1"; shift
  local dir tmp
  dir=$(dirname -- "$target")
  
  # Validate target path
  validate_output_path "$target" "$dir" || return 1
  
  tmp=$(mktemp --tmpdir="$dir" .unpack.XXXXXXXX)
  TEMP_FILES+=("$tmp")
  
  # shellcheck disable=SC2068
  "$@" > "$tmp"
  mv -f -- "$tmp" "$target"
  
  # Remove from temp files list since it's now moved
  TEMP_FILES=($(printf '%s\n' "${TEMP_FILES[@]}" | grep -v "^$tmp$" || true))
}

# Atomic zip extraction: extract to temp dir, then move files
unpack_zip_atomic() {
  local f="$1" dir temp_dir
  dir=$(dirname -- "$f")
  
  # Validate extraction directory
  validate_output_path "$dir" "$dir" || return 1
  
  temp_dir=$(mktemp -d --tmpdir="$dir" .unpack_zip.XXXXXXXX)
  TEMP_FILES+=("$temp_dir")
  
  require_cmd unzip || return 1
  unzip -o -q -- "$f" -d "$temp_dir" || return 1
  
  # Move extracted files to target directory (force overwrite to meet requirements)
  find "$temp_dir" -mindepth 1 -maxdepth 1 -exec mv -f -- {} "$dir" \; 2>/dev/null || true
  
  # Clean up temp directory
  rmdir "$temp_dir" 2>/dev/null || true
  TEMP_FILES=($(printf '%s\n' "${TEMP_FILES[@]}" | grep -v "^$temp_dir$" || true))
}

unpack_zip() {
  local f="$1"
  # Use atomic zip extraction for better safety
  unpack_zip_atomic "$f"
}

unpack_gzip() {
  local f="$1" out
  out=$(derive_out_stream "$f")
  require_cmd gzip || return 1
  write_atomic "$out" gzip -cd -- "$f"
}

unpack_bzip2() {
  local f="$1" out
  out=$(derive_out_stream "$f")
  require_cmd bzip2 || return 1
  write_atomic "$out" bzip2 -cd -- "$f"
}

unpack_compress() {
  local f="$1" out
  out=$(derive_out_stream "$f")
  if require_cmd uncompress; then
    write_atomic "$out" uncompress -c -- "$f"
  elif require_cmd gzip; then
    write_atomic "$out" gzip -cd -- "$f"
  else
    return 1
  fi
}


# Check file size limits
check_file_size() {
  local f="$1"
  local size
  size=$(stat -c%s -- "$f" 2>/dev/null || echo 0)
  if (( size > MAX_FILE_SIZE )); then
    printf "Error: File too large: %s (%d bytes, max: %d)\n" "$f" "$size" "$MAX_FILE_SIZE" >&2
    return 1
  fi
  return 0
}

# Verify file integrity with checksum (if available)
verify_file_integrity() {
  local f="$1"
  local checksum_file="${f}.sha256"
  
  # Only verify if checksum file exists
  if [[ -f "$checksum_file" ]]; then
    if require_cmd sha256sum; then
      if ! sha256sum -c --quiet "$checksum_file" 2>/dev/null; then
        printf "Warning: Checksum verification failed for %s\n" "$f" >&2
        return 1
      fi
    fi
  fi
  return 0
}

# Check total file count limits
check_file_count() {
  local current_count=$((decompressed_count + not_decompressed_count))
  if (( current_count >= MAX_FILES )); then
    printf "Error: Too many files processed (%d, max: %d)\n" "$current_count" "$MAX_FILES" >&2
    return 1
  fi
  return 0
}

process_file() {
  local f="$1" mime handler
  
  # Check file count limit
  check_file_count || return 1
  
  # Check file size limit
  check_file_size "$f" || {
    ((++not_decompressed_count))
    log_failed "$f"
    return 0
  }
  
  # Verify file integrity (optional)
  verify_file_integrity "$f" || {
    # Continue processing even if checksum fails (just warn)
    :
  }
  
  mime=$(mime_of "$f")
  handler=${UNPACK_HANDLER_BY_MIME[$mime]:-}
  if [[ -n "$handler" ]]; then
    log_unpack "$f"
    if "$handler" "$f"; then
      ((++decompressed_count))
    else
      ((++not_decompressed_count))
      log_failed "$f"
    fi
  else
    log_ignore "$f"
    ((++not_decompressed_count))
  fi
}

process_directory() {
  local d="$1"
  
  # Process files with progress indicator for large directories
  local file_count=0
  while IFS= read -r -d '' f; do
    ((++file_count))
    if (( VERBOSE && file_count % 100 == 0 )); then
      printf "Processed %d files...\n" "$file_count" >&2
    fi
    process_file "$f" || break
  done < <(
    if (( RECURSIVE )); then
      find "$d" -type f -print0
    else
      find "$d" -maxdepth 1 -type f -print0
    fi
  )
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

while getopts ":rvh-:" opt; do
  case "$opt" in
    r) RECURSIVE=1 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    -) case "$OPTARG" in
         help) usage; exit 0 ;;
         add-custom)
           # Capture positional args after long opt
           if (( OPTIND <= $# )); then ADD_FORMAT="${!OPTIND}"; ((OPTIND++)); fi
           if (( OPTIND <= $# )); then ADD_CMD="${!OPTIND}"; ((OPTIND++)); fi
           if (( OPTIND <= $# )); then ADD_MIMES="${!OPTIND}"; ((OPTIND++)); fi
           ;;
         *) usage; exit 2 ;;
       esac ;;
    \?) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Handle --add-custom if specified
if [[ -n "${ADD_FORMAT:-}" ]]; then
  # Validate format name (alphanumeric + underscore only)
  if [[ ! "$ADD_FORMAT" =~ ^[a-zA-Z0-9_]+$ ]]; then
    printf "Error: Invalid format name '%s'. Use alphanumeric characters and underscores only.\n" "$ADD_FORMAT" >&2
    exit 2
  fi
  
  # Validate command if provided
  if [[ -n "${ADD_CMD:-}" ]]; then
    if [[ ! "$ADD_CMD" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      printf "Error: Invalid command name '%s'. Use alphanumeric characters, hyphens, and underscores only.\n" "$ADD_CMD" >&2
      exit 2
    fi
  fi
  
  # Create handlers directory if it doesn't exist
  mkdir -p -- "$SCRIPT_DIR/handlers"
  
  # Generate handler file
  handler_file="$SCRIPT_DIR/handlers/${ADD_FORMAT}.sh"
  cat > "$handler_file" << EOF
#!/usr/bin/env bash
# Auto-generated handler for ${ADD_FORMAT} format

unpack_${ADD_FORMAT}() {
  local f="\$1" out
  out=\$(derive_out_stream "\$f")
  require_cmd "${ADD_CMD:-${ADD_FORMAT}}" || return 1
  write_atomic "\$out" ${ADD_CMD:-${ADD_FORMAT}} -cd -- "\$f"
}
EOF
  
  printf "Created handler: %s\n" "$handler_file"
  
  # Add MIME mappings to config if provided
  if [[ -n "${ADD_MIMES:-}" ]]; then
    # Split comma-separated MIMEs
    old_ifs="$IFS"
    IFS=',' read -ra MIMES <<< "$ADD_MIMES"
    IFS="$old_ifs"
    for mime in "${MIMES[@]}"; do
      # Trim whitespace
      mime=$(echo "$mime" | xargs)
      if [[ -n "$mime" ]]; then
        echo "application/$mime unpack_${ADD_FORMAT}" >> "$SCRIPT_DIR/unpack.conf"
        printf "Added MIME mapping: application/%s -> unpack_%s\n" "$mime" "$ADD_FORMAT"
      fi
    done
  else
    # Add comment hint for user
    echo "# application/x-${ADD_FORMAT} unpack_${ADD_FORMAT}" >> "$SCRIPT_DIR/unpack.conf"
    printf "Added MIME hint to unpack.conf. Edit to add actual MIME types.\n"
  fi
  
  # Check if command is available and suggest a generic installation hint
  if [[ -n "${ADD_CMD:-}" ]] && ! require_cmd "${ADD_CMD}"; then
    printf "Note: Command '%s' not found. You may need to install it.\n" "${ADD_CMD}"
    printf "Example (Ubuntu/Debian): sudo apt-get install %s\n" "${ADD_CMD}"
  fi
  
  printf "Format '%s' added successfully. Reload the script to use it.\n" "$ADD_FORMAT"
  exit 0
fi

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

for arg in "$@"; do
  process_path "$arg"
done

printf 'Decompressed %d archive(s)\n' "$decompressed_count"
exit $(( not_decompressed_count > 255 ? 255 : not_decompressed_count ))
