# Yon — the book and the site

This directory is a standard Docusaurus project. The book lives in
`docs/book/` (chapters 00–22 plus appendices A–D). The suite
(`regression/test_syntax_triangle.py`) compiles the book's gated Yon blocks
and CodeWindows; blocks marked `<!-- yon-gate: illustrative -->` are fragments
and are not compiled on their own.

Read it directly on GitHub (the Markdown renders fine), or build the
site:

```bash
npm install
npm run build      # static site in build/
npm run serve      # preview at localhost:3000
```

The public site (yon-lang.org) is built from these sources; `build/`
and `node_modules/` are not committed.
