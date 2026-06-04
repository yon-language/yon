import React from 'react';
import ComponentCreator from '@docusaurus/ComponentCreator';

export default [
  {
    path: '/',
    component: ComponentCreator('/', '8d1'),
    routes: [
      {
        path: '/',
        component: ComponentCreator('/', '9f0'),
        routes: [
          {
            path: '/',
            component: ComponentCreator('/', '8f5'),
            routes: [
              {
                path: '/book/arrows',
                component: ComponentCreator('/book/arrows', 'a5e'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/benchmarks',
                component: ComponentCreator('/book/benchmarks', '696'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/capabilities',
                component: ComponentCreator('/book/capabilities', '39c'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/coming-from',
                component: ComponentCreator('/book/coming-from', '49d'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/content-addressed-heap',
                component: ComponentCreator('/book/content-addressed-heap', '83e'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/control-flow',
                component: ComponentCreator('/book/control-flow', 'd6f'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/data-structures-on-the-lattice',
                component: ComponentCreator('/book/data-structures-on-the-lattice', '30c'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/functions-and-effects',
                component: ComponentCreator('/book/functions-and-effects', '355'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/glossary',
                component: ComponentCreator('/book/glossary', 'b2a'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/hello-world',
                component: ComponentCreator('/book/hello-world', 'edc'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/heyting-core',
                component: ComponentCreator('/book/heyting-core', '868'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/hott-types',
                component: ComponentCreator('/book/hott-types', 'cc6'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/how-spaces-talk',
                component: ComponentCreator('/book/how-spaces-talk', '8d0'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/limits',
                component: ComponentCreator('/book/limits', 'f0d'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/projects-and-packages',
                component: ComponentCreator('/book/projects-and-packages', '053'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/showpieces',
                component: ComponentCreator('/book/showpieces', '571'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/spaces-and-packages',
                component: ComponentCreator('/book/spaces-and-packages', 'f30'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/standard-library',
                component: ComponentCreator('/book/standard-library', '2a3'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/the-project',
                component: ComponentCreator('/book/the-project', 'e08'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/tooling',
                component: ComponentCreator('/book/tooling', '321'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/topos-oriented-programming',
                component: ComponentCreator('/book/topos-oriented-programming', 'd80'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/values-and-bindings',
                component: ComponentCreator('/book/values-and-bindings', '47b'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/values-cells-lifetime',
                component: ComponentCreator('/book/values-cells-lifetime', '0bd'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/when-things-go-wrong',
                component: ComponentCreator('/book/when-things-go-wrong', '5ef'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/book/worlds-and-places',
                component: ComponentCreator('/book/worlds-and-places', '03a'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/category/the-book',
                component: ComponentCreator('/category/the-book', '652'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/syntax-reference',
                component: ComponentCreator('/syntax-reference', '666'),
                exact: true,
                sidebar: "docs"
              },
              {
                path: '/',
                component: ComponentCreator('/', '7da'),
                exact: true,
                sidebar: "docs"
              }
            ]
          }
        ]
      }
    ]
  },
  {
    path: '*',
    component: ComponentCreator('*'),
  },
];
