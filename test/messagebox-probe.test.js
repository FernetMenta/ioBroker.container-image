// Unit tests for `probeMessagebox` using an injected FAKE states client.
//
// Feature: the active messagebox round-trip self-probe (ioBroker #3524; see
// `lib/messagebox-probe.js`). These tests drive the pure probe logic with a fake
// client so no real DB is touched, mirroring how the other lib/ modules are
// tested as pure logic. They pin the three outcomes and the cleanup invariant.
//
// The fake simulates the host's reply by invoking the registered `change` handler
// with the probe's own unique `callback.id` and `ack: true` on the probe's reply
// channel (`messagebox.<replyFrom>`), exactly as js-controller delivers an inbound
// messagebox message.

import { describe, it, expect } from 'vitest';
import { probeMessagebox, ProbeOutcome } from '../lib/messagebox-probe.js';

const HOST = 'slave01';
const HOST_ID = `system.host.${HOST}`;
const REPLY_FROM = `${HOST_ID}.messagebox-probe`;
const UNIQUE_ID = 0x4abcdef0;

/**
 * Build a fake states client and a factory for it. The factory captures the
 * settings (so a test can invoke the `change`/`connected` callbacks) and records
 * every call for cleanup/interference assertions.
 *
 * @param {object} behavior - Controls the fake's responses.
 * @param {'resolve-null'|'resolve-value'|'reject'} behavior.getState
 *   How `getState` behaves (proves or fails DB reachability).
 * @param {boolean} [behavior.callConnected]
 *   Whether to invoke the `connected` callback when the client is built.
 * @param {boolean} [behavior.autoReply]
 *   When true, `pushMessage` immediately drives the registered `change` handler
 *   with a matching reply (simulates a live host answering the round-trip).
 * @param {boolean} [behavior.subscribeRejects]
 *   When true, `subscribeMessage` rejects (models the real client surfacing a
 *   redis error from the fresh probe subscription).
 * @param {boolean} [behavior.pushRejects]
 *   When true, `pushMessage` rejects (models the real client throwing on a
 *   DB-closed/publish error).
 * @param {boolean} [behavior.pushHangs]
 *   When true, `pushMessage` never settles (models a hung publish).
 * @param {number} [behavior.connectedAfterMs]
 *   When set, the `connected` callback fires asynchronously after this many ms
 *   (models the real client: the main connection services `getState` before the
 *   system pub/sub side is ready and `connected` fires). While `connected` has not
 *   fired, `subscribeMessage` behaves like the real client with no `subSystem`:
 *   it RESOLVES without registering anything (so a reply pushed before readiness
 *   would never route), and `autoReply` is suppressed until readiness.
 * @returns {{ factory: Function, calls: object, getSettings: Function }}
 */
function makeFake(behavior) {
  const calls = {
    subscribeMessage: [],
    unsubscribeMessage: [],
    pushMessage: [],
    getState: [],
    destroy: 0,
  };
  let settings = null;
  // Tracks whether the (optionally delayed) `connected` callback has fired, which
  // models the real client's system pub/sub (`subSystem`) readiness. A
  // subscription issued before readiness registers nothing (see makeFake docs).
  let pubSubReady = behavior.connectedAfterMs === undefined;

  const client = {
    async getState(id) {
      calls.getState.push(id);
      if (behavior.getState === 'reject') {
        throw new Error('DB closed');
      }
      return behavior.getState === 'resolve-value' ? { val: true } : null;
    },
    async subscribeMessage(id) {
      calls.subscribeMessage.push(id);
      if (behavior.subscribeRejects) {
        throw new Error('Connection is closed.');
      }
      // Model the real client: while the system pub/sub side is not ready, a
      // subscribe RESOLVES without registering anything (ERROR_DB_CLOSED is exempt
      // from rejection when no callback is given). Record readiness at subscribe
      // time so a later autoReply can tell whether routing would have worked.
      calls.subscribeMessage[calls.subscribeMessage.length - 1] = { id, pubSubReady };
    },
    async unsubscribeMessage(id) {
      calls.unsubscribeMessage.push(id);
    },
    async pushMessage(id, message) {
      calls.pushMessage.push({ id, message });
      if (behavior.pushRejects) {
        throw new Error('Connection is closed.');
      }
      if (behavior.pushHangs) {
        await new Promise(() => {}); // never settles
      }
      // A reply can only route back if the subscription was installed on a ready
      // pub/sub channel. If we subscribed before readiness, the reply is lost —
      // exactly the fresh-client race the probe must not misread as #3524.
      const lastSub = calls.subscribeMessage[calls.subscribeMessage.length - 1];
      const subscribedWhileReady = lastSub && lastSub.pubSubReady === true;
      if (behavior.autoReply && subscribedWhileReady) {
        // Simulate the host answering: re-deliver to our reply channel with the
        // same callback id and ack: true.
        settings.change(`messagebox.${REPLY_FROM}`, {
          command: 'getVersion',
          from: id,
          callback: { id: message.callback.id, ack: true, message: null },
        });
      }
    },
    async destroy() {
      calls.destroy += 1;
    },
  };

  const factory = (s) => {
    settings = s;
    if (behavior.callConnected) {
      s.connected();
    } else if (behavior.connectedAfterMs !== undefined) {
      // Fire `connected` asynchronously to model the system pub/sub side becoming
      // ready only after the main connection already served `getState`.
      setTimeout(() => {
        pubSubReady = true;
        s.connected();
      }, behavior.connectedAfterMs);
    }
    return client;
  };

  return { factory, calls, getSettings: () => settings };
}

