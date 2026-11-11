// Relais Cloudflare Worker : lit une page produit et renvoie {title, brand, shop, price, currency, images[]}
// Variables à créer dans Cloudflare (Settings → Variables) :
//   ALLOWED_ORIGINS = https://TON-PSEUDO.github.io      (séparer par des virgules si plusieurs)
// Aucune clé secrète n'est nécessaire.

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const allowed = (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
    const okOrigin = allowed.includes(origin) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
    const cors = {
      'Access-Control-Allow-Origin': okOrigin ? origin : 'null',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Vary': 'Origin',
    };
    if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
    if (request.method !== 'GET') return json({error: 'GET seulement'}, 405, cors);
    if (!okOrigin) return json({error: 'origine non autorisée'}, 403, cors);

    const target = new URL(request.url).searchParams.get('url') || '';
    let u;
    try { u = new URL(target); } catch { return json({error: 'url invalide'}, 400, cors); }
    if (!/^https?:$/.test(u.protocol) || isPrivateHost(u.hostname)) return json({error: 'url refusée'}, 400, cors);

    try {
      const r = await fetch(u.href, {headers: {'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml', 'Accept-Language': 'fr-FR,fr;q=0.9,en;q=0.7'}, redirect: 'follow', cf: {cacheTtl: 3600}});
      if (!r.ok) return json({error: 'page inaccessible (' + r.status + ')'}, 502, cors);
      const html = (await r.text()).slice(0, 1500000);
      return json(parseProduct(html, r.url || u.href), 200, cors);
    } catch (e) {
      return json({error: 'lecture impossible'}, 502, cors);
    }
  },
};

function json(o, status, cors) { return new Response(JSON.stringify(o), {status, headers: {...cors, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'public, max-age=3600'}}); }
function isPrivateHost(h) {
  h = h.toLowerCase();
  return h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || !h.includes('.') ||
    /^(127\.|10\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(h) || h.includes(':');
}
const decode = s => String(s || '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).trim();

export function parseProduct(html, pageUrl) {
  const metas = [];
  for (const m of html.matchAll(/<meta\b[^>]*>/gi)) {
    const t = m[0];
    const key = (t.match(/\b(?:property|name|itemprop)\s*=\s*["']([^"']+)["']/i) || [])[1];
    const val = (t.match(/\bcontent\s*=\s*"([^"]*)"/i) || t.match(/\bcontent\s*=\s*'([^']*)'/i) || [])[1];
    if (key && val != null) metas.push([key.toLowerCase(), decode(val)]);
  }
  const all = k => metas.filter(m => m[0] === k).map(m => m[1]).filter(Boolean);
  const one = (...ks) => { for (const k of ks) { const v = all(k)[0]; if (v) return v; } return ''; };

  let title = one('og:title', 'twitter:title');
  let brand = one('product:brand', 'og:brand');
  let price = one('product:price:amount', 'og:price:amount', 'price');
  let currency = one('product:price:currency', 'og:price:currency', 'pricecurrency');
  const images = [...all('og:image'), ...all('og:image:url'), ...all('twitter:image'), ...all('image')];

  // JSON-LD (schema.org Product)
  for (const m of html.matchAll(/<script[^>]+type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    let data; try { data = JSON.parse(m[1].trim()); } catch { continue; }
    const stack = [data];
    while (stack.length) {
      const n = stack.pop();
      if (Array.isArray(n)) { stack.push(...n); continue; }
      if (!n || typeof n !== 'object') continue;
      if (n['@graph']) stack.push(n['@graph']);
      const type = [].concat(n['@type'] || []).join(',');
      if (/Product/i.test(type)) {
        if (!title && n.name) title = String(n.name);
        if (!brand && n.brand) brand = typeof n.brand === 'string' ? n.brand : (n.brand.name || '');
        [].concat(n.image || []).forEach(i => images.push(typeof i === 'string' ? i : (i && (i.url || i.contentUrl)) || ''));
        for (const o of [].concat(n.offers || [])) {
          const offers = o && o.offers ? [].concat(o.offers) : [o];
          for (const x of offers) {
            if (!x) continue;
            if (!price) price = x.price ?? x.lowPrice ?? (x.priceSpecification && x.priceSpecification.price) ?? '';
            if (!currency) currency = x.priceCurrency || (x.priceSpecification && x.priceSpecification.priceCurrency) || '';
          }
        }
      }
    }
  }
  if (!title) title = decode((html.match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1] || '');
  title = title.replace(/\s+/g, ' ').trim();
  const p = parseFloat(String(price).replace(/\s/g, '').replace(',', '.'));
  const host = (() => { try { return new URL(pageUrl).hostname.replace(/^www\./, ''); } catch { return ''; } })();
  const abs = i => { try { return new URL(i, pageUrl).href; } catch { return ''; } };
  return {
    title: title.slice(0, 200),
    brand: String(brand || '').slice(0, 80),
    shop: host,
    price: isNaN(p) ? null : p,
    currency: (String(currency || 'EUR').toUpperCase().match(/^[A-Z]{3}$/) || ['EUR'])[0],
    images: [...new Set(images.map(abs).filter(Boolean))].slice(0, 12),
  };
}
