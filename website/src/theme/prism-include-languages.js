// Swizzled (eject) of @docusaurus/theme-classic's prism-include-languages.
// Loads the configured additionalLanguages AND registers a small grammar for
// Yon, so ```yon code blocks are syntax-highlighted with the site's theme.
// The keyword and boolean lists are generated from regression/GRAMMAR.tokens
// (tools/gen_highlighters.py); the rest of the grammar is written by hand.
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
      // Capitalized identifiers: places, worlds, builtins (Text, HashMap...)
      // Also catches Pi, Sigma, Type, Id from the HoTT layer.
      pattern: /\b[A-Z][A-Za-z0-9_]*\b/,
    },
    // The lowercase words of frontend/lexer.mll that a live form reads, minus
    // true/false (boolean below); both lists are generated, between the two
    // markers, from regression/GRAMMAR.tokens. Capitalized reserved words (Pi, Sigma, Id, Type)
    // are matched by the class-name rule above. Contextual phrase words
    // (object, oldest, newest, subset, conflict, transform) are free
    // identifiers and stay uncolored on purpose.
    // BEGIN generated from regression/GRAMMAR.tokens, do not edit (python3 tools/gen_highlighters.py)
    keyword: new RegExp(
      '\\b(?:' +
        'absent|aggregates|algebra|and|as|at|back|by|carried|cell|clear|comp|compose|converts|do|drop|each|el_match|else|emit|error|escape|every|exact|fold|for|forces|forever|from|fst|fun|functor|geomorph|given|hcomp|here|heyting|if|import|in|ind_path|induct|internal|is|iter|law|maps|match|morph|morphism|most|move|multishot|mut|nat|not|of|operation|or|otherwise|over|pair|parallel|place|present|produce|promote|proof|prop|pull|push|quote|reduction|refl|repeat|requires|resolves|return|scope|sequence|share|show|snd|space|spawn|stream|then|this|through|times|to|topos|unifies|unknown|uses|via|view|visits|walk|when|where|while|wire|with' +
        ')\\b',
    ),
    boolean: /\b(?:false|true)\b/,
    // END generated from regression/GRAMMAR.tokens
    function: /\b[a-z_][A-Za-z0-9_]*(?=\s*\()/,
    number: /\b\d[\d_]*(?:\.\d+)?(?:ms|s|min|h|d|y)?\b/,
    // BEGIN generated from regression/GRAMMAR.tokens, do not edit (python3 tools/gen_highlighters.py): operators
    operator: /&&\?|\.->|<=>|=>\?|>->|\|->|\|\|\?|!=|!\?|&&|&\?|\+\+|->|:=|:U|<-|<=|==|=>|>=|\^\?|\|>|\|\?|\|\||~\?|!|%|&|\*|\+|-|\/|<|=|>|@|\^|\||~|¬|→|↔|↦|↪|∧|∨|≠/,
    // END generated from regression/GRAMMAR.tokens: operators
    punctuation: /[{}()[\];:,]/,
  };
  delete globalThis.Prism;
}
