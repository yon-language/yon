// Swizzled (eject) of @docusaurus/theme-classic's prism-include-languages.
// Loads the configured additionalLanguages AND registers a small grammar for
// Yon, so ```yon code blocks are syntax-highlighted with the site's theme.
import siteConfig from '@generated/docusaurus.config';

export default function prismIncludeLanguages(PrismObject) {
  const {
    themeConfig: {prism},
  } = siteConfig;
  const {additionalLanguages} = prism;

  // prism-react-renderer uses its own Prism instance; Prism's language
  // components register onto globalThis.Prism, so mount it temporarily.
  globalThis.Prism = PrismObject;

  additionalLanguages.forEach((lang) => {
    if (lang === 'php') {
      require('prismjs/components/prism-markup-templating.js');
    }
    require(`prismjs/components/prism-${lang}`);
  });

  // ---- Yon ----
  PrismObject.languages.yon = {
    comment: {
      pattern: /\/\/.*|\/\*[\s\S]*?\*\//,
      greedy: true,
    },
    string: {
      pattern: /"(?:\\.|[^"\\\r\n])*"/,
      greedy: true,
    },
    'class-name': {
      // Capitalized identifiers: places, worlds, builtins (String, HashMap...)
      pattern: /\b[A-Z][A-Za-z0-9_]*\b/,
    },
    keyword:
      /\b(?:fun|be|holds|return|if|then|else|when|is|for|every|while|becomes|visits|requires|place|world|space|package|import|extends|prop|move|view|reduction|geomorph|produce|emit|spawn|here|from|to|in|as|and|or|not|present|absent|unknown|refl|pair|fst|snd)\b/,
    boolean: /\b(?:true|false)\b/,
    function: /\b[a-z_][A-Za-z0-9_]*(?=\s*\()/,
    number: /\b\d[\d_]*(?:\.\d+)?\b/,
    operator: /\|>|->|=>|⊣|∗|⇔|[-+*/%=<>!|&.]+/,
    punctuation: /[{}()[\];:,]/,
  };

  delete globalThis.Prism;
}
