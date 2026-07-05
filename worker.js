// Cloudflare Worker for the Yon site.
//
// Everything is served from the static Docusaurus build (env.ASSETS) EXCEPT
// /install.sh, which is proxied straight from the repo on `main`. Proxy, not a
// 302 redirect, so the rustup-style one-liner works with plain curl:
//
//   curl --proto '=https' --tlsv1.2 -sSf https://yon-lang.org/install.sh | bash
//
// (a redirect would need `curl -L`; a 200 does not).
const INSTALL_SH =
  "https://raw.githubusercontent.com/yon-language/yon/main/install.sh";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/install.sh") {
      const upstream = await fetch(INSTALL_SH, { cf: { cacheTtl: 300 } });
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": "text/x-shellscript; charset=utf-8",
          "cache-control": "public, max-age=300",
        },
      });
    }
    return env.ASSETS.fetch(request);
  },
};
