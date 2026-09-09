// Unit test for happy-path Node major version derivation (task 3.3).
//
// Verifies the concrete happy path of `lib/node-major.js`: a valid `nodeMajor`
// value derives to its integer major version, both from a string and from a
// real integer, and via the package.json Build_Config convenience helper. Also
// confirms that NO fallback path exists — an absent value throws rather than
// returning a default.
//
// Requirements: 5.4 (read the Node.js major version from the integer value of
// the `nodeMajor` field of the Build_Config).

import { describe, it, expect } from 'vitest';
import {
  deriveNodeMajor,
  deriveNodeMajorFromPackageJson,
  NodeMajorDerivationError,
} from '../lib/node-major.js';

describe('Node major derivation (happy path)', () => {
  it('derives 22 from the string "22"', () => {
    expect(deriveNodeMajor('22')).toBe(22);
  });

  it('derives 22 from the integer 22', () => {
    expect(deriveNodeMajor(22)).toBe(22);
  });

  it('derives 22 from a package.json with containerImage.nodeMajor "22"', () => {
    expect(deriveNodeMajorFromPackageJson({ containerImage: { nodeMajor: '22' } })).toBe(22);
  });

  it('has no fallback path: an absent value throws instead of returning a default', () => {
    expect(() => deriveNodeMajor(undefined)).toThrow(NodeMajorDerivationError);
  });
});
