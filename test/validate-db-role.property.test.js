// Property test for lib/validate.js DB port + role + type validators (task 2.4).
//
// Feature: rootless-iobroker-container-image, Property 11: Database port, type, and multihost role validation
//
// A database backend port is accepted iff it is an integer within 1..65535; a
// multihost role iff it is exactly 'master' or 'slave'; a database type iff it
// is one of jsonl|file|redis. Rejections name the offending value.
//
// Validates: Requirements 12.9

import { describe, it, expect } from 'vitest';
import fc from 'fast-check';
import { assertParams } from './helpers/fast-check-config.js';
import {
  validateDbPort,
  validateRole,
  validateDbType,
  DB_PORT_MIN,
  DB_PORT_MAX,
  MULTIHOST_ROLES,
  DB_TYPES,
} from '../lib/validate.js';

describe('validateDbPort / validateRole / validateDbType', () => {
  it('accepts a db port iff it is an integer in 1–65535, naming rejected values', () => {
    fc.assert(
      fc.property(fc.integer({ min: -10, max: 70000 }), (port) => {
        const result = validateDbPort(port);
        const inRange = Number.isInteger(port) && port >= DB_PORT_MIN && port <= DB_PORT_MAX;
        expect(result.accepted).toBe(inRange);
        expect(result.value).toBe(port);
        if (!inRange) {
          expect(typeof result.reason).toBe('string');
          expect(result.reason.length).toBeGreaterThan(0);
        }
      }),
      assertParams,
    );
  });

  it('accepts a role iff it is exactly "master" or "slave", naming rejected values', () => {
    fc.assert(
      fc.property(fc.oneof(fc.constant('master'), fc.constant('slave'), fc.string()), (role) => {
        const result = validateRole(role);
        const ok = MULTIHOST_ROLES.includes(role);
        expect(result.accepted).toBe(ok);
        expect(result.value).toBe(role);
        if (!ok) expect(result.reason.length).toBeGreaterThan(0);
      }),
      assertParams,
    );
  });

  it('accepts a db type iff it is jsonl/file/redis, naming rejected values', () => {
    fc.assert(
      fc.property(
        fc.oneof(fc.constantFrom('jsonl', 'file', 'redis'), fc.string()),
        (type) => {
          const result = validateDbType(type);
          const ok = DB_TYPES.includes(type);
          expect(result.accepted).toBe(ok);
          expect(result.value).toBe(type);
          if (!ok) expect(result.reason.length).toBeGreaterThan(0);
        },
      ),
      assertParams,
    );
  });
});
