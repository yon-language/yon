// Swizzled (eject) of @docusaurus/theme-classic's prism-include-languages.
// Loads the configured additionalLanguages AND registers a small grammar for
// Yon, so ```yon code blocks are syntax-highlighted with the site's theme.
// Keyword list generated from frontend/lexer.mll; regenerate on any
// lexer change (the Keywords chapter coverage check is the companion).
import siteConfig from '@generated/docusaurus.config';

export default function prismIncludeLanguages(PrismObject) {
  const {
    themeConfig: { prism },
  } = siteConfig;
  const { additionalLanguages } = prism;
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
      // Also catches Pi, Sigma, Type, Id from the HoTT layer.
      pattern: /\b[A-Z][A-Za-z0-9_]*\b/,
    },
    keyword: new RegExp(
      // Exactly the lowercase reserved words of frontend/lexer.mll, minus
      // true/false (boolean below); regression/test_website_surface.py holds
      // the two lists equal. Capitalized reserved words (Pi, Sigma, Id, Type)
      // are matched by the class-name rule above. Contextual phrase words
      // (object, oldest, newest, subset, conflict, transform) are free
      // identifiers and stay uncolored on purpose.
      '\\b(?:' +
        'absent|aggregates|algebra|along|and|as|at|back|be|by|carry|cell|clear|comp|compose|converts|do|drop|each|el_match|else|emit|error|every|exact|fold|for|forces|forever|from|fst|fun|functor|geomorph|given|hcomp|here|heyting|hit|hit_elim|if|import|in|ind_path|induct|internal|is|iter|law|maps|match|morph|morphism|most|move|multishot|nat|not|of|operation|or|otherwise|over|pair|parallel|place|plam|present|produce|promote|prop|pull|push|quote|reduction|refl|repeat|requires|resolves|return|scope|sequence|share|show|snd|space|spawn|stream|then|this|through|times|to|topos|unifies|unknown|uses|via|view|visits|when|where|while|wire|with' +
        ')\\b',
    ),
    boolean: /\b(?:true|false)\b/,
    function: /\b[a-z_][A-Za-z0-9_]*(?=\s*\()/,
    number: /\b\d[\d_]*(?:\.\d+)?(?:ms|s|min|h|d|y)?\b/,
    operator: /\|>|->|=>|⊣|∗|⇔|[-+*/%=<>!|&.]+/,
    punctuation: /[{}()[\];:,]/,
  };
  delete globalThis.Prism;
}
