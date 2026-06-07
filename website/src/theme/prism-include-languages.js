// Swizzled (eject) of @docusaurus/theme-classic's prism-include-languages.
// Loads the configured additionalLanguages AND registers a small grammar for
// Yon, so ```yon code blocks are syntax-highlighted with the site's theme.
// Keyword list derived from frontend/lexer.mll (book audit, 2026-06-06).
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
      // Also catches Pi, Sigma, Type, Id from the HoTT layer.
      pattern: /\b[A-Z][A-Za-z0-9_]*\b/,
    },
    keyword: new RegExp(
      '\\b(?:' +
      // core
      'fun|be|holds|return|if|then|else|when|otherwise|is|not|and|or|new|import|extends|from|to|as|in|here|package|requires|becomes|visits|move|view|handle|cell|share|uses|via' +
      // loops & blocks
      '|for|every|each|sequence|over|while|iter|do|forever|repeat|most|times|scope|with|where' +
      // worlds, places, topoi
      '|world|place|space|topos|objects|morphisms|terminal|prop|forces|topology' +
      // reductions
      '|reduction|forward|backward|bi|law|lawful|invertible|fold|multi_shot|on|on_error|on_morphism|on_object|operation|conflict_on' +
      // streams & sub-runtimes
      '|produce|emit|spawn|stream|buffer|drop_newest|drop_oldest' +
      // solving & algebra
      '|solve|unifies|resolves|converts|algebra|aggregates|heyt_int|subset_of|sum_f64' +
      // categorical layer (live: geomorph & friends, pullback/pushout)
      '|functor|functorial|nat_transform|adjunction|geomorph|geometric_morphism|f_star|f_lower_star|pull|push|pullback|pushout|compose|morph|exact' +
      // HoTT fragment & truth values
      '|refl|pair|fst|snd|ind_path|present|absent|unknown' +
      ')\\b'
    ),
    boolean: /\b(?:true|false)\b/,
    function: /\b[a-z_][A-Za-z0-9_]*(?=\s*\()/,
    number: /\b\d[\d_]*(?:\.\d+)?(?:ms|s|min|h|d|y)?\b/,
    operator: /\|>|->|=>|⊣|∗|⇔|[-+*/%=<>!|&.]+/,
    punctuation: /[{}()[\];:,]/,
  };
  delete globalThis.Prism;
}