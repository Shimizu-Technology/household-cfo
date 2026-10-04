import { defineConfig } from '@playwright/test'
import base from './playwright.config'
export default defineConfig({ ...base, testMatch: '**/privacy-controls.spec.ts', webServer: undefined, use: { ...base.use, baseURL: 'http://127.0.0.1:4399' } })
