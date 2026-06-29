import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

const publicDir = path.resolve(process.cwd(), 'public')
const rawSiteUrl = process.env.VITE_SITE_URL || process.env.URL || 'https://household-cfo.netlify.app'
const siteUrl = rawSiteUrl.replace(/\/$/, '')
const lastmod = process.env.SITEMAP_LASTMOD || new Date().toISOString().slice(0, 10)

const robotsTxt = `# Household CFO powered by VERA
# ${siteUrl}

User-agent: *
Allow: /
Disallow: /api/
Disallow: /admin
Disallow: /admin/
Disallow: /sign-in
Disallow: /sign-up

Sitemap: ${siteUrl}/sitemap.xml
`

const sitemapXml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>${siteUrl}/</loc>
    <lastmod>${lastmod}</lastmod>
    <changefreq>monthly</changefreq>
    <priority>1.0</priority>
  </url>
</urlset>
`

fs.mkdirSync(publicDir, { recursive: true })
fs.writeFileSync(path.join(publicDir, 'robots.txt'), robotsTxt, 'utf8')
fs.writeFileSync(path.join(publicDir, 'sitemap.xml'), sitemapXml, 'utf8')

console.info(`Generated SEO files for ${siteUrl}`)
