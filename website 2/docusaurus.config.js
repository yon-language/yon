// Yon language documentation — docs-only Docusaurus site.
// @ts-check

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Yon',
  tagline: 'A topos-oriented programming language with a content-addressed lattice heap',
  url: 'https://yon-lang.org',
  baseUrl: '/',
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
          routeBasePath: '/',          // docs-only mode
          sidebarPath: './sidebars.js',
        },
        blog: false,
        theme: { customCss: './src/css/custom.css' },
      }),
    ],
  ],
  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: 'img/social-card.png',
      metadata: [
        {name: 'keywords', content: 'topos programming language, category theory, MLIR, LLVM, content-addressed memory, Leech lattice, HoTT'},
        {name: 'twitter:card', content: 'summary_large_image'},
      ],
      navbar: {
      logo: { alt: 'Yon', src: 'img/logo.svg' },
        title: 'Yon',
        items: [
          { type: 'docSidebar', sidebarId: 'docs', position: 'left', label: 'Docs' },
        ],
      },
      footer: {
        style: 'dark',
        copyright: `Yon — research language and working compiler.`,
      },
    }),
};

export default config;
