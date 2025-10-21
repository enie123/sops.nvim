# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

sops.nvim is a Neovim plugin that provides transparent decryption and encryption of SOPS-encrypted files. The plugin automatically detects SOPS-encrypted YAML/JSON files and handles decryption on read and encryption on write.

## Development Commands

### Linting
```bash
luacheck lua/ plugin/
```

### Formatting
```bash
stylua --check lua/ plugin/
stylua lua/ plugin/  # to fix formatting
```

Code style: 2 spaces, 120 column width, Unix line endings, double quotes preferred.

## Architecture

### Core Components

1. **plugin/sops.lua** - Entry point that calls `setup()`

2. **lua/sops.lua** - Main module containing:
   - `sops_decrypt_buffer(bufnr)`: Decrypts SOPS file via `sops --decrypt` command, swaps buffer contents with decrypted data, sets buffer to `acwrite` mode, and clears undo history
   - `sops_encrypt_buffer(bufnr)`: Encrypts buffer via `sops edit` with custom editor script hack (writes plaintext to temp file, editor script copies to SOPS temp file)
   - `setup(opts)`: Creates autocmds for BufReadPost/FileReadPost on supported patterns, sets up BufWriteCmd to intercept saves

3. **lua/util.lua** - Utility functions:
   - `is_sops_encrypted(bufnr)`: Detects SOPS files by searching for marker bytes (`mac: ENC[` for YAML, `"mac": "ENC[` for JSON)

4. **scripts/sops-editor.sh** - Bash script used as SOPS_EDITOR during encryption. Copies plaintext from temp file to SOPS's temp file, enabling transparent encryption without opening an external editor.

### File Format Support

Default patterns: `*.yaml`, `*.yml`, `*.json`, `*.dockerconfigjson`

Additional formats can be added via `setup({ supported_file_formats = { ... } })`

### Encryption/Decryption Flow

**Decryption (on file open):**
1. BufReadPost/FileReadPost triggers on supported patterns
2. Check if file contains SOPS markers (lua/util.lua:9-23)
3. If encrypted, run `sops --decrypt` with filetype-based input/output types
4. Replace buffer contents with decrypted data, set `buftype=acwrite`
5. Clear undo history to prevent leaking plaintext
6. Set up per-buffer autocmds for saving and cleanup

**Encryption (on save):**
1. BufWriteCmd intercepts write operation
2. Skip if buffer not modified (lua/sops.lua:157-161)
3. Write buffer contents to temp file
4. Run `sops edit` with `SOPS_EDITOR` pointing to sops-editor.sh
5. Script copies temp file contents to SOPS's temp file
6. SOPS encrypts and writes to disk

### Key Design Decisions

- Uses `buftype=acwrite` to intercept all write operations
- Employs editor script hack (from vscode-sops) to avoid spawning actual editor during encryption
- Checks modification status before saving to avoid false positive file changes
- Creates per-buffer autocmd groups for proper cleanup on buffer delete
- Clears undo history after decryption to prevent plaintext leakage
- Uses `vim.system()` for async command execution

## Dependencies

- SOPS CLI tool must be available on PATH
- Requires Neovim with Lua API support (nvim_buf_set_lines, vim.system, etc.)
