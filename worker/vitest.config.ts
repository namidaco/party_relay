import { defineWorkersConfig } from '@cloudflare/vitest-pool-workers/config';

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        singleWorker: true,
        // Rooms use random codes, and alarms fire outside the per test storage stack.
        isolatedStorage: false,
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          bindings: {
            MEMBERSHIP: 'off',
            JOIN_TIMEOUT_MS: '300',
            PENDING_TIMEOUT_MS: '400',
            HOST_GRACE_MS: '300',
            IDLE_TIMEOUT_MS: '1500',
            DIRECTORY_REFRESH_MS: '400',
            // the whole suite creates and lists from one ip, the limits and the cache are exercised with per call overrides
            CREATE_RATE_MAX: '0',
            LIST_RATE_MAX: '0',
            LIST_CACHE_MS: '0',
          },
        },
      },
    },
  },
});
