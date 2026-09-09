// Unit test for the database-backend planner mapping / no-op behavior (task 7.3).
//
// Verifies: nothing specified -> no-op (leave local config untouched, Req 12.3);
// specified objects/states fields flow into the plan target for each DB
// independently (Req 12.1, 12.4, 12.5); role flows through (Req 12.6); invalid
// type/port/role are rejected naming the value (Req 12.9).
//
// Requirements: 12.1, 12.3, 12.4, 12.5, 12.6, 12.9

import { describe, it, expect } from 'vitest';
import { planDbConfig } from '../lib/db-plan.js';

describe('db-plan: specified-only patch + no-op', () => {
  it('is a no-op when the operator specifies nothing (Req 12.3)', () => {
    const plan = planDbConfig({}, { objects: { type: 'jsonl' }, states: { type: 'jsonl' } });
    expect(plan.valid).toBe(true);
    expect(plan.changed).toBe(false);
    expect(plan.objects).toEqual({});
    expect(plan.states).toEqual({});
    expect(plan.role).toBe('');
  });

  it('configures objects and states independently with their own host/port (Req 12.1, 12.4, 12.5)', () => {
    const plan = planDbConfig(
      {
        objects: { type: 'jsonl', host: 'iob', port: '9001' },
        states: { type: 'jsonl', host: 'iob', port: '9000' },
        role: 'slave',
      },
      {},
    );
    expect(plan.valid).toBe(true);
    expect(plan.changed).toBe(true);
    expect(plan.objects).toEqual({ type: 'jsonl', host: 'iob', port: 9001 });
    expect(plan.states).toEqual({ type: 'jsonl', host: 'iob', port: 9000 });
    expect(plan.role).toBe('slave');
  });

  it('accepts redis as a type (Req 12.2)', () => {
    const plan = planDbConfig({ objects: { type: 'redis', host: 'r', port: 6379 } }, {});
    expect(plan.valid).toBe(true);
    expect(plan.objects.type).toBe('redis');
  });

  it('rejects an invalid objects type, naming the value (Req 12.9)', () => {
    const plan = planDbConfig({ objects: { type: 'mongo' } }, {});
    expect(plan.valid).toBe(false);
    expect(plan.reason).toBe('invalid-objects-type');
    expect(plan.value).toBe('mongo');
  });

  it('rejects an out-of-range states port, naming the value (Req 12.9)', () => {
    const plan = planDbConfig({ states: { port: 99999 } }, {});
    expect(plan.valid).toBe(false);
    expect(plan.reason).toBe('invalid-states-port');
    expect(plan.value).toBe(99999);
  });

  it('rejects an invalid role, naming the value (Req 12.9)', () => {
    const plan = planDbConfig({ role: 'leader' }, {});
    expect(plan.valid).toBe(false);
    expect(plan.reason).toBe('invalid-role');
    expect(plan.value).toBe('leader');
  });
});
