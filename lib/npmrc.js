// npm settings manager (pure module).
//
// Implements the "npm settings manager" component from the design document
// (§8) as PURE decision logic. It owns WHICH settings the ioBroker `.npmrc`
// must contain and WHERE that file lives, and it exposes:
//
//   - the required settings as constants (`REQUIRED_NPMRC_SETTINGS`),
//   - the canonical location of the file (`DEFAULT_NPMRC_PATH`),
//   - a renderer that produces the exact `.npmrc` content the runtime needs
//     (`renderNpmrc`),
//   - a parser for existing `.npmrc` content (`parseNpmrc`),
//   - a validity check that decides whether an adapter install may proceed or
//     MUST be blocked (`checkNpmrc`), and
//   - a convenience "ensure" planner (`ensureNpmrc`) that tells the shell glue
//     whether the file is already correct or must be (re)written, and whether
//     the install has to be blocked because the settings are corrupt or
//     inaccessible.
//
// The three settings ioBroker's installer relies on are `audit=false`,
// `update-notifier=false`, and `engine-strict=true` (Req 11.1, 11.2, 11.3).
// They must apply to adapter installs performed within the runtime (Req 11.4).
//
// Fail-closed contract (Req 11.5): if the settings file is corrupt (cannot be
// parsed into recognizable key=value settings, or contains conflicting values
// for a required key) or inaccessible (a read error is reported by the caller),
// the install MUST be blocked rather than proceeding with default npm behavior.
// This module never "repairs silently past" a corrupt file for the purposes of
// deciding whether to block: it signals `block: true` so the entrypoint can
// refuse. The shell glue keeps all filesystem side effects thin — it reads the
// file (or reports the read error), calls into this module, then writes the
// rendered content or aborts.
//
// Requirements: 11.1, 11.2, 11.3, 11.4, 11.5.

/**
 * Default location of the ioBroker `.npmrc` inside the runtime image. ioBroker
 * installs under `/opt/iobroker` (design §8, Data Models), and the npm settings
 * that apply to adapter installs live alongside the install so npm picks them
 * up as the project-level config.
 * @type {string}
 */
export const DEFAULT_NPMRC_PATH = '/opt/iobroker/.npmrc';

/**
 * The npm settings the `.npmrc` MUST contain for the Iobroker_Runtime, in the
 * canonical order they are rendered. Each entry is a `[key, value]` pair. The
 * values are the literal strings npm expects in an `.npmrc` file.
 *
 * - `audit=false`          (Req 11.1)
 * - `update-notifier=false`(Req 11.2)
 * - `engine-strict=true`   (Req 11.3)
 *
 * @type {ReadonlyArray<readonly [string, string]>}
 */
export const REQUIRED_NPMRC_SETTINGS = Object.freeze([
  Object.freeze(['audit', 'false']),
  Object.freeze(['update-notifier', 'false']),
  Object.freeze(['engine-strict', 'true']),
]);

/**
 * The required settings as a plain lookup object (`key -> value`). Convenience
 * view over {@link REQUIRED_NPMRC_SETTINGS} for callers that prefer a map.
 * @type {Readonly<Record<string, string>>}
 */
export const REQUIRED_NPMRC_MAP = Object.freeze(
  Object.fromEntries(REQUIRED_NPMRC_SETTINGS.map(([key, value]) => [key, value])),
);

/**
 * A parsed representation of an `.npmrc`'s contents.
 *
 * @typedef {Object} ParsedNpmrc
 * @property {Record<string, string>} settings - The recognized `key=value`
 *   settings, keyed by (lower-cased) key. When a key appears more than once
 *   with the SAME value it is collapsed to that value; when it appears with
 *   CONFLICTING values the key is recorded in {@link ParsedNpmrc.conflicts}
 *   and its `settings` entry holds the last value seen.
 * @property {string[]} conflicts - Keys that appeared multiple times with
 *   differing values. A conflict on a REQUIRED key is treated as corruption.
 * @property {boolean} malformed - True if any non-blank, non-comment line could
 *   not be parsed as a `key=value` setting (corrupt content).
 */

