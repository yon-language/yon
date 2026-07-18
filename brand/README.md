# Yon — kit del marchio

Il segno è **il conferimento**: due parentesi, sopra e sotto, che racchiudono l'oggetto
al centro. Nasce dai radicali di 與, il kanji da cui deriva よ (l'immersione di Yoneda):
𦥑 due mani dall'alto, 廾 due mani dal basso, e 与 al centro, la cosa che passa. Da lì
i significati del carattere: dare, conferire, prendere parte.

La stessa figura è Hom(−, A): un oggetto è ciò che gli altri gli conferiscono.

## Palette

| ruolo | hex |
|---|---|
| fondo profondo | `#241E4A` |
| anello | `#5B4A9E` |
| lavanda media | `#8B7DD0` |
| tratti chiari | `#E4DEF5` |
| oggetto conferito | `#F0B23C` |
| viola scuro su chiaro | `#3D3172` |
| ambra su chiaro | `#E09A18` |

## File

**Vettoriali**

- `yon-logo.svg` — marchio principale, badge su fondo scuro
- `yon-logo-light.svg` — per fondi chiari, contrasto alzato
- `yon-logo-mono.svg` — monocromatico, usa `currentColor` (eredita il colore del testo)
- `favicon.svg` — proporzioni semplificate per le dimensioni piccole: disco pieno
  senza anello, marchio più grande. Non usarlo sopra i 64 px.

**Raster**

- `yon-logo-{1024,512,256,128,64}.png` — trasparenti
- `yon-logo-light-512.png`
- `apple-touch-icon.png` — 180×180, fondo pieno (iOS non gestisce la trasparenza)
- `favicon-{48,32,16}x{48,32,16}.png`
- `favicon.ico` — multi-formato 16/32/48

## Quando usare quale

- Avatar GitHub, r/YonLang, social: `yon-logo-512.png`
- Header del sito su fondo scuro: `yon-logo.svg`
- Documenti, stampa, fondi chiari: `yon-logo-light.svg`
- README e badge testuali: `yon-logo-mono.svg`
- Sotto i 64 px: sempre la famiglia `favicon.*`

## Snippet per il sito

```html
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
```

In Docusaurus, `favicon.ico` va in `static/` e si dichiara in `docusaurus.config.js`
con `favicon: 'favicon.ico'`.

## Regole d'uso

- Spazio libero attorno al marchio: almeno metà del raggio del disco.
- Non ruotare, non deformare, non aggiungere ombre o sfumature.
- L'oggetto centrale resta sempre ambra: è l'unica nota calda e regge la lettura.
- Su fondi fotografici o rumorosi, usare il badge, mai la versione piana.
