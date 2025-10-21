## Complete Flow of sops.nvim: From First Principles

Let me walk through exactly how this plugin works, starting with Neovim's plugin loading system and buffer lifecycle.

### Part 1: Neovim Plugin Loading Architecture

**Plugin Directory Structure:**
- Neovim automatically sources files in `plugin/` directory when it starts
- Files in `lua/` directory are loaded on-demand via `require()`

**Initialization Flow:**

1. **Neovim starts** → automatically loads all files in `plugin/` directory
2. **plugin/sops.lua:1** executes: `require("sops").setup()`
3. This loads `lua/sops.lua` and calls its `setup()` function
4. The plugin is now registered and waiting for file operations

### Part 2: Setting Up The Autocommands (lua/sops.lua:119-170)

When `setup()` runs, it registers **global autocommands** that watch for file operations:

```lua
vim.api.nvim_create_autocmd({ "BufReadPost", "FileReadPost" }, {
    pattern = SUPPORTED_FILE_FORMATS,  -- *.yaml, *.yml, *.json, *.dockerconfigjson
    callback = function() ... end
})
```

**Key autocmd events:**
- **BufReadPost**: Fires AFTER a buffer has been created and file content loaded into it
- **FileReadPost**: Fires AFTER reading a file with `:read` command

These autocmds are **pattern-filtered** - they only trigger for files matching `*.yaml`, `*.yml`, `*.json`, etc.

### Part 3: Opening a SOPS File (Decryption Flow)

Let's trace what happens when you run `:edit secrets.yaml`:

**Step 1: Neovim's Normal File Loading**
```
:edit secrets.yaml
  ↓
Neovim creates buffer
  ↓
Neovim reads file from disk into buffer
  ↓
Buffer now contains ENCRYPTED content: "apikey: ENC[AES256_GCM,data:...,mac: ENC[...]"
  ↓
BufReadPost event fires
```

**Step 2: sops.nvim's BufReadPost Handler (lua/sops.lua:131-168)**

```lua
callback = function()
    local bufnr = vim.api.nvim_get_current_buf()
    if not util.is_sops_encrypted(bufnr) then
        return  -- Not a SOPS file, do nothing
    end
```

First, it checks if the buffer actually contains SOPS-encrypted data by scanning for markers:
- YAML: `mac: ENC[`
- JSON: `"mac": "ENC[`

If NOT encrypted → exits early, normal file editing proceeds

**Step 3: Per-Buffer Autocmd Registration (lua/sops.lua:137-165)**

If the file IS encrypted, the plugin creates a **per-buffer autocommand group**:

```lua
local au_group = vim.api.nvim_create_augroup("sops.nvim" .. bufnr, { clear = true })
```

