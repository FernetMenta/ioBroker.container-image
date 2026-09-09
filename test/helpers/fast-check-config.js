// Shared fast-check configuration for the rootless-iobroker-container-image feature.
//
// Every property-based test in this project MUST run at least 100 iterations,
// per the design Testing Strategy. Import PROPERTY_TEST_RUNS (or the pre-built
// assertParams object) instead of hard-coding numRuns in individual tests so the
// project-wide iteration count stays consistent and adjustable in one place.

/**
 * Minimum number of iterations every property test runs.
 * @type {number}
 */
export const PROPERTY_TEST_RUNS = 100;

/**
 * Parameters object to pass as the second argument of `fc.assert(...)`.
 * @type {{ numRuns: number }}
 */
export const assertParams = { numRuns: PROPERTY_TEST_RUNS };