describe('probeMessagebox (ioBroker #3524)', () => {
  it('DB reachable + reply delivered within timeout → ok', async () => {
    const { factory, calls } = makeFake({
      getState: 'resolve-value',
      callConnected: true,
      autoReply: true,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 1000,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.OK);
    // Sent the getVersion probe to the host with our unique callback id.
    expect(calls.pushMessage).toHaveLength(1);
    expect(calls.pushMessage[0].id).toBe(HOST_ID);
    expect(calls.pushMessage[0].message.command).toBe('getVersion');
    expect(calls.pushMessage[0].message.from).toBe(REPLY_FROM);
    expect(calls.pushMessage[0].message.callback.id).toBe(UNIQUE_ID);
    expect(calls.pushMessage[0].message.callback.ack).toBe(false);
  });

  it('DB reachable (connected fires, getState null) + NO reply before timeout → failed', async () => {
    const { factory } = makeFake({
      getState: 'resolve-null',
      callConnected: true,
      autoReply: false,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 30, // short so the test is fast
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.FAILED);
  });

  it('DB never reachable (getState rejects, no connected) → inconclusive (anti-restart-loop)', async () => {
    const { factory, calls } = makeFake({
      getState: 'reject',
      callConnected: false,
      autoReply: false,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 1000,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    // Critically, it must NOT have sent a probe message when the DB was unreachable.
    expect(calls.pushMessage).toHaveLength(0);
    expect(calls.subscribeMessage).toHaveLength(0);
  });

  it('a stale reply (wrong callback id) does NOT satisfy the probe → failed', async () => {
    // Guards against accepting unrelated messagebox traffic as our reply.
    const calls = {
      subscribeMessage: [],
      unsubscribeMessage: [],
      pushMessage: [],
      getState: [],
      destroy: 0,
    };
    let settings = null;
    const client = {
      async getState(id) {
        calls.getState.push(id);
        return { val: true };
      },
      async subscribeMessage(id) {
        calls.subscribeMessage.push(id);
      },
      async unsubscribeMessage(id) {
        calls.unsubscribeMessage.push(id);
      },
      async pushMessage(id, message) {
        calls.pushMessage.push({ id, message });
        // Reply with a DIFFERENT callback id — must be ignored.
        settings.change(`messagebox.${REPLY_FROM}`, {
          callback: { id: message.callback.id + 1, ack: true },
        });
      },
      async destroy() {
        calls.destroy += 1;
      },
    };
    const factory = (s) => {
      settings = s;
      s.connected(); // pub/sub ready so the probe subscribes and sends the round-trip
      return client;
    };

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 30,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.FAILED);
  });

  it('single overall deadline: a hung getState resolves to inconclusive, never hangs', async () => {
    // Review fix: the connect phase is bounded by the SAME overall deadline as the
    // round-trip. A states client whose getState never settles (DB unreachable, the
    // redis client queues the command offline) must still resolve within timeoutMs —
    // as inconclusive (DB unreachable), NOT as a messagebox failure.
    const calls = { unsubscribeMessage: [], pushMessage: [], destroy: 0 };
    const client = {
      getState() {
        return new Promise(() => {}); // never resolves
      },
      async subscribeMessage() {},
      async unsubscribeMessage(id) {
        calls.unsubscribeMessage.push(id);
      },
      async pushMessage(id, message) {
        calls.pushMessage.push({ id, message });
      },
      async destroy() {
        calls.destroy += 1;
      },
    };
    const factory = () => client;

    const started = Date.now();
    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 40,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    // It never attempted the round-trip (DB was never confirmed reachable)…
    expect(calls.pushMessage).toHaveLength(0);
    // …and it still cleaned up and returned promptly (well under a second).
    expect(Date.now() - started).toBeLessThan(900);
    expect(calls.destroy).toBe(1);
  });

  it('failed is emitted after waiting the full deadline (the #3524 driver)', async () => {
    // Regression guard for the blocking review finding: the `failed` outcome is the
    // only one that must wait out the whole timeout, so the single overall deadline
    // (not an outer wrapper of equal duration) must be what emits it. Here DB is
    // reachable (getState resolves) and no reply ever arrives.
    const { factory, calls } = makeFake({
      getState: 'resolve-value',
      callConnected: true,
      autoReply: false,
    });

    const started = Date.now();
    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 50,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.FAILED);
    // It did attempt the round-trip and waited roughly the deadline before failing.
    expect(calls.pushMessage).toHaveLength(1);
    expect(Date.now() - started).toBeGreaterThanOrEqual(40);
  });

  it('getState returns null with NO connected signal → inconclusive, never failed', async () => {
    // Review finding #1: the real db-states-redis client CATCHES a redis GET error
    // and returns `null` (statesInRedisClient getState ~668-693), so a null result
    // is indistinguishable from a failed DB request and must NOT prove reachability.
    // With no `connected` signal either, the DB is never positively confirmed
    // reachable, so this must be inconclusive (a DB outage is caught by `iobroker
    // status`), NOT a messagebox failure — otherwise a plain DB drop would drive a
    // restart loop.
    const { factory, calls } = makeFake({
      getState: 'resolve-null',
      callConnected: false,
      autoReply: false,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 1000,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    // It must NOT have sent a probe when the DB was never confirmed reachable.
    expect(calls.pushMessage).toHaveLength(0);
    expect(calls.subscribeMessage).toHaveLength(0);
  });

  it('subscribeMessage rejects on a reachable DB → inconclusive (round-trip never sent)', async () => {
    // Review finding #1: a rejecting fresh probe subscription (the real client
    // surfaces a redis error from subscribeMessage) must NOT be read as a dead
    // messagebox. The round-trip was never cleanly sent, so the result is
    // inconclusive, not failed.
    const { factory, calls } = makeFake({
      getState: 'resolve-value', // DB positively reachable (non-null read)
      callConnected: true, // pub/sub ready, so the subscribe is actually attempted
      subscribeRejects: true,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 1000,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    // subscribe was attempted but push must not have been reached.
    expect(calls.subscribeMessage).toHaveLength(1);
    expect(calls.pushMessage).toHaveLength(0);
  });

  it('non-null getState before a delayed connected → waits for readiness, then completes the round trip → ok', async () => {
    // Review finding #1 (fresh-client readiness race): the main redis connection
    // services getState BEFORE the system pub/sub side is ready, and subscribing
    // before readiness silently registers nothing (resolves, no reject). The probe
    // must NOT subscribe on the strength of getState alone — it must await the
    // `connected` callback (the only pub/sub-ready signal) before subscribing, then
    // complete the round trip. Here getState resolves a non-null value immediately
    // but `connected` fires only after 20ms; with a 1000ms deadline the probe must
    // wait for readiness, subscribe on a ready channel, and get the reply → ok.
    const { factory, calls } = makeFake({
      getState: 'resolve-value',
      connectedAfterMs: 20,
      autoReply: true,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 1000,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.OK);
    // It subscribed only once, and only after pub/sub readiness (so the reply routed).
    expect(calls.subscribeMessage).toHaveLength(1);
    expect(calls.subscribeMessage[0].pubSubReady).toBe(true);
    expect(calls.pushMessage).toHaveLength(1);
  });

  it('non-null getState but connected never fires within the deadline → inconclusive, never failed', async () => {
    // The other half of finding #1: if the system pub/sub side never becomes ready
    // within the deadline (connected never fires), a subscription issued now would
    // register nothing, so the round-trip can never be cleanly sent. That must be
    // inconclusive (NOT a messagebox failure) so a boot/reconnect fresh-client race
    // cannot be misread as #3524 and drive a restart loop.
    const { factory, calls } = makeFake({
      getState: 'resolve-value', // DB reachable at the main connection…
      connectedAfterMs: 10_000, // …but pub/sub readiness never arrives in time
      autoReply: true,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 40,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    // It must NOT have subscribed or pushed before pub/sub readiness.
    expect(calls.subscribeMessage).toHaveLength(0);
    expect(calls.pushMessage).toHaveLength(0);
  });

  it('pushMessage rejects on a reachable DB → inconclusive (round-trip never sent)', async () => {
    // Review finding #1: the real client THROWS from pushMessage on a DB-closed /
    // publish error. A rejecting publish means the round-trip was never confirmed
    // sent, so this is inconclusive, not a messagebox failure.
    const { factory, calls } = makeFake({
      getState: 'resolve-value',
      callConnected: true,
      pushRejects: true,
    });

    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 1000,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    expect(calls.pushMessage).toHaveLength(1);
  });

  it('pushMessage hangs on a reachable DB → inconclusive within the deadline, cleans up', async () => {
    // A publish that never settles must be bounded by the overall deadline and
    // resolve inconclusive (round-trip not confirmed sent), never hang.
    const { factory, calls } = makeFake({
      getState: 'resolve-value',
      callConnected: true,
      pushHangs: true,
    });

    const started = Date.now();
    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 40,
      uniqueId: () => UNIQUE_ID,
    });

    expect(result.outcome).toBe(ProbeOutcome.INCONCLUSIVE);
    expect(Date.now() - started).toBeLessThan(900);
    expect(calls.destroy).toBe(1);
    expect(calls.unsubscribeMessage).toContain(REPLY_FROM);
  });

  it('overall duration (incl. cleanup) stays within ~timeoutMs + cleanup grace even when destroy hangs', async () => {
    // Review finding #2: cleanup must not grant each teardown step its own fresh
    // budget. Here DB is reachable, no reply arrives (so the deadline is consumed
    // by the `failed` wait), AND destroy() hangs. The whole probe — teardown
    // included — must still resolve within roughly timeoutMs + one shared cleanup
    // grace (~1s), not timeoutMs + N × budget.
    const calls = { unsubscribeMessage: [], pushMessage: [], destroy: 0 };
    const client = {
      async getState() {
        return { val: true }; // DB reachable
      },
      async subscribeMessage() {},
      async unsubscribeMessage(id) {
        calls.unsubscribeMessage.push(id);
      },
      async pushMessage(id, message) {
        calls.pushMessage.push({ id, message });
      },
      destroy() {
        return new Promise(() => {}); // never settles
      },
    };
    const factory = (s) => {
      s.connected(); // pub/sub ready so the round-trip is sent and awaits the reply
      return client;
    };

    const started = Date.now();
    const result = await probeMessagebox({
      createStatesClient: factory,
      hostName: HOST,
      timeoutMs: 50,
      uniqueId: () => UNIQUE_ID,
    });
    const elapsed = Date.now() - started;

    // No reply on a reachable DB with a cleanly-sent round-trip => failed.
    expect(result.outcome).toBe(ProbeOutcome.FAILED);
    // 50ms deadline + ~1s shared cleanup grace for the hung destroy; must NOT be
    // the old timeoutMs + 2×1s path, and must be well under the shell backstop.
    expect(elapsed).toBeLessThan(1500);
    expect(calls.unsubscribeMessage).toContain(REPLY_FROM);
  });

  it('cleanup invariant: unsubscribeMessage and destroy run on every outcome', async () => {
    const cases = [
      { getState: 'resolve-value', callConnected: true, autoReply: true }, // ok
      { getState: 'resolve-null', callConnected: true, autoReply: false }, // failed
      { getState: 'reject', callConnected: false }, // inconclusive
    ];

    for (const behavior of cases) {
      const { factory, calls } = makeFake(behavior);
      await probeMessagebox({
        createStatesClient: factory,
        hostName: HOST,
        timeoutMs: 20,
        uniqueId: () => UNIQUE_ID,
      });

      // destroy always runs; unsubscribe runs whenever a client was built.
      expect(calls.destroy).toBe(1);
      expect(calls.unsubscribeMessage).toContain(REPLY_FROM);
    }
  });
});
