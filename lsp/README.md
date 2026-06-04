# Yon LSP

Language server per Yon. Gira sul client (stdin/stdout, JSON-RPC) — niente da
hostare. Riusa il frontend (parser, lexer, typechecker): un diagnostic LSP e'
un type_error del compilatore tradotto nel protocollo.

## Capacita' attuali
- Diagnostics in tempo reale (errori di sintassi e di tipo) su didOpen/didChange.
- Multi-error: tutti gli errori del programma, non solo il primo.

## Build
Il binario e' un executable del frontend (condivide i moduli):
```
cd frontend && dune build
# -> frontend/_build/default/yon_lsp.exe
```

## Uso CLI (test/CI)
```
yon_lsp.exe --check file.yon   # stampa diagnostics, exit code = #errori
```

## Editor
- Neovim: vedi editors/neovim.lua (vim.lsp nativo, nessun plugin).
- VSCode: vedi editors/vscode/ (client minimo + package.json).

## Roadmap (non ancora implementato)
- Hover: tipo di un'espressione al passaggio del mouse.
- Go-to-definition: place, fun, reduction.
- Completion: keyword, nomi di place/fun in scope.
- Document symbols: outline di world/place/fun.
