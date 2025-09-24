# Archive Unpacker Script

A Bash script for unpacking multiple compressed files with automatic format detection and extensible design.

## Features

- **Format Detection**: Uses `file -b --mime-type` to detect compression type (ignores file extensions)
- **Supported Formats**: zip, gzip, bzip2, unix compress (.Z)
- **Directory Processing**: Handle files and directories, with optional recursive traversal
- **Verbose Mode**: Detailed output showing what's being processed
- **Exit Codes**: Returns exact number of files NOT decompressed
- **Safe Operation**: Keeps original archives intact, overwrites outputs automatically
- **Extensible Design**: Easy to add new compression formats via handler functions
- **Error Handling**: Comprehensive error reporting with line numbers
- **Atomic Operations**: Safe file writing for stream decompressors

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

- `-v, --verbose`: Show detailed processing information
- `-r, --recursive`: Process subdirectories recursively
- `-h, --help`: Show usage information and exit
- `--add-custom FORMAT [CMD MIME1[,MIME2]]`: Add support for a new compression format

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

# Add custom format support
./unpack.sh --add-custom xz
# Creates handlers/xz.sh and updates unpack.conf

# Show help
./unpack.sh --help
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

# Make script executable
chmod +x unpack.sh
```

## Exit Codes

- `0`: All files were successfully decompressed
- `1-255`: Number of files that were NOT decompressed (non-archives or failed attempts)
- `255`: More than 255 files were not decompressed (capped at 255 due to Unix limitations)

**Note:** Exit codes are capped at 255 due to Unix process limitations. If more than 255 files fail to decompress, the exit code will be 255, indicating "many failures."

## Adding New Compression Formats

The script provides two ways to add support for new compression formats:

### Method 1: Using --add-custom (Recommended)

The `--add-custom` feature automatically generates handler code and configuration:

```bash
# Add xz support (basic)
./unpack.sh --add-custom xz

# Add xz support with specific command and MIME types
./unpack.sh --add-custom xz xz xz,xz-compressed

# Add 7zip support
./unpack.sh --add-custom 7zip 7z 7z,7zip
```

**What --add-custom does:**
1. Creates `handlers/xz.sh` with the handler function
2. Adds MIME mappings to `unpack.conf` (if MIME types provided)
3. Validates format names and command names
4. Checks if the required command is available
5. Provides installation hints if command is missing

**Generated files:**
- `handlers/FORMAT.sh` - Handler implementation
- `unpack.conf` - MIME type mappings

### Method 2: Manual Implementation

For advanced customization, you can manually create handlers:

1. **Create handler file** (`handlers/newformat.sh`):
```bash
#!/usr/bin/env bash
unpack_newformat() {
  local f="$1" out
  out=$(derive_out_stream "$f")
  require_cmd newformat || return 1
  write_atomic "$out" newformat -d -- "$f"
}
```

2. **Add MIME mappings** to `unpack.conf`:
```
application/x-newformat unpack_newformat
application/newformat unpack_newformat
```

### How It Works

The script automatically:
- Sources all `handlers/*.sh` files on startup
- Loads MIME mappings from `unpack.conf`
- Uses `file -b --mime-type` for format detection
- Handles output filename derivation (always `.out` for stream formats)
- Provides atomic file writing and error handling

## Testing

The `sample-files/` directory contains test archives in various formats for validation:

```bash
# Test with sample files
./unpack.sh -v sample-files/

# Test recursive processing
./unpack.sh -v -r sample-files/

# Test exit codes
./unpack.sh sample-files/; echo "Exit code: $?"
```

The test directory includes:
- **Supported formats**: `.zip`, `.gz`, `.bz2`, `.Z` (compress)
- **Unsupported formats**: `.xz`, plain text files
- **Mixed scenarios** for comprehensive testing

### Testing Custom Formats

After adding a custom format, test it:

```bash
# Add xz support
./unpack.sh --add-custom xz

# Test the new format
./unpack.sh -v test.xz

# Verify MIME detection
file -b --mime-type test.xz
```

## Environment Variables

- `MAX_FILE_SIZE`: Maximum file size in bytes (default: 2GB)
- `MAX_FILES`: Maximum number of files to process (default: 100,000)

```bash
# Process larger files
MAX_FILE_SIZE=5368709120 ./unpack.sh large-archive.zip

# Limit file processing
MAX_FILES=1000 ./unpack.sh -r huge-directory/
```