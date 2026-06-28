import { useEffect } from 'react'
import {
  DEFAULT_KEYWORDS,
  SITE_NAME,
  THEME_COLOR,
  canonicalUrl,
  getSectionSeo,
  socialImageUrl,
  webApplicationStructuredData,
} from '../lib/seo'

function upsertMeta(selector: string, attributes: Record<string, string>) {
  let element = document.head.querySelector<HTMLMetaElement>(selector)

  if (!element) {
    element = document.createElement('meta')
    document.head.appendChild(element)
  }

  Object.entries(attributes).forEach(([key, value]) => element.setAttribute(key, value))
}

function upsertLink(selector: string, attributes: Record<string, string>) {
  let element = document.head.querySelector<HTMLLinkElement>(selector)

  if (!element) {
    element = document.createElement('link')
    document.head.appendChild(element)
  }

  Object.entries(attributes).forEach(([key, value]) => element.setAttribute(key, value))
}

function upsertStructuredData(id: string, payload: Record<string, unknown>) {
  let element = document.head.querySelector<HTMLScriptElement>(`script#${id}`)

  if (!element) {
    element = document.createElement('script')
    element.id = id
    element.type = 'application/ld+json'
    document.head.appendChild(element)
  }

  element.textContent = JSON.stringify(payload)
}

export function SeoManager({ section }: { section: string }) {
  useEffect(() => {
    const route = getSectionSeo(section)
    const canonical = canonicalUrl()
    const image = socialImageUrl()
    const robots = route.robots || 'index,follow'

    document.title = route.title

    upsertMeta('meta[name="title"]', { name: 'title', content: route.title })
    upsertMeta('meta[name="description"]', { name: 'description', content: route.description })
    upsertMeta('meta[name="keywords"]', { name: 'keywords', content: DEFAULT_KEYWORDS })
    upsertMeta('meta[name="author"]', { name: 'author', content: SITE_NAME })
    upsertMeta('meta[name="robots"]', { name: 'robots', content: robots })
    upsertMeta('meta[name="theme-color"]', { name: 'theme-color', content: THEME_COLOR })

    upsertLink('link[rel="canonical"]', { rel: 'canonical', href: canonical })

    upsertMeta('meta[property="og:type"]', { property: 'og:type', content: 'website' })
    upsertMeta('meta[property="og:url"]', { property: 'og:url', content: canonical })
    upsertMeta('meta[property="og:title"]', { property: 'og:title', content: route.title })
    upsertMeta('meta[property="og:description"]', { property: 'og:description', content: route.description })
    upsertMeta('meta[property="og:image"]', { property: 'og:image', content: image })
    upsertMeta('meta[property="og:image:width"]', { property: 'og:image:width', content: '1200' })
    upsertMeta('meta[property="og:image:height"]', { property: 'og:image:height', content: '630' })
    upsertMeta('meta[property="og:site_name"]', { property: 'og:site_name', content: SITE_NAME })

    upsertMeta('meta[name="twitter:card"]', { name: 'twitter:card', content: 'summary_large_image' })
    upsertMeta('meta[name="twitter:url"]', { name: 'twitter:url', content: canonical })
    upsertMeta('meta[name="twitter:title"]', { name: 'twitter:title', content: route.title })
    upsertMeta('meta[name="twitter:description"]', { name: 'twitter:description', content: route.description })
    upsertMeta('meta[name="twitter:image"]', { name: 'twitter:image', content: image })

    upsertStructuredData('household-cfo-web-application-schema', webApplicationStructuredData())
  }, [section])

  return null
}
