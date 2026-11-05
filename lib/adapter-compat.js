// lib/adapter-compat.js
//
// Admin / js-controller compatibility resolver (PURE module + thin CLI).
//
// WHY: on a FRESH container the reconciler seeds `admin` into the desired set
// and installs the newest STABLE admin from the active repo. The js-controller
// is baked into the image at a FIXED version (e.g. 7.2.2). A newer stable admin
// can require a newer controller than the image ships (e.g. admin 8.3.5 needs
// js-controller >=7.2.5), so the unpinned install lands an admin that is
// INCOMPATIBLE with the running controller. This module decides, from the
// installed controller version and a set of candidate admin versions annotated
// with their js-controller requirement, the NEWEST admin version that the
// installed controller SATISFIES — or null when none is compatible.
//
// The caller (scripts/reconcile.sh glue) probes admin versions newest->oldest,
// fetching each version's io-package.json `common.dependencies` (preferably the
// GitHub raw io-package.json by tag) to learn its js-controller requirement,
// and asks this module whether the installed controller satisfies it. Because
// the glue stops at the first compatible version, this module also exposes the
// per-version predicate (`isCompatible`) it uses, so the shell can short-circuit
// its probing without gathering every candidate.
//
// SCOPE: this is applied ONLY to the fresh-install `admin` bootstrap path. It is
// deliberately generic over "adapter + js-controller requirement" (nothing here
// is admin-specific) but the project wires it only for admin.
//
// SEMVER: the project does NOT depend on `semver`. Rather than add a runtime
// dependency, this module ships a small, self-contained semver subset that
// covers exactly what adapter js-controller requirements use in practice:
// comparator ranges (`>=`, `>`, `<=`, `<`, `=`), `x`/`*` wildcards, caret
// (`^`) and tilde (`~`) ranges, hyphen ranges (`A - B`), and `||` unions. It is
// NOT a full semver implementation; anything it cannot parse is reported as
// "cannot determine", which the caller treats as a reason to SKIP that version
// (documented below), never as a silent "compatible".

import { pathToFileURL } from 'node:url';

/**
 * Outcome codes for a single-version compatibility decision.
 *
 * - `compatible`   — the installed controller satisfies the version's
 *   js-controller requirement (including the "no requirement" case, which is
 *   always compatible).
 * - `incompatible` — the requirement is well-formed but the installed
 *   controller does NOT satisfy it.
 * - `unknown`      — the requirement (or the installed controller version)
 *   could not be parsed/understood. The caller MUST treat this as a reason to
 *   SKIP the version, never as compatible: installing against an unparseable
 *   requirement is exactly the mismatch this feature exists to prevent.
 *
 * @readonly
 * @enum {string}
 */
export const COMPAT_RESULTS = Object.freeze({
  COMPATIBLE: 'compatible',
  INCOMPATIBLE: 'incompatible',
  UNKNOWN: 'unknown',
});

/**
 * A candidate adapter version annotated with its js-controller requirement.
 *
 * @typedef {Object} CandidateVersion
 * @property {string} version - The adapter version (a semver release string,
 *   e.g. `"8.3.5"`). Prerelease versions (containing `-`) are skipped by
 *   {@link resolveCompatibleVersion} when resolving.
 * @property {string|null|undefined} controllerRange - The js-controller
 *   semver RANGE this version requires (from io-package.json
 *   `common.dependencies` / `common.globalDependencies`), e.g. `">=7.2.5"`. An
 *   empty/absent value means the version declares NO js-controller requirement
 *   and is therefore always compatible.
 */

/**
 * Parse a dot-separated numeric version core into a `[major, minor, patch]`
 * triple of numbers. Missing components default to 0. Extra components are
 * ignored. Returns null if the first component is not a non-negative integer.
 *
 * @param {string} core - The version core (no prerelease/build), e.g. `"7.2"`.
 * @returns {[number, number, number] | null}
 */