This group is unique to THIS buffer (e.g., "sops.nvim5" for buffer #5).

It registers TWO buffer-local autocmds:

**3a. BufDelete autocmd (lua/sops.lua:139-149):**
```lua
vim.api.nvim_create_autocmd("BufDelete", {
    buffer = bufnr,  -- Only for THIS buffer
    group = au_group,
    callback = function()
        -- Clean up our autocmds when buffer is deleted
        vim.api.nvim_clear_autocmds({ buffer = bufnr, group = au_group })
    end,
})
```
This ensures cleanup when you close the buffer (`:bd`, `:q`, etc.).

**3b. BufWriteCmd autocmd (lua/sops.lua:151-165):**
```lua
vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,  -- Only for THIS buffer
    group = au_group,
    callback = function()
        if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
            return  -- No changes, skip encryption
        end
        sops_encrypt_buffer(bufnr)
    end,
})
```

**Critical:** `BufWriteCmd` **intercepts** the normal write operation. When this autocmd exists, Neovim does NOT write the buffer to disk itself - it delegates entirely to this callback.

**Step 4: Decryption Process (lua/sops.lua:167 → sops_decrypt_buffer)**

```lua
sops_decrypt_buffer(bufnr)
```

This function:

**4a. Spawns SOPS process (lua/sops.lua:25-28):**
```lua
vim.system(
    { "sops", "--decrypt", "--input-type", filetype, "--output-type", filetype, path },
    { cwd = cwd, text = true },
    function(out) ... end
)
```

`vim.system()` runs asynchronously - Neovim doesn't freeze. The callback executes when SOPS finishes.

**4b. Inside the callback (lua/sops.lua:29-57):**

```lua
vim.schedule(function()  -- Schedule for main event loop (thread safety)
```

All UI operations must happen on the main thread, so `vim.schedule()` is required.

**4c. Replace buffer contents (lua/sops.lua:36-42):**
```lua
local decrypted_lines = vim.fn.split(out.stdout, "\n", false)

vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, decrypted_lines)
```

**Critical setting: `buftype=acwrite`**
- "acwrite" = "autocommand write"
- Tells Neovim: "This buffer's contents should NOT be written directly to disk"
- ALL write operations (`:w`, `:wq`, etc.) will trigger `BufWriteCmd` instead
- This is how the plugin intercepts saves

**4d. Clear undo history (lua/sops.lua:44-48):**
```lua
local old_undo_levels = vim.api.nvim_get_option_value("undolevels", { buf = bufnr })
vim.api.nvim_set_option_value("undolevels", -1, { buf = bufnr })
vim.cmd('exe "normal a \\<BS>\\<Esc>"')  -- Trigger undo tree rebuild
vim.api.nvim_set_option_value("undolevels", old_undo_levels, { buf = bufnr })
```

**Why?** Without this, pressing `u` (undo) could revert to the ENCRYPTED content, leaking secrets into the undo tree.

Setting `undolevels=-1` temporarily disables undo, the normal mode command forces a rebuild, then undo is re-enabled.

**4e. Mark as unmodified (lua/sops.lua:50-51):**
```lua
vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
```

The buffer now shows decrypted content, but is marked as "saved" (no `[+]` indicator).

**4f. Trigger syntax highlighting (lua/sops.lua:53-56):**
```lua
vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
```

Since we just swapped the buffer contents, we manually trigger `BufReadPost` again. This makes filetype detection, syntax highlighting, LSP, etc. re-run on the DECRYPTED content.

**Result:** You now see and can edit the plaintext secrets!

### Part 4: Saving a SOPS File (Encryption Flow)

User makes edits and runs `:w`:

**Step 1: Neovim's Write Attempt**
```
:w
  ↓
Neovim sees buftype=acwrite
  ↓
Instead of writing to disk, fires BufWriteCmd event
  ↓
Our handler (lua/sops.lua:154-164) executes
```

**Step 2: Check If Modified (lua/sops.lua:157-161)**
```lua
if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    vim.notify("Skipping sops encryption. File has not been modified", vim.log.levels.INFO)
    return
end
```

**Optimization:** SOPS always generates different ciphertext (due to random IV/nonce), even for identical plaintext. This would show as a "change" in git even when content is identical. By checking `modified` flag, we avoid spurious diffs.

**Step 3: Encryption Process (lua/sops.lua:163 → sops_encrypt_buffer)**

**3a. Setup (lua/sops.lua:64-89):**
```lua
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local editor_script = vim.fs.joinpath(plugin_root, "scripts", "sops-editor.sh")
```

Locates the editor script using debug info to find the plugin's installation directory.

```lua
local temp_file = vim.fn.tempname()
local plaintext_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
vim.fn.writefile(plaintext_lines, temp_file)
```

Writes the DECRYPTED buffer contents to a temporary file.

**3b. The SOPS Editor Hack (lua/sops.lua:91-97):**
```lua
vim.system({ "sops", "edit", path }, {
    cwd = cwd,
    env = {
        SOPS_EDITOR = editor_script,       -- Path to scripts/sops-editor.sh
        SOPS_NVIM_TEMP_FILE = temp_file,   -- Path to our temp file with plaintext
    },
    text = true,
}, function(out) ... end)
```

**How `sops edit` normally works:**
1. SOPS decrypts the file to a temp file
2. Opens `$EDITOR` (or `$SOPS_EDITOR`) with that temp file
3. Waits for editor to exit
4. Reads the temp file back
5. Encrypts and writes to original path

**The Hack:**
We set `SOPS_EDITOR` to our bash script. When SOPS "opens the editor":

```bash
# scripts/sops-editor.sh
cat "$SOPS_NVIM_TEMP_FILE" > "$1"
```

Our script:
- Receives SOPS's temp file path as `$1`
- Overwrites it with contents from `$SOPS_NVIM_TEMP_FILE` (our buffer's plaintext)
- Exits immediately

**Result:** SOPS thinks a human edited the file, but we've programmatically injected our buffer's content. SOPS then encrypts it and writes to disk.

**3c. Completion (lua/sops.lua:99-114):**
```lua
function(out)
    vim.schedule(function()
        cleanup()  -- Delete temp file

        if out.code ~= 0 then
            vim.notify("SOPS failed to edit file: " .. (out.stderr or ""), vim.log.levels.WARN)
            return
        end

        vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
```

Mark buffer as saved (removes `[+]` indicator).

### Part 5: The Critical Buffer Option: `buftype=acwrite`

This is the linchpin of the entire system:

**Normal buffer (`buftype=""`):**
- `:w` → Neovim writes buffer lines directly to file
- No intervention possible

**acwrite buffer (`buftype="acwrite"`):**
- `:w` → Fires `BufWriteCmd` autocmd
- NO direct write to disk
- Plugin must handle ALL write logic

**Why this matters:**
- Without `acwrite`, Neovim would write DECRYPTED plaintext to disk
- With `acwrite`, we intercept and run SOPS encryption instead
- The encrypted file on disk is always ciphertext
- The buffer in memory is always plaintext

### Summary: The Complete Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Neovim Startup                                           │
│    plugin/sops.lua sources → lua/sops.lua:setup()           │
│    Registers BufReadPost/FileReadPost autocmds              │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. User Opens File (:edit secrets.yaml)                     │
│    Neovim loads ENCRYPTED bytes into buffer                 │
│    BufReadPost fires                                        │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Plugin Detects SOPS File                                 │
│    Checks for "mac: ENC[" marker                            │
│    Creates per-buffer autocmds (BufWriteCmd, BufDelete)     │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. Decryption                                               │
│    Spawns: sops --decrypt secrets.yaml                      │
│    Sets buftype=acwrite                                     │
│    Replaces buffer content with PLAINTEXT                   │
│    Clears undo history                                      │
│    Marks as unmodified                                      │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. User Edits and Saves (:w)                                │
│    Neovim sees buftype=acwrite                              │
│    BufWriteCmd fires (instead of normal write)              │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. Encryption                                               │
│    Writes buffer to temp file                               │
│    Spawns: sops edit secrets.yaml                           │
│      with SOPS_EDITOR=sops-editor.sh                        │
│    Script copies temp file → SOPS temp file                 │
│    SOPS encrypts and writes CIPHERTEXT to disk              │
│    Marks buffer as unmodified                               │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. User Closes Buffer (:bd)                                 │
│    BufDelete fires                                          │
│    Cleans up per-buffer autocmds                            │
└─────────────────────────────────────────────────────────────┘
```

### Key Takeaways

1. **Autocommand Events Are Everything:** The plugin uses Neovim's event system as hook points - it never polls or monitors files
2. **BufReadPost** = "file was just loaded" → decrypt
3. **BufWriteCmd** = "user wants to save" → encrypt
4. **BufDelete** = "buffer closing" → cleanup

5. **`buftype=acwrite`** is the secret weapon that lets the plugin intercept ALL save operations

6. **Async operations** (`vim.system()`) prevent UI freezing during SOPS commands

7. **The editor hack** avoids spawning a real text editor by tricking SOPS into thinking it did

8. **Security measures**: Undo history clearing prevents leaking plaintext through undo operations

This architecture is elegant because it works transparently - users edit "normal" buffers, unaware that every read/write is being encrypted/decrypted behind the scenes.
