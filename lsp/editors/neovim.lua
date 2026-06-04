-- Yon LSP per Neovim (0.8+). Niente plugin esterni: usa vim.lsp nativo.
-- 1. Builda l'LSP:  cd frontend && dune build
-- 2. Punta YON_LSP_BIN al binario (o modifica il path sotto).
-- 3. Metti questo in init.lua (o source-alo).

local bin = os.getenv("YON_LSP_BIN")
  or "frontend/_build/default/yon_lsp.exe"

vim.filetype.add({ extension = { yon = "yon" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "yon",
  callback = function(args)
    vim.lsp.start({
      name = "yon-lsp",
      cmd = { bin },
      root_dir = vim.fs.dirname(args.file),
    })
  end,
})