function parseCore(core) {
  const parts = core.split('.');
  /** @type {number[]} */
  const nums = [];
  for (let i = 0; i < 3; i++) {
    const raw = parts[i];
    if (raw === undefined || raw === '') {
      nums.push(0);
      continue;
    }
    if (!/^\d+$/.test(raw)) {
      return null;
    }
    nums.push(Number(raw));
  }
  return /** @type {[number, number, number]} */ (nums);
}

/**
 * A parsed semver version: numeric release triple plus an optional ordered
 * prerelease identifier list (empty for a stable release).
 *
 * @typedef {Object} ParsedVersion
 * @property {number} major
 * @property {number} minor
 * @property {number} patch
 * @property {Array<string|number>} prerelease - Dot-separated prerelease ids.
 *   Numeric ids are stored as numbers (for numeric comparison per semver).
 * @property {string} raw - The input string, trimmed and `v`-stripped.
 */

/**
 * Parse a semver version string into a {@link ParsedVersion}. Tolerant of a
 * leading `v`. Build metadata (`+...`) is ignored. Returns null when the core
 * is not a valid numeric version.
 *
 * @param {string} input
 * @returns {ParsedVersion | null}
 */
export function parseVersion(input) {
  if (typeof input !== 'string') {
    return null;
  }
  let s = input.trim();
  if (s === '') {
    return null;
  }
  if (s[0] === 'v' || s[0] === 'V') {
    s = s.slice(1);
  }
  // Strip build metadata.
  const plus = s.indexOf('+');
  if (plus >= 0) {
    s = s.slice(0, plus);
  }
  // Split off prerelease.
  let pre = '';
  const dash = s.indexOf('-');
  let core = s;
  if (dash >= 0) {
    core = s.slice(0, dash);
    pre = s.slice(dash + 1);
  }
  const triple = parseCore(core);
  if (triple === null) {
    return null;
  }
  const prerelease =
    pre === '' ? [] : pre.split('.').map((id) => (/^\d+$/.test(id) ? Number(id) : id));
  return { major: triple[0], minor: triple[1], patch: triple[2], prerelease, raw: s };
}

/**
 * Compare two prerelease identifier lists per the semver precedence rules.
 * A version with no prerelease ranks HIGHER than one with a prerelease.
 *
 * @param {Array<string|number>} a
 * @param {Array<string|number>} b
 * @returns {number} -1, 0, or 1
 */
function comparePrerelease(a, b) {
  if (a.length === 0 && b.length === 0) return 0;
  if (a.length === 0) return 1; // no prerelease > has prerelease
  if (b.length === 0) return -1;
  const len = Math.min(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const x = a[i];
    const y = b[i];
    const xNum = typeof x === 'number';
    const yNum = typeof y === 'number';
    if (xNum && yNum) {
      if (x !== y) return x < y ? -1 : 1;
    } else if (xNum !== yNum) {
      // Numeric identifiers always have lower precedence than non-numeric.
      return xNum ? -1 : 1;
    } else {
      if (x !== y) return String(x) < String(y) ? -1 : 1;
    }
  }
  if (a.length !== b.length) return a.length < b.length ? -1 : 1;
  return 0;
}

/**
 * Compare two parsed versions by semver precedence.
 *
 * @param {ParsedVersion} a
 * @param {ParsedVersion} b
 * @returns {number} -1 if a<b, 0 if equal, 1 if a>b.
 */
export function compareVersions(a, b) {
  if (a.major !== b.major) return a.major < b.major ? -1 : 1;
  if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
  if (a.patch !== b.patch) return a.patch < b.patch ? -1 : 1;
  return comparePrerelease(a.prerelease, b.prerelease);
}

/**
 * A single parsed comparator: an operator plus the version it compares against.
 *
 * @typedef {Object} Comparator
 * @property {'<'|'<='|'>'|'>='|'='} op
 * @property {ParsedVersion} version
 */

