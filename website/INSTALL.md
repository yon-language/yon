# Yon site, design + landing overlay

Drop these files into your existing `website/` (overwrite where noted). Built and tested against Docusaurus 3.6.

## Files
- `docusaurus.config.js`, **overwrite**. Dark-only theme, new navbar/footer, custom home.
- `src/css/custom.css`, **overwrite**. The whole design system (palette, fonts, code, sidebar, footer). Every book page inherits it.
- `src/pages/index.js` + `src/pages/index.module.css`, **add**. The landing (home).
- `src/components/YonMotif.js`, **add**. The live converging-arrows motif.
- `src/theme/prism-include-languages.js`, **add**. Registers a `yon` grammar so your ```yon snippets tokenize (plus loads bash/c/json/toml).
- `docs/`, **replace the whole folder**. Every page is now em-dash-free (258 removed). `intro.md` got the tone pass and moved off `/`; three book pages got clean `slug:`s; the rest are your originals with em dashes stripped.

## Run
```
npm install      # prism-react-renderer is already in your deps
npm start        # or: npm run build && npm run serve
```

## What changed in routing
- The **home `/`** is now the landing (`src/pages/index.js`).
- The book intro moved from `/` to **`/intro`** (navbar “The Book” points there).
- Clean slugs added: `/book/benchmarks`, `/book/limits`, `/book/topos-oriented-programming`. `/syntax-reference` is unchanged.

## Typography: em dashes removed everywhere
All 27 markdown pages were stripped of the em dash (`—`): prose dashes became commas, table placeholder cells went blank. Skim a couple of pages, a blind pass occasionally wants a colon or parentheses where it left a comma; point me at any that read wrong.

## Tone pass, scope (intentional)
Per the brief, the **landing + front doors** speak plainly; the **book and Benchmarks keep their method and caveats**. Edited: `intro.md` (removed “every snippet… compiled and run before being written down”, twice) and the book index blurb. The deep chapters’ technical uses of “honest” / “by design” / “numbers before claims” were left intact, they are specification, not credibility. Say the word and I’ll take the plain-voice pass chapter by chapter.

## Book theme + code highlighting
The book reads as a book now: **Space Grotesk** throughout (headings and body, same as the landing), **JetBrains Mono** for code, all on the indigo palette (sidebar, TOC, tables, blockquotes, pagination, admonitions themed). Code blocks use a custom Prism theme matched to the landing: gold keywords, blue types, purple functions, green strings. `yon`, `c`, `bash`, `json`, and `toml` all colorize.

## Assets
`static/img/logo.svg` and `static/img/social-card.png` are already in your tree; the design reuses them. Light mode is disabled (the brand is the dark indigo).
