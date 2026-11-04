// lib/native-preflight.js
//
// Native-module PREFLIGHT for startup reconciliation.
//
// WHY: the runtime image is toolchain-free. After a Node-major upgrade the
// image can repair only the native modules it ships itself (seed overlay). An
// adapter's OWN native dependency (serialport, sqlite3, ...) keeps its old-ABI
// binary and the adapter crashes when it loads it. This module detects that
// state up front, attributes every unloadable native package to the adapter(s)
// that depend on it, and classifies each one against
// IOB_ADAPTER_INSTALL_FAILURE_POLICY so the reconciler can warn (every start,
// until fixed) or block, exactly like a failed adapter install.
//
// Two layers:
//   * classifyBroken()          pure policy decision (property-testable)
//   * scanBrokenNativeModules() filesystem + dlopen probe
//
// CLI (used by scripts/reconcile.sh):
//   node native-preflight.js <node_modules dir>
//   env: IOB_P_POLICY, IOB_P_ENABLED (newline list), IOB_P_ENABLED_OK (true|false),
//        IOB_P_SKIP (newline list of packages the reconciler will repair itself)
//   stdout: one line per broken package:
//     <fatal|tolerated>\t<package>\t<owners, comma separated>\t<error>

import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

export const PREFLIGHT_POLICIES = Object.freeze(['strict', 'tolerate-no-instance', 'tolerate-all']);

/** Owner name used for js-controller's own natives; always considered enabled. */
export const CORE_OWNER = 'js-controller';

// Path tokens that mark a prebuilt binary as belonging to ANOTHER platform/arch.
// Such files are not candidates (they can never load here, and that is fine).
const FOREIGN_TOKENS = new Set([
  'darwin',
  'win32',
  'windows',
  'win',
  'mac',
  'macos',
  'freebsd',
  'openbsd',
  'android',
  'sunos',
  'aix',
  'musl',
  'musllinux',
  'alpine',
  'x64',
  'arm64',
  'arm',
  'armv7',
  'ia32',
  'x86',
  'ppc64',
  'ppc64le',
  's390x',
  'riscv64',
  'mips',
  'mipsel',
]);

/**
 * Is this .node file a candidate for the running platform/arch?
 * @param {string} relPath path relative to node_modules
 * @param {string} arch process.arch
 */
export function isCandidateForHost(relPath, arch = process.arch) {
  const tokens = relPath
    .toLowerCase()
    .split(/[\\/._-]+/)
    .filter(Boolean);
  for (const t of tokens) {
    if (t === arch) continue;
    if (t === 'x64' && arch === 'x64') continue;
    if (FOREIGN_TOKENS.has(t)) return false;
  }
  return true;
}

/**
 * PURE. Decide, per broken package, whether the active policy treats it as fatal.
 *
 * @param {{pkg:string, owners:string[], error:string}[]} broken
 * @param {{policy:string, enabledAdapters:Iterable<string>, enabledQueryOk:boolean}} ctx
 * @returns {{fatal:object[], tolerated:object[]}}
 */
export function classifyBroken(broken, ctx) {
  const enabled = new Set(ctx.enabledAdapters ?? []);
  enabled.add(CORE_OWNER);
  const fatal = [];
  const tolerated = [];
  for (const b of broken) {
    let isFatal;
    switch (ctx.policy) {
      case 'strict':
        isFatal = true;
        break;
      case 'tolerate-all':
        isFatal = false;
        break;
      case 'tolerate-no-instance':
        // Unknown instance state fails safe (as for failed installs), but only
        // for packages some adapter actually depends on.
        isFatal =
          b.owners.length > 0 && (!ctx.enabledQueryOk || b.owners.some((o) => enabled.has(o)));
        break;
      default:
        isFatal = true; // unknown policy: fail safe
    }
    (isFatal ? fatal : tolerated).push(b);
  }
  return { fatal, tolerated };
}

function readJson(path, cache) {
  if (cache.has(path)) return cache.get(path);
  let v = null;
  try {
    v = JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    v = null;
  }
  cache.set(path, v);
  return v;
}

function walkNodeFiles(dir, out, depth = 0) {
  if (depth > 12) return;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      walkNodeFiles(p, out, depth + 1);
    } else if (e.isFile() && e.name.endsWith('.node')) {
      out.push(p);
    }
  }
}

function packageDirOf(file, nodeModulesDir) {
  let d = dirname(file);
  while (d.length > nodeModulesDir.length) {
    if (existsSync(join(d, 'package.json'))) return d;
    d = dirname(d);
  }
  return null;
}

/** Try to load one .node binary in a throwaway process. Returns null or an error string. */
function probeDlopen(file, timeoutMs) {
  const r = spawnSync(
    process.execPath,
    ['-e', 'process.dlopen({ exports: {} }, process.argv[1])', file],
    { encoding: 'utf8', timeout: timeoutMs },
  );
  if (r.error) return `probe failed: ${r.error.message}`;
  if (r.status === 0) return null;
  const text = `${r.stderr || ''}`
    .split('\n')
    .find((l) => /Error|error|NODE_MODULE_VERSION|cannot open/.test(l));
  return (text || `exit ${r.status}${r.signal ? ` (${r.signal})` : ''}`).trim().slice(0, 300);
}

