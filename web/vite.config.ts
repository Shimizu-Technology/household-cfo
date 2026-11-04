import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const siteUrl = (env.VITE_SITE_URL || 'https://household-cfo.netlify.app').replace(/\/$/, '')

  const buildId = env.DEPLOY_ID || [env.COMMIT_REF || 'local', Date.now()].join('-')

  return {
    define: { __APP_BUILD_ID__: JSON.stringify(buildId) },
    plugins: [
      react(),
      {
        name: 'household-cfo-build-version',
        generateBundle() { this.emitFile({ type: 'asset', fileName: 'version.json', source: JSON.stringify({ version: buildId }) }) },
        configureServer(server) {
          server.middlewares.use('/version.json', (_request, response) => {
            response.setHeader('Content-Type', 'application/json')
            response.setHeader('Cache-Control', 'no-store')
            response.end(JSON.stringify({ version: buildId }))
          })
        },
      },
      {
        name: 'household-cfo-site-url-html-transform',
        transformIndexHtml: (html) => html.replaceAll('__SITE_URL__', siteUrl),
      },
    ],
    server: { proxy: { '/api/auth': { target: env.VITE_API_BASE_URL || 'http://localhost:3000', changeOrigin: true } } },
    build: {
      rolldownOptions: {
        output: {
          codeSplitting: {
            minSize: 20_000,
            groups: [
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