/**
 * Render the exact `.npmrc` content the Iobroker_Runtime requires.
 *
 * Produces one `key=value` line per {@link REQUIRED_NPMRC_SETTINGS} entry, in
 * canonical order, terminated by a trailing newline. This is the content the
 * shell glue writes to {@link DEFAULT_NPMRC_PATH} when the file is missing or
 * does not already satisfy the required settings.
 *
 * @returns {string} The canonical `.npmrc` file content.
 */
export function renderNpmrc() {
  return REQUIRED_NPMRC_SETTINGS.map(([key, value]) => `${key}=${value}`).join('\n') + '\n';
}

/**
 * Parse `.npmrc` file content into a {@link ParsedNpmrc}.
 *
 * Recognizes the simple `key=value` form npm uses (one setting per line),
 * ignoring blank lines and comments (lines whose first non-whitespace character
 * is `#` or `;`). Keys are lower-cased and trimmed; values are trimmed. Any
 * other non-blank line marks the content as `malformed`. A key repeated with
 * conflicting values is recorded in `conflicts`.
 *
 * This is a deliberately small parser: it does not implement npm's full config
 * syntax (env interpolation, quoting, arrays). It recognizes exactly enough to
 * decide whether the REQUIRED settings are present, correct, and unambiguous,
 * and to detect corruption otherwise.
 *
 * @param {string} content - The raw `.npmrc` file content.
 * @returns {ParsedNpmrc}
 */
export function parseNpmrc(content) {
  /** @type {Record<string, string>} */
  const settings = {};
  /** @type {Set<string>} */
  const conflicts = new Set();
  let malformed = false;

  const text = typeof content === 'string' ? content : '';

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();

    // Skip blank lines and comments.
    if (line === '' || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }

    const eq = line.indexOf('=');
    if (eq <= 0) {
      // No '=' at all, or a line starting with '=' (empty key): not a setting.
      malformed = true;
      continue;
    }

    const key = line.slice(0, eq).trim().toLowerCase();
    const value = line.slice(eq + 1).trim();

    if (key === '') {
      malformed = true;
      continue;
    }

    if (Object.prototype.hasOwnProperty.call(settings, key) && settings[key] !== value) {
      conflicts.add(key);
    }
    settings[key] = value;
  }

  return { settings, conflicts: [...conflicts], malformed };
}

/**
 * The result of checking whether an `.npmrc` satisfies the required settings
 * and whether an adapter install may proceed.
 *
 * @typedef {Object} NpmrcCheck
 * @property {boolean} valid - True iff the parsed content contains all required
 *   settings with the exact required values, with no conflicting duplicates on
 *   a required key. A `valid` file is fine as-is; extra unrelated settings are
 *   permitted and do not affect validity.
 * @property {boolean} block - True iff the adapter install MUST be blocked
 *   rather than falling back to default npm behavior (Req 11.5). This is set
 *   when the content is corrupt: it is malformed, or a required key has a
 *   conflicting duplicate. When the file is merely absent or missing some
 *   required settings (but is otherwise well-formed), `block` is false and the
 *   file can be (re)written to the required content.
 * @property {string[]} missing - Required keys that are absent (well-formed
 *   file that simply lacks a setting).
 * @property {Array<{ key: string, expected: string, actual: string }>} incorrect -
 *   Required keys present with the wrong value (well-formed disagreement that a
 *   rewrite will correct).
 * @property {string} reason - Short machine-friendly code summarizing the
 *   outcome: `'ok'`, `'inaccessible'`, `'corrupt'`, or `'needs-write'`.
 */

/**
 * Decide whether an existing (or absent) `.npmrc` satisfies the required
 * settings, and whether an adapter install may proceed.
 *
 * Input models what the thin shell glue can observe about the file:
 *   - `{ accessible: false }` — the file could not be read (a read error,
 *     permission problem, etc.). This is "inaccessible": the install MUST be
 *     blocked (Req 11.5).
 *   - `{ accessible: true, exists: false }` — the file is simply not present.
 *     Not corruption: the glue can create it, so `block` is false.
 *   - `{ accessible: true, exists: true, content }` — the file exists; its
 *     content is parsed and evaluated against the required settings.
 *
 * Corruption (`block: true`, Req 11.5) means the file exists and is
 * well-formed-enough-to-read-but-not-to-trust: it has unparseable lines
 * (`malformed`) or a REQUIRED key carries conflicting duplicate values. In that
 * case we refuse rather than silently overwriting and proceeding, because a
 * corrupt settings file signals the environment is not in a state we can rely
 * on for adapter installs.
 *
 * A well-formed file that is merely missing required keys or has an out-of-date
 * value is NOT corruption: it yields `valid: false, block: false` with `missing`
 * / `incorrect` populated, so the glue rewrites it to the canonical content.
 *
 * @param {{ accessible?: boolean, exists?: boolean, content?: string }} [input]
 *   Observations about the `.npmrc` file. Defaults to an inaccessible file.
 * @returns {NpmrcCheck}
 */
