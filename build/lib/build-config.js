// Maintainer-owned build configuration reader.
//
// This module centralizes WHERE the maintainer-owned build configuration lives
// and WHICH fields declare the build knobs. The build knobs — the Node.js major
// version and the Debian release codename — are OUR decisions as image
// maintainers, not ioBroker's. They live in the repository's `package.json`
// under the `containerImage` key, e.g.:
//
//     "containerImage": { "nodeMajor": 22, "debianCodename": "trixie" }
//
// This replaces the former ioBroker `versions.json` / `nodeJsRecommended`
// sourcing: `versions.json` is ioBroker's file and was misleading as the source
// of image-maintainer build knobs. Nothing reads it at container runtime; the
// build knobs are build-time inputs only.
//
// The actual validation/derivation of the integer Node major version (fail-fast
// when the field is missing, empty, whitespace, or non-integer) is implemented
// separately in `lib/node-major.js` and consumes the value read here.
//
// Requirements: 5.4 (read Node major from the Build_Config `nodeMajor`), 5.7
// (read the Debian codename from the Build_Config `debianCodename`).

import { readFileSync } from 'node:fs';

/**
 * The `package.json` key that holds the maintainer-owned build configuration.
 * @type {string}
 */
export const BUILD_CONFIG_KEY = 'containerImage';

/**
 * The Build_Config field that declares the Node.js major version to install.
 * @type {string}
 */
export const NODE_MAJOR_FIELD = 'nodeMajor';

/**
 * The Build_Config field that declares the Debian release codename used for
 * both the Build_Stage and Runtime_Image base images.
 * @type {string}
 */
export const DEBIAN_CODENAME_FIELD = 'debianCodename';

/**
 * Default location of the maintainer build config: the repository-root
 * `package.json`. For local builds and CI this is the natural source; there is
 * no in-image copy because nothing reads the build knobs at runtime.
 * @type {string}
 */
export const DEFAULT_BUILD_CONFIG_PATH = './package.json';

/**
 * Read and parse the `package.json` that carries the build config.
 *
 * @param {string} [path] - Path to the package.json. Defaults to `./package.json`.
 * @returns {Record<string, unknown>} The parsed JSON object.
 * @throws {Error} If the file cannot be read or does not contain valid JSON.
 */
export function readPackageJson(path = DEFAULT_BUILD_CONFIG_PATH) {
  const raw = readFileSync(path, 'utf8');
  return JSON.parse(raw);
}

/**
 * Extract the `containerImage` build-config object from a parsed package.json.
 *
 * @param {Record<string, unknown>} pkg - Parsed package.json object.
 * @returns {Record<string, unknown> | undefined} The build-config object, or
 *   undefined when the `containerImage` key is absent.
 */
export function readBuildConfig(pkg) {
  const cfg = pkg?.[BUILD_CONFIG_KEY];
  return cfg && typeof cfg === 'object' ? cfg : undefined;
}

/**
 * Extract the raw (unvalidated) `nodeMajor` value from a parsed package.json.
 * Validation/derivation into an integer major version is the responsibility of
 * `lib/node-major.js`.
 *
 * @param {Record<string, unknown>} pkg - Parsed package.json object.
 * @returns {unknown} The raw value of the `nodeMajor` field (may be undefined).
 */
export function readNodeMajor(pkg) {
  return readBuildConfig(pkg)?.[NODE_MAJOR_FIELD];
}

/**
 * Extract the raw (unvalidated) `debianCodename` value from a parsed
 * package.json.
 *
 * @param {Record<string, unknown>} pkg - Parsed package.json object.
 * @returns {unknown} The raw value of the `debianCodename` field (may be undefined).
 */
export function readDebianCodename(pkg) {
  return readBuildConfig(pkg)?.[DEBIAN_CODENAME_FIELD];
}
