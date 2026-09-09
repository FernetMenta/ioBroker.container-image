import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // Unit + property tests live under test/ (and may be co-located as *.test.js).
    include: ['test/**/*.test.js', 'lib/**/*.test.js'],
    environment: 'node',
    globals: true,
    // Property-based tests can take longer than the default 5s at numRuns: 100.
    testTimeout: 30000,
  },
});