export function checkNpmrc(input = {}) {
  const { accessible, exists, content } = input;

  // Inaccessible: the caller could not read the file at all. Block (Req 11.5).
  if (accessible === false) {
    return {
      valid: false,
      block: true,
      missing: [],
      incorrect: [],
      reason: 'inaccessible',
    };
  }

  // Absent but accessible: not corruption. The glue can create the file.
  if (exists === false) {
    return {
      valid: false,
      block: false,
      missing: REQUIRED_NPMRC_SETTINGS.map(([key]) => key),
      incorrect: [],
      reason: 'needs-write',
    };
  }

  const parsed = parseNpmrc(typeof content === 'string' ? content : '');

  // A required key with conflicting duplicate values is corruption (Req 11.5).
  const requiredConflicts = parsed.conflicts.filter((key) =>
    Object.prototype.hasOwnProperty.call(REQUIRED_NPMRC_MAP, key),
  );

  if (parsed.malformed || requiredConflicts.length > 0) {
    return {
      valid: false,
      block: true,
      missing: [],
      incorrect: [],
      reason: 'corrupt',
    };
  }

  /** @type {string[]} */
  const missing = [];
  /** @type {Array<{ key: string, expected: string, actual: string }>} */
  const incorrect = [];

  for (const [key, expected] of REQUIRED_NPMRC_SETTINGS) {
    if (!Object.prototype.hasOwnProperty.call(parsed.settings, key)) {
      missing.push(key);
    } else if (parsed.settings[key] !== expected) {
      incorrect.push({ key, expected, actual: parsed.settings[key] });
    }
  }

  if (missing.length === 0 && incorrect.length === 0) {
    return { valid: true, block: false, missing: [], incorrect: [], reason: 'ok' };
  }

  return { valid: false, block: false, missing, incorrect, reason: 'needs-write' };
}

/**
 * A plan describing what the shell glue should do about the `.npmrc`.
 *
 * @typedef {Object} NpmrcPlan
 * @property {'ok'|'write'|'block'} action - What to do:
 *   - `'ok'`    — the file already satisfies the required settings; do nothing.
 *   - `'write'` — (re)write the file to {@link NpmrcPlan.content}; the file is
 *     absent or well-formed-but-outdated.
 *   - `'block'` — the settings are corrupt or inaccessible; block the adapter
 *     install and do NOT fall back to default npm behavior (Req 11.5).
 * @property {string} path - The `.npmrc` location the plan applies to.
 * @property {string} [content] - The canonical content to write; present only
 *   when `action` is `'write'`.
 * @property {NpmrcCheck} check - The underlying check result, for logging.
 */

/**
 * Produce an "ensure" plan for the `.npmrc`: given what the glue observed about
 * the file, decide whether it is already correct, should be (re)written to the
 * required content, or the install must be blocked.
 *
 * This is the primary entry point for the entrypoint's npm-settings step. The
 * glue stays thin: it stats/reads the file, hands the observations here, and
 * then acts on `action` (do nothing / write `content` / abort the install).
 *
 * @param {{ accessible?: boolean, exists?: boolean, content?: string }} [input]
 *   Observations about the `.npmrc` file (see {@link checkNpmrc}).
 * @param {string} [path] - The `.npmrc` location. Defaults to
 *   {@link DEFAULT_NPMRC_PATH}.
 * @returns {NpmrcPlan}
 */
export function ensureNpmrc(input = {}, path = DEFAULT_NPMRC_PATH) {
  const check = checkNpmrc(input);

  if (check.block) {
    return { action: 'block', path, check };
  }

  if (check.valid) {
    return { action: 'ok', path, check };
  }

  return { action: 'write', path, content: renderNpmrc(), check };
}
