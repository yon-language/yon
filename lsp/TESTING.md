# Testare l'LSP Yon in Cursor e vim

Binario (path assoluto su questa macchina):
`/home/claude/full/turno_33_part17_2026-05-30/frontend/_build/default/yon_lsp.exe`

Builda con: `cd frontend && dune build`

## Cursor / VSCode
Cursor parla LSP come VSCode. Due strade:

### A. Estensione (completa)
```
cd lsp/editors/vscode
npm install
# imposta yon.lspPath = path assoluto al binario nelle settings
# F5 in VSCode/Cursor per lanciare un Extension Development Host
```

### B. Test rapido senza estensione (consigliato per provare subito)
Crea un file `test.yon`, poi configura un generic LSP client.
In Cursor: installa l'estensione "yon" da lsp/editors/vscode, oppure usa
il settings.json del workspace per associare .yon e puntare al binario.

## vim / Neovim
Neovim 0.8+ ha vim.lsp nativo. Copia lsp/editors/neovim.lua in init.lua
(o source-alo), esportando il path del binario:
```
export YON_LSP_BIN="/home/claude/full/turno_33_part17_2026-05-30/frontend/_build/default/yon_lsp.exe"
nvim test.yon
```
Poi apri un .yon: gli errori appaiono inline, :lua vim.lsp.buf.hover() per
l'hover, :lua vim.lsp.buf.document_symbol() per l'outline, completion con
<C-x><C-o> (omnifunc).

## Test al volo da terminale (no editor)
```
/home/claude/full/turno_33_part17_2026-05-30/frontend/_build/default/yon_lsp.exe --check test.yon   # diagnostics, exit code = #errori
```

## Cosa aspettarsi
- Errori di sintassi/tipo sottolineati in rosso mentre scrivi (multi-error).
- Hover su un'espressione: descrizione del nodo.
- Outline: world / place / fun / move / reduction con le loro firme.
- Completion: keyword Yon + nomi di place/fun/world in scope.
