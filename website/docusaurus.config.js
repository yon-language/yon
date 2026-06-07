// Yon · docs-only Docusaurus site with a custom landing at "/".
// @ts-check

// Code-block colors matched to the landing's syntax palette.
const yonCodeTheme = {
  plain: { color: '#EBE6FF', backgroundColor: '#1C173E' },
  styles: [
    { types: ['comment', 'prolog', 'doctype', 'cdata'], style: { color: '#8079b0' } },
    { types: ['punctuation'], style: { color: '#A59ED7' } },
    { types: ['operator', 'entity', 'url'], style: { color: '#A59ED7' } },
    { types: ['keyword', 'builtin', 'rule', 'atrule', 'important'], style: { color: '#f0bf72' } },
    { types: ['string', 'char', 'attr-value', 'regex', 'inserted'], style: { color: '#9fe3b8' } },
    { types: ['number', 'boolean', 'constant', 'symbol'], style: { color: '#f0bf72' } },
    { types: ['function', 'function-variable', 'method'], style: { color: '#c9c0ff' } },
    { types: ['class-name', 'maybe-class-name', 'namespace', 'type', 'tag'], style: { color: '#8fb6ff' } },
    { types: ['property', 'attr-name', 'selector'], style: { color: '#c9c0ff' } },
    { types: ['variable', 'parameter'], style: { color: '#EBE6FF' } },
    { types: ['deleted'], style: { color: '#e08aa0' } },
  ],
};

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Yon',
  tagline: 'The Topos of Programming',
  url: 'https://yon-lang.org',
  baseUrl: '/',
  trailingSlash: false,
  favicon: 'img/logo.svg',
  onBrokenLinks: 'warn',
  onBrokenMarkdownLinks: 'warn',
  i18n: { defaultLocale: 'en', locales: ['en'] },
  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: '/',          // docs-only mode; the home "/" is src/pages/index.js
          sidebarPath: './sidebars.js',
        },
        blog: false,
        theme: { customCss: './src/css/custom.css' },
      }),
    ],
  ],
  themes: [
    ["@easyops-cn/docusaurus-search-local", {
      hashed: true,
      indexBlog: false,
      docsRouteBasePath: "/",
      highlightSearchTermsOnTargetPage: true,
    }],
  ],
  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: 'img/social-card.png',
      metadata: [
        {name: 'keywords', content: 'topos programming language, category theory, MLIR, LLVM, content-addressed memory, Leech lattice, HoTT'},
        {name: 'twitter:card', content: 'summary_large_image'},
      ],
      colorMode: {
        defaultMode: 'dark',
        disableSwitch: true,
        respectPrefersColorScheme: false,
      },
      navbar: {
        logo: { alt: 'Yon', src: 'img/logo.svg' },
        title: 'Yon',
        items: [
          { to: '/intro', label: 'The Book', position: 'left' },
          { to: '/syntax-reference', label: 'Syntax Reference', position: 'left' },
          { to: '/book/benchmarks', label: 'Benchmarks', position: 'left' },
          { href: 'https://github.com/yon-language/yon', label: 'GitHub', position: 'right' },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              { label: 'The Book', to: '/intro' },
              { label: 'Syntax Reference', to: '/syntax-reference' },
              { label: 'Benchmarks', to: '/book/benchmarks' },
              { label: 'Future work', to: '/book/future-work' },
            ],
          },
          {
            title: 'Community',
            items: [
              { label: 'GitHub', href: 'https://github.com/yon-language/yon' },
              { label: 'r/YonLang', href: 'https://reddit.com/r/YonLang' },
              { label: 'LLVM Discourse', href: 'https://discourse.llvm.org/t/yon-a-new-research-language-compiling-to-native-code-via-mlir-and-llvm/90994' },
            ],
          },
        ],
        copyright: 'Yon · The Topos of Programming · AGPL',
      },
      prism: {
        theme: yonCodeTheme,
        darkTheme: yonCodeTheme,
        additionalLanguages: ['bash', 'c', 'json', 'toml'],
      },
    }),
};

export default config;