/**
 * Map broken package dirs to the adapters (and js-controller) depending on them,
 * by walking each adapter's dependency closure using node's resolution order.
 */
function attributeOwners(brokenDirs, nodeModulesDir) {
  const cache = new Map();
  const result = new Map(brokenDirs.map((d) => [d, new Set()]));
  const wanted = new Set(brokenDirs);
  const stop = dirname(nodeModulesDir);

  const roots = [];
  try {
    for (const name of readdirSync(nodeModulesDir)) {
      if (!name.startsWith('iobroker.')) continue;
      const dir = join(nodeModulesDir, name);
      try {
        if (statSync(dir).isDirectory()) roots.push({ owner: name.slice('iobroker.'.length), dir });
      } catch {
        /* ignore */
      }
    }
  } catch {
    return result;
  }

  const resolveDep = (fromDir, dep) => {
    let d = fromDir;
    for (;;) {
      const base = basename(d) === 'node_modules' ? d : join(d, 'node_modules');
      const cand = join(base, dep);
      if (existsSync(join(cand, 'package.json'))) return cand;
      if (d === stop || d === dirname(d)) return null;
      d = dirname(d);
    }
  };

  for (const { owner, dir } of roots) {
    const seen = new Set([dir]);
    const queue = [dir];
    while (queue.length) {
      const cur = queue.pop();
      if (wanted.has(cur)) result.get(cur).add(owner === 'js-controller' ? CORE_OWNER : owner);
      const pj = readJson(join(cur, 'package.json'), cache);
      if (!pj) continue;
      const deps = { ...(pj.optionalDependencies || {}), ...(pj.dependencies || {}) };
      for (const dep of Object.keys(deps)) {
        const res = resolveDep(cur, dep);
        if (res && !seen.has(res)) {
          seen.add(res);
          queue.push(res);
        }
      }
    }
  }
  return result;
}

/**
 * Find native packages under nodeModulesDir none of whose host-compatible .node
 * binaries can be loaded by the running Node.
 *
 * @returns {{pkg:string, owners:string[], error:string}[]}
 */
export function scanBrokenNativeModules(nodeModulesDir, { timeoutMs = 10000, skip = [] } = {}) {
  const skipSet = new Set(skip);
  const files = [];
  walkNodeFiles(nodeModulesDir, files);

  /** @type {Map<string, string[]>} package dir -> candidate .node files */
  const byPkg = new Map();
  for (const f of files) {
    if (!isCandidateForHost(relative(nodeModulesDir, f))) continue;
    const pdir = packageDirOf(f, nodeModulesDir);
    if (!pdir) continue;
    if (!byPkg.has(pdir)) byPkg.set(pdir, []);
    byPkg.get(pdir).push(f);
  }

  const brokenDirs = [];
  const errors = new Map();
  for (const [pdir, cands] of byPkg) {
    let lastErr = null;
    let ok = false;
    for (const f of cands) {
      const err = probeDlopen(f, timeoutMs);
      if (err === null) {
        ok = true;
        break;
      }
      lastErr = err;
    }
    if (!ok && !skipSet.has(relative(nodeModulesDir, pdir).split(sep).join('/'))) {
      brokenDirs.push(pdir);
      errors.set(pdir, lastErr);
    }
  }
  if (brokenDirs.length === 0) return [];

  const owners = attributeOwners(brokenDirs, nodeModulesDir);
  return brokenDirs
    .map((d) => ({
      pkg: relative(nodeModulesDir, d).split(sep).join('/'),
      owners: [...owners.get(d)].sort(),
      error: errors.get(d) ?? 'unknown error',
    }))
    .sort((a, b) => a.pkg.localeCompare(b.pkg));
}

// -- CLI ----------------------------------------------------------------------

function main() {
  const nodeModulesDir = process.argv[2];
  if (!nodeModulesDir) {
    process.stderr.write('usage: native-preflight.js <node_modules dir>\n');
    process.exit(2);
  }
  const policy = process.env.IOB_P_POLICY || 'tolerate-no-instance';
  const enabledAdapters = (process.env.IOB_P_ENABLED || '')
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean);
  const enabledQueryOk = process.env.IOB_P_ENABLED_OK === 'true';

  const skip = (process.env.IOB_P_SKIP || '')
    .split('\n')
    .map((x) => x.trim())
    .filter(Boolean);
  const broken = scanBrokenNativeModules(nodeModulesDir, { skip });
  const { fatal, tolerated } = classifyBroken(broken, { policy, enabledAdapters, enabledQueryOk });
  const line = (kind, b) =>
    `${kind}\t${b.pkg}\t${b.owners.join(',') || '(unattributed)'}\t${b.error.replace(/[\t\r\n]+/g, ' ')}\n`;
  for (const b of fatal) process.stdout.write(line('fatal', b));
  for (const b of tolerated) process.stdout.write(line('tolerated', b));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
