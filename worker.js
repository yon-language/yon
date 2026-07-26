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

const SECURITY_HEADERS = {
  "strict-transport-security": "max-age=31536000",
  "x-content-type-options": "nosniff",
  "x-frame-options": "SAMEORIGIN",
  "referrer-policy": "strict-origin-when-cross-origin",
};

function withHeaders(res, extra) {
  const out = new Response(res.body, res);
  for (const [k, v] of Object.entries(extra)) out.headers.set(k, v);
  return out;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/install.sh") {
      const upstream = await fetch(INSTALL_SH, { cf: { cacheTtl: 300 } });
      return withHeaders(
        new Response(upstream.body, {
          status: upstream.status,
          headers: {
            "content-type": "text/x-shellscript; charset=utf-8",
            "cache-control": "public, max-age=300",
          },
        }),
        SECURITY_HEADERS,
      );
    }
    const res = await env.ASSETS.fetch(request);
    const headers = { ...SECURITY_HEADERS };
    // Docusaurus content-hashes everything under /assets/, so those files can
    // be cached forever; HTML and other unhashed paths keep must-revalidate.
    if (url.pathname.startsWith("/assets/")) {
      headers["cache-control"] = "public, max-age=31536000, immutable";
    }
    return withHeaders(res, headers);
  },
};
