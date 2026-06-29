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
      // Generated mechanically from frontend/lexer.mll (2026-06-08):
      // every lowercase reserved word, minus true/false (boolean below).
      // Capitalized reserved words (Pi, Sigma, Id, Type) are matched by
      // the class-name rule above. Contextual phrase words (object,
      // morphism, oldest, newest, subset, conflict, nat, transform) are
      // free identifiers and stay uncolored on purpose.
      '\\b(?:' +
        'absent|adjunction|aggregates|algebra|all|and|as|at|backward|be|becomes|bi|buffer|by|cell|compose|converts|do|drop|each|effects|else|emit|error|every|exact|extends|fold|for|forces|forever|forward|from|fst|fun|functor|functorial|geomorph|here|heyting|holds|if|import|in|ind_path|init|internal|invertible|is|iter|law|lawful|list|map|maps|morph|morphisms|most|move|multishot|new|not|objects|of|operation|or|otherwise|over|pair|partial|place|present|produce|prop|pull|pullback|push|pushout|reduction|refl|repeat|requires|resolves|return|scope|sequence|share|show|snd|verify|space|stream|terminal|then|times|to|topology|topos|unifies|unknown|uses|via|view|visits|when|where|while|wire|with|world' +
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