/**
 * Parse a single comparator token (e.g. `">=7.2.5"`, `"7.2.5"`, `"<8.0.0"`).
 * Returns null if it cannot be parsed.
 *
 * @param {string} token
 * @returns {Comparator | null}
 */
function parseComparator(token) {
  const m = token.match(/^(>=|<=|>|<|=)?\s*(.+)$/);
  if (!m) return null;
  const op = /** @type {Comparator['op']} */ (m[1] || '=');
  const version = parseVersion(m[2]);
  if (version === null) return null;
  return { op, version };
}

/**
 * Does a version satisfy a single comparator?
 *
 * @param {ParsedVersion} v
 * @param {Comparator} cmp
 * @returns {boolean}
 */
function satisfiesComparator(v, cmp) {
  const c = compareVersions(v, cmp.version);
  switch (cmp.op) {
    case '<':
      return c < 0;
    case '<=':
      return c <= 0;
    case '>':
      return c > 0;
    case '>=':
      return c >= 0;
    case '=':
      return c === 0;
    default:
      return false;
  }
}

/**
 * Expand an advanced range primitive (wildcard / caret / tilde / bare partial /
 * hyphen) into a list of plain comparators. Returns null if the primitive
 * cannot be understood.
 *
 * Supported:
 *   - `*` / `x` / `""`     -> no constraint (matches anything, but see below)
 *   - `1` / `1.2`          -> partial version: `>=1.0.0 <2.0.0` / `>=1.2.0 <1.3.0`
 *   - `1.x` / `1.2.x`      -> same as partial
 *   - `^1.2.3`             -> `>=1.2.3 <2.0.0` (or `<0.3.0` / `<0.2.4` for 0.x)
 *   - `~1.2.3`             -> `>=1.2.3 <1.3.0`
 *   - `>=1.2.3` etc.       -> single comparator (handled by parseComparator)
 *
 * @param {string} primitive
 * @returns {Comparator[] | null}
 */
function expandPrimitive(primitive) {
  const token = primitive.trim();
  if (token === '') {
    return []; // empty -> no constraint
  }

  // Plain comparator (operator-prefixed) with a FULL numeric version: let
  // parseComparator handle it. Wildcards after an operator are not standard;
  // fall through to the wildcard handling for the bare forms.
  if (/^(>=|<=|>|<|=)/.test(token)) {
    const cmp = parseComparator(token);
    return cmp ? [cmp] : null;
  }

  // Caret range.
  if (token[0] === '^') {
    const v = parseVersion(token.slice(1));
    if (!v) return null;
    const lower = { op: /** @type {const} */ ('>='), version: v };
    let upper;
    if (v.major > 0) {
      upper = mkVersion(v.major + 1, 0, 0);
    } else if (v.minor > 0) {
      upper = mkVersion(0, v.minor + 1, 0);
    } else {
      upper = mkVersion(0, 0, v.patch + 1);
    }
    return [lower, { op: '<', version: upper }];
  }

  // Tilde range.
  if (token[0] === '~') {
    const v = parseVersion(token.slice(1));
    if (!v) return null;
    const lower = { op: /** @type {const} */ ('>='), version: v };
    const upper = mkVersion(v.major, v.minor + 1, 0);
    return [lower, { op: '<', version: upper }];
  }

  // Wildcard / bare partial version: `*`, `x`, `1`, `1.x`, `1.2`, `1.2.x`.
  const parts = token.split('.');
  // Leading wildcard: matches anything.
  if (parts[0] === '*' || parts[0] === 'x' || parts[0] === 'X') {
    return [];
  }
  const major = parts[0];
  if (!/^\d+$/.test(major)) {
    return null;
  }
  const minorRaw = parts[1];
  const minorWild =
    minorRaw === undefined || minorRaw === 'x' || minorRaw === 'X' || minorRaw === '*';
  const patchRaw = parts[2];
  const patchWild =
    patchRaw === undefined || patchRaw === 'x' || patchRaw === 'X' || patchRaw === '*';

  const maj = Number(major);
  if (minorWild) {
    return [
      { op: '>=', version: mkVersion(maj, 0, 0) },
      { op: '<', version: mkVersion(maj + 1, 0, 0) },
    ];
  }
  if (!/^\d+$/.test(minorRaw)) return null;
  const min = Number(minorRaw);
  if (patchWild) {
    return [
      { op: '>=', version: mkVersion(maj, min, 0) },
      { op: '<', version: mkVersion(maj, min + 1, 0) },
    ];
  }
  if (!/^\d+$/.test(patchRaw)) return null;
  // Fully specified bare version -> exact match.
  return [{ op: '=', version: mkVersion(maj, min, Number(patchRaw)) }];
}

