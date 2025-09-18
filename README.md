# Archive Unpacker Scripts

Two Bash scripts for unpacking multiple compressed files with automatic format detection.

## Scripts

- **`unpack.sh`** - Original implementation meeting exam requirements
- **`unpack2.sh`** - Enhanced version with best practices and extensible design

## Features

- **Format Detection**: Uses `file -b --mime-type` to detect compression type (ignores file extensions)
- **Supported Formats**: zip, gzip, bzip2, unix compress (.Z)
- **Directory Processing**: Handle files and directories, with optional recursive traversal
- **Verbose Mode**: Detailed output showing what's being processed
- **Exit Codes**: Returns exact number of files NOT decompressed
- **Safe Operation**: Keeps original archives intact, overwrites outputs automatically

## Usage

```bash
# Basic usage
./unpack.sh file1.zip file2.bz2

# Verbose mode
./unpack.sh -v file1.zip file2.bz2

# Recursive directory processing
./unpack.sh -r directory/

# Mixed options
./unpack.sh -v -r directory/
```

## Options

- `-v` (verbose): Show detailed processing information
- `-r` (recursive): Process subdirectories recursively

## Examples

```bash
# Single archive
./unpack.sh archive.zip
# Output: Decompressed 1 archive(s)

# Multiple files with verbose output
./unpack.sh -v archive.zip archive.bz2 text.txt
# Output:
# Unpacking archive.zip...
# Unpacking archive.bz2...
# Ignoring text.txt
# Decompressed 2 archive(s)

# Directory processing
./unpack.sh -v sample-files/
# Processes all files in sample-files/ (one level deep)

# Recursive processing
./unpack.sh -r sample-files/
# Processes sample-files/ and all subdirectories
```

## Requirements

- Linux/Unix environment (tested on Ubuntu/WSL)
- Required tools: `file`, `unzip`, `gzip`, `bzip2`, `uncompress`
- Bash 4.0+

## Installation

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt update
sudo apt install -y file unzip gzip bzip2 ncompress

# Make scripts executable
chmod +x unpack.sh unpack2.sh
```

## Exit Codes

- `0`: All files were successfully decompressed
- `1-255`: Number of files that were NOT decompressed (non-archives or failed attempts)

## Differences Between Scripts

### unpack.sh
- Minimal implementation meeting exam requirements
- Direct output redirection for stream decompressors
- Basic error handling

### unpack2.sh
- Enhanced with best practices:
  - Error visibility with line numbers (`trap ERR`)
  - Locale stability (`LC_ALL=C`)
  - Atomic writes for stream decompressors
  - Extensible format registry system
  - Comprehensive documentation

## Adding New Compression Formats

### unpack.sh (case-based)
Add a new case to `process_file()`:
```bash
application/x-newformat)
  log_unpack "$f"; if unpack_newformat "$f"; then ((++decompressed_count)); else ((++not_decompressed_count)); (( VERBOSE )) && printf 'Failed %s\n' "$(basename -- "$f")"; fi ;;
```

### unpack2.sh (registry-based)
1. Implement handler function:
```bash
unpack_newformat() {
  local f="$1" out
  out=$(derive_out_from_suffix "$f" ".new" ".NEW")
  require_cmd newformat || return 1
  write_atomic "$out" newformat -d -- "$f"
}
```

2. Register MIME type:
```bash
UNPACK_HANDLER_BY_MIME[application/x-newformat]=unpack_newformat
```

## Testing

The `sample-files/` directory contains test archives in various formats for validation.

## License

Educational project for Linux/Bash proficiency exam.
