// Cloudflare Worker for the Yon site.
//
// Everything is served from the static Docusaurus build (env.ASSETS), with the
// security headers below and long-lived caching for the hashed assets.

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
