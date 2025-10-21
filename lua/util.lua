local M = {}

local SOPS_MARKER_BYTES = {
  ["yaml"] = "mac: ENC[",
  ["yaml.helm-values"] = "mac: ENC[",
  ["json"] = '"mac": "ENC[',
}

M.is_sops_encrypted = function(bufnr)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  local marker = SOPS_MARKER_BYTES[filetype]
  if not marker then
    return false
  end

  -- SOPS metadata is always at the end of the file, so only check the last ~20 lines
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(0, line_count - 20)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, -1, false)

  for _, line in ipairs(lines) do
    if string.find(line, marker, nil, true) then
      return true
    end
  end

  return false
end

return M