/**
 * Build a ParsedVersion from numeric components (no prerelease).
 * @param {number} major
 * @param {number} minor
 * @param {number} patch
 * @returns {ParsedVersion}
 */
function mkVersion(major, minor, patch) {
  return { major, minor, patch, prerelease: [], raw: `${major}.${minor}.${patch}` };
}

/**
 * Parse one range "set" (a space-separated conjunction of primitives, possibly
 * including a hyphen range `A - B`) into comparators. Returns null if any part
 * cannot be understood.
 *
 * @param {string} set
 * @returns {Comparator[] | null}
 */
function parseRangeSet(set) {
  const trimmed = set.trim();
  if (trimmed === '') {
    return []; // empty set matches anything
  }

  // Hyphen range: "A - B" (spaces around the hyphen are required by semver).
  const hyphen = trimmed.split(/\s+-\s+/);
  if (hyphen.length === 2) {
    const lo = parseVersion(hyphen[0]);
    const hi = parseVersion(hyphen[1]);
    if (!lo || !hi) return null;
    return [
      { op: '>=', version: lo },
      { op: '<=', version: hi },
    ];
  }

  const tokens = trimmed.split(/\s+/).filter(Boolean);
  /** @type {Comparator[]} */
  const comparators = [];
  for (const tok of tokens) {
    const expanded = expandPrimitive(tok);
    if (expanded === null) {
      return null;
    }
    comparators.push(...expanded);
  }
  return comparators;
}

/**
 * Decide whether an installed controller version satisfies an adapter's
 * js-controller requirement RANGE.
 *
 * Handled cases (per the task's enumerated requirements):
 *   - An empty/absent range -> COMPATIBLE (the version declares no requirement).
 *   - A controller version that is itself a prerelease -> parsed and compared
 *     by semver precedence (satisfiesComparator uses full semver ordering).
 *   - Multiple comparators in a set -> all must hold (conjunction).
 *   - `||` unions -> any set may hold (disjunction).
 *   - A malformed / unparseable range (or an unparseable controller version)
 *     -> UNKNOWN, so the caller SKIPS the version rather than risking an
 *     incompatible install.
 *
 * @param {string} controllerVersion - The installed js-controller version.
 * @param {string|null|undefined} range - The required js-controller range.
 * @returns {COMPAT_RESULTS[keyof COMPAT_RESULTS]}
 */
