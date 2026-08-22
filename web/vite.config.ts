import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const siteUrl = (env.VITE_SITE_URL || 'https://household-cfo.netlify.app').replace(/\/$/, '')

  return {
    plugins: [
      react(),
      {
        name: 'household-cfo-site-url-html-transform',
        transformIndexHtml: (html) => html.replaceAll('__SITE_URL__', siteUrl),
      },
    ],
    build: {
      rolldownOptions: {
        output: {
          codeSplitting: {
            minSize: 20_000,
            groups: [
              { name: 'clerk', test: /node_modules[\\/]@clerk[\\/]/, priority: 30 },
              { name: 'analytics', test: /node_modules[\\/]posthog-js[\\/]/, priority: 30 },
              { name: 'plaid', test: /node_modules[\\/](?:react-plaid-link|plaid)[\\/]/, priority: 30 },
              { name: 'react', test: /node_modules[\\/](?:react|react-dom|scheduler)[\\/]/, priority: 20 },
              { name: 'vendor', test: /node_modules[\\/]/, priority: 10 },
            ],
          },
        },
      },
    },
  }
})