export function isCompatible(controllerVersion, range) {
  const installed = parseVersion(controllerVersion);
  if (installed === null) {
    // We cannot reason about an unparseable controller version. Fail closed.
    return COMPAT_RESULTS.UNKNOWN;
  }

  // No requirement declared -> always compatible.
  if (range === null || range === undefined || String(range).trim() === '') {
    return COMPAT_RESULTS.COMPATIBLE;
  }

  const sets = String(range).split('||');
  let sawParseError = false;
  let anySatisfied = false;

  for (const rawSet of sets) {
    const comparators = parseRangeSet(rawSet);
    if (comparators === null) {
      sawParseError = true;
      continue;
    }
    // A fully-wildcard set yields zero comparators: matches anything.
    const satisfied = comparators.every((cmp) => satisfiesComparator(installed, cmp));
    if (satisfied) {
      anySatisfied = true;
      break;
    }
  }

  if (anySatisfied) {
    return COMPAT_RESULTS.COMPATIBLE;
  }
  // No set matched. If we could not even parse part of the range, report
  // UNKNOWN (skip) rather than a definitive incompatible, because an
  // unparseable alternative might actually have matched.
  return sawParseError ? COMPAT_RESULTS.UNKNOWN : COMPAT_RESULTS.INCOMPATIBLE;
}

/**
 * Normalize/collect a js-controller requirement RANGE out of the
 * io-package.json `common.dependencies` (and optionally
 * `common.globalDependencies`) shape.
 *
 * ioBroker records dependencies as an ARRAY whose entries are either a bare
 * string adapter name (no version constraint) or an object mapping a dependency
 * name to a range, e.g. `[{ "js-controller": ">=7.2.5" }, "backitup"]`. We scan
 * for the `js-controller` key across all entries of the provided arrays and
 * return the first range we find, or null when none constrains js-controller.
 *
 * Extremely defensive: anything that is not the expected shape is ignored (a
 * missing/short-circuited field simply yields null -> "no requirement").
 *
 * @param {unknown} dependencies - `common.dependencies` (any shape).
 * @param {unknown} [globalDependencies] - `common.globalDependencies`.
 * @returns {string | null} The js-controller range, or null if unconstrained.
 */
export function extractControllerRange(dependencies, globalDependencies) {
  const scan = (deps) => {
    if (!Array.isArray(deps)) return null;
    for (const entry of deps) {
      if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
        const val = /** @type {Record<string, unknown>} */ (entry)['js-controller'];
        if (typeof val === 'string' && val.trim() !== '') {
          return val.trim();
        }
      }
      // A bare string entry (e.g. "js-controller") carries no range -> no
      // constraint; keep scanning in case a later entry has an object form.
    }
    return null;
  };
  return scan(dependencies) ?? scan(globalDependencies) ?? null;
}

/**
 * The result of resolving the newest compatible version.
 *
 * @typedef {Object} ResolveResult
 * @property {string | null} version - The newest compatible version, or null
 *   when none of the candidates is compatible.
 * @property {Array<{ version: string, result: string, range: string|null }>} evaluated -
 *   Per-candidate decisions, in the (descending) order they were evaluated,
 *   up to and including the first compatible one. Useful for logging WHY a
 *   version was chosen or why nothing matched.
 */

/**
 * Resolve the NEWEST candidate version compatible with the installed
 * js-controller.
 *
 * Candidates are sorted by semver descending, prerelease candidates are
 * skipped (the fresh-install bootstrap resolves to a stable release), and each
 * remaining candidate is tested newest-first. The FIRST candidate the installed
 * controller satisfies wins; `UNKNOWN` (unparseable requirement) candidates are
 * skipped and recorded. Evaluation stops at the first compatible version, so
 * the `evaluated` trail is bounded to the versions actually inspected.
 *
 * This mirrors the shell glue's newest->oldest probe but as a PURE function
 * over already-annotated candidates, so it is fully property-testable.
 *
 * @param {string} controllerVersion - The installed js-controller version.
 * @param {CandidateVersion[]} candidates - Candidate admin versions annotated
 *   with their js-controller requirement range.
 * @returns {ResolveResult}
 */
export function resolveCompatibleVersion(controllerVersion, candidates) {
  /** @type {ResolveResult['evaluated']} */
  const evaluated = [];

  if (!Array.isArray(candidates)) {
    return { version: null, evaluated };
  }

  // Parse + sort descending; drop entries whose version is unparseable or a
  // prerelease (we only bootstrap stable releases).
  const parsed = candidates
    .map((c) => ({ raw: c, parsed: parseVersion(c && c.version) }))
    .filter((e) => e.parsed !== null && e.parsed.prerelease.length === 0)
    .sort((a, b) => compareVersions(b.parsed, a.parsed));

  for (const entry of parsed) {
    const range = entry.raw.controllerRange ?? null;
    const result = isCompatible(controllerVersion, range);
    evaluated.push({
      version: entry.parsed.raw,
      result,
      range: range === null || range === undefined ? null : String(range),
    });
    if (result === COMPAT_RESULTS.COMPATIBLE) {
      return { version: entry.parsed.raw, evaluated };
    }
  }

  return { version: null, evaluated };
}

// -- CLI ----------------------------------------------------------------------
//
// Thin command surface for scripts/reconcile.sh. Each subcommand is a pure
// mapping over its inputs (no network, no filesystem writes), so the shell glue
// stays responsible for the side effects (reading the controller version,
// fetching io-package.json, running the install).
//
// Subcommands:
//
//   sort <versions-json>
//       <versions-json> is the `npm view iobroker.admin versions --json`
//       output (a JSON array of version strings). Prints the STABLE (non
//       -prerelease) versions, parseable as semver, one per line, NEWEST FIRST.
//       The shell probes this list in order and stops at the first compatible
//       version, so the ordering defines the probe order and bounds the work.
//
//   extract   (reads io-package.json JSON on stdin)
//       Prints the js-controller requirement RANGE extracted from
//       `common.dependencies` / `common.globalDependencies`, or nothing when
//       the version declares no js-controller constraint.
//
//   check <controllerVersion> <range>
//       Prints `compatible` / `incompatible` / `unknown` for the installed
//       controller against the given range (empty range -> `compatible`). The
//       shell treats anything other than `compatible` as "skip this version".
//
// Exit status is 0 for a successful mapping; 2 for a usage/parse error. The
// decision itself is conveyed on stdout, never via a non-zero exit, so the
// shell's `set -e` is not tripped by an ordinary "incompatible"/"unknown".

function readStdin() {
  return new Promise((resolve) => {
    let s = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (d) => (s += d));
    process.stdin.on('end', () => resolve(s));
    process.stdin.on('error', () => resolve(s));
  });
}

async function main(argv) {
  const sub = argv[0];
  switch (sub) {
    case 'sort': {
      let versions;
      try {
        versions = JSON.parse(argv[1] ?? '');
      } catch {
        process.stderr.write('adapter-compat: sort: invalid versions JSON\n');
        process.exit(2);
        return;
      }
      if (!Array.isArray(versions)) {
        process.exit(2);
        return;
      }
      const parsed = versions
        .map((v) => parseVersion(v))
        .filter((p) => p !== null && p.prerelease.length === 0)
        .sort((a, b) => compareVersions(b, a));
      for (const p of parsed) {
        process.stdout.write(`${p.raw}\n`);
      }
      return;
    }
    case 'extract': {
      const text = await readStdin();
      let obj;
      try {
        obj = JSON.parse(text);
      } catch {
        // Unreadable io-package.json: emit nothing. The shell treats an empty
        // range as "no declared requirement", but it only calls `extract` after
        // a SUCCESSFUL fetch, so an empty here means a genuinely dependency-free
        // version. A fetch failure is handled by the shell before this point.
        return;
      }
      const common = obj && obj.common ? obj.common : {};
      const range = extractControllerRange(common.dependencies, common.globalDependencies);
      if (range) {
        process.stdout.write(range);
      }
      return;
    }
    case 'check': {
      const controllerVersion = argv[1] ?? '';
      const range = argv[2] ?? '';
      process.stdout.write(isCompatible(controllerVersion, range));
      return;
    }
    default:
      process.stderr.write('usage: adapter-compat.js <sort|extract|check> ...\n');
      process.exit(2);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
