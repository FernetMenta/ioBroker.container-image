// Active messagebox self-probe for the container healthcheck (ioBroker #3524).
//
// WHAT THIS DETECTS
// In a multihost slave, after a states/objects DB reconnect where the TCP close
// was never observed (rootless container networking), the host's inbound message
// channel (`messagebox.system.host.<name>` pub/sub subscription) can die silently
// while `iobroker status` still reports healthy. The existing healthcheck only
// runs `iobroker status`, which stays green during this bug, so it never catches
// it. This probe actively verifies the host can still RECEIVE and ANSWER a host
// message. Flagging the container unhealthy is the entire required action — the
// operator's quadlet kills and restarts the container, and a restart re-subscribes
// the messagebox on boot and recovers. This script does NOT restart anything.
//
// HOW THE ROUND-TRIP WORKS (grounded in installed js-controller source — see the
// note at the bottom; citations are from the SOURCE checked out at the sibling
// workspace `/home/rainer/progs/src/ioBroker.js-controller` because the
// `@iobroker/*` packages are not installed in THIS repo's environment):
//   - The states client publishes a message to a messagebox channel via
//     `pushMessage(id, message)`  (db-states-redis statesInRedisClient.ts ~1796:
//     publishes JSON of `{ ...message, _id }` to `messagebox.<id>`).
//   - It subscribes to a messagebox channel via `subscribeMessage(id)`
//     (statesInRedisClient.ts ~1834: `psubscribe` on `messagebox.<id>`), and
//     cleans up with `unsubscribeMessage(id)` (~1877: `punsubscribe`).
//   - Incoming messages are delivered through the `change` handler passed in the
//     client constructor settings: the system `pmessage` handler JSON-parses the
//     payload and calls `onChange(channel, parsedMessage)` (statesInRedisClient.ts
//     ~363-423, ~411/413). For a subscribed messagebox channel the id handed to
//     `change` is `messagebox.<id>` (exactly how the controller recognizes its own
//     inbound host messages: `id === messagebox.${hostObjectPrefix}` in
//     controller main.ts ~535).
//   - The reply/callback mechanism mirrors the controller's own host-liveness
//     check `getVersionFromHost` (controller main.ts ~2045): it sends a `getVersion`
//     message carrying a `callback` (ack:false, unique id) to `system.host.<name>`.
//     The receiving host answers by re-sending the message back to the ORIGINAL
//     sender's messagebox (`sendTo(msg.from, msg.command, payload, msg.callback)`,
//     main.ts ~1985) with `callback.ack = true` and the SAME `callback.id`. The
//     sender recognizes the reply by `obj.callback.ack && obj.callback.id`
//     (main.ts ~540). `getVersion` is the lightweight, side-effect-free,
//     reply-guaranteed command the controller itself uses for host liveness
//     (case at main.ts ~3036); receiving its reply proves the host's inbound
//     messagebox subscription is live AND the host answered.
//
// PACKAGE RESOLUTION IN THE IMAGE (review fix):
// This module ships under `/opt/lib` while the `@iobroker/*` packages live under
// `<IOB_ROOT>/node_modules` (`/opt/iobroker/node_modules`). A bare dynamic import
// of `@iobroker/db-states-<type>` would resolve from this module's own directory
// ancestry (`/opt/lib`, `/opt`, `/`) and fail with ERR_MODULE_NOT_FOUND. The CLI
// entry therefore resolves the package explicitly from the install root with
// `createRequire(<IOB_ROOT>/package.json).resolve(pkg)` and imports the resolved
// path as a `file://` URL. See `buildRealClientFactory` below.
//
// SINGLE OVERALL DEADLINE INCLUDING CLEANUP (review fix):
// The probe applies ONE bounded deadline (`timeoutMs`) from entry that governs
// client construction, DB-reachability confirmation, subscribe, publish, the
// reply wait, AND teardown (unsubscribe + destroy). There is no separate
// per-phase timer: every DB-touching await races the SAME deadline, so no phase
// can hang past `timeoutMs`, even when the states client queues a command offline
// (which `getState` does when the DB is unreachable). Teardown shares that one
// deadline too while it is still live; the single exception is a stalled teardown
// AFTER the deadline has already expired, which is capped by ONE small shared
// `CLEANUP_GRACE_MS` backstop across both steps — so the absolute worst case is
// `timeoutMs + CLEANUP_GRACE_MS`, never `timeoutMs + N × budget`. The shell
// backstop (`IOB_MESSAGEBOX_PROBE_TIMEOUT + 10`s) plus the clamp on the probe
// timeout keep that worst case well inside the healthcheck's 30s per-check budget.
// This guarantee holds independent of any outer `timeout` wrapper, and it ensures
// the `failed` outcome (the one that must wait out the full timeout) is emitted by
// THIS module rather than preempted by an equal-duration outer wrapper. See
// `probeMessagebox` for the per-phase detail.
//
// OPERATION ERRORS ARE NOT A DEADLINE (review fix):
// A rejected DB operation (getState / subscribeMessage / pushMessage throwing,
// e.g. ERROR_DB_CLOSED) is kept DISTINCT from the overall deadline expiring. A
// setup/transport rejection ALWAYS yields `inconclusive`, never `failed`: it
// means we never positively completed the round-trip send on a confirmed-reachable
// DB, so it must not be reported as a dead messagebox. Only a cleanly SENT
// round-trip (subscribe + push both resolved) on a POSITIVELY-reachable DB that
// then produces no reply before the deadline yields `failed`. See the real client
// error behavior cited in `buildRealClientFactory`.
//
// SUBSCRIBE READINESS IS GATED ON `connected`, NOT ON `getState` (review fix):
// The states client services `getState` on its MAIN redis connection, which reaches
// `ready` BEFORE the separate system pub/sub connection (`subSystem`) is even
// created — `subSystem` is instantiated INSIDE the main client's `ready` handler
// and only then reaches its own `ready` (db-states-redis statesInRedisClient.js
// ~250-259, ~345). The `connected` callback is fired only AFTER `subSystem` is
// ready and its initial subscriptions are issued (~374/457/484). Crucially,
// `subscribeMessage` while `subSystem` is still null does NOT reject: with no
// callback it routes through `maybeCallbackWithError(undefined, ERROR_DB_CLOSED)`,
// and because ERROR_DB_CLOSED is exempt from rejection there, it RESOLVES with
// `undefined` and silently registers NOTHING (maybeCallback.js ~28-44;
// statesInRedisClient.js subscribeMessage ~952-956). A probe that subscribed on the
// strength of a successful `getState` alone could therefore push its `getVersion`
// against a subscription that was never actually installed, never receive the
// reply, and report `failed` on a perfectly healthy host — a false positive that
// repeats every cycle (the fresh-client race). THEREFORE: a non-null `getState`
// establishes DB REACHABILITY only (to tell a DB outage apart from a dead
// messagebox); it does NOT establish that the round-trip can be sent. Before
// subscribing, the probe AWAITS the `connected` callback (bounded by the overall
// deadline). If `connected` never fires within the deadline, the system pub/sub
// side was never ready, so the round-trip was never cleanly sent => `inconclusive`,
// never `failed`.
//
// `getState` NULL IS NOT PROOF OF REACHABILITY (review fix):
// The installed states client CATCHES a redis GET error and returns `null`
// (db-states-redis statesInRedisClient.js getState ~668-693: the try/catch around
// `this.client.get(...)` swallows the error, then `if (!obj) return null`), so an
// absent state and a FAILED DB request are indistinguishable at the `getState`
// return value. Therefore a `null` getState result is NOT treated as positive DB
// evidence. DB reachability is only positively confirmed by (a) the client's
// `connected` callback firing, or (b) a NON-NULL `getState` value (a value can
// only come back from a completed read). This closes the false-positive path where
// a GET error on a dropped DB would otherwise look like a reachable DB.
//
// SEMANTIC DISTINCTION — DB-DOWN IS NOT A MESSAGEBOX FAILURE (crucial, see #3524):
// This probe reports `failed` ONLY when it has POSITIVELY confirmed the host is
// reachable at the states-DB level (the client's `connected` callback fired and/or
// a `getState('system.host.<name>.alive')` round-trip succeeded) BUT the messagebox
// reply did not arrive within the bounded timeout. If the probe cannot even
// establish a states connection, that is a DB outage — already covered by
// `iobroker status` — and is reported as `inconclusive`, NEVER as a messagebox
// `failed`. Reporting a DB outage as a messagebox failure would double-penalize it
// and cause a restart loop. This is a deliberate decision: only a confirmed
// DB-reachable + messagebox-timeout counts as the #3524 signature.

import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

/**
 * Possible probe outcomes.
 *
 * - `ok`           — DB reachable AND messagebox reply received within the timeout.
 * - `failed`       — DB reachable (positively confirmed) BUT messagebox reply did
 *                    NOT arrive within the timeout. This is the ONLY case the
 *                    healthcheck treats as a messagebox failure (the #3524 signature).
 * - `inconclusive` — DB never confirmed reachable, or any setup error occurred.
 *                    Deliberately NOT a messagebox failure (DB outages are caught
 *                    by `iobroker status`; see the module header).
 *
 * @readonly
 * @enum {string}
 */
export const ProbeOutcome = Object.freeze({
  OK: 'ok',
  FAILED: 'failed',
  INCONCLUSIVE: 'inconclusive',
});

/**
 * @typedef {object} StatesClientLike
 * @property {(id: string) => Promise<void>} subscribeMessage
 *   Subscribe to a messagebox channel (`messagebox.<id>`).
 * @property {(id: string) => Promise<void>} unsubscribeMessage
 *   Unsubscribe from a messagebox channel.
 * @property {(id: string, message: object) => Promise<void>} pushMessage
 *   Publish a message to a target's messagebox (`messagebox.<id>`).
 * @property {(id: string) => Promise<any>} getState
 *   Read a state (used to positively confirm DB reachability).
 * @property {() => Promise<void>} destroy
 *   Tear down the client's DB connections.
 */

/**
 * @typedef {object} ProbeOptions
 * @property {(settings: object) => StatesClientLike} createStatesClient
 *   Factory that builds a states client from the given settings. The settings
 *   object carries a `connected` callback (invoked once the DB connects) and a
 *   `change` handler (invoked with `(id, message)` for subscribed channels),
 *   mirroring the js-controller `new States({ ..., connected, change })` shape.
 *   Injected so unit tests can drive a fake client with no real DB.
 * @property {string} hostName
 *   The host name (resolved like js-controller's `getHostName`). The probe target
 *   is `system.host.<hostName>`.
 * @property {number} [timeoutMs]
 *   Single overall deadline, in milliseconds, bounding EVERYTHING from probe
 *   entry: client construction, DB-reachability confirmation (`getState`),
 *   subscribe, publish, the reply wait, AND cleanup (unsubscribe + destroy).
 *   Default 5000 (matches the controller's own 5s host-liveness timeout in
 *   `getVersionFromHost`). No single phase has its own separate timer — the one
 *   deadline guarantees the probe always resolves and never hangs even if the
 *   underlying states client queues a command offline (which `getState` does
 *   when the DB is unreachable; see db-states-redis statesInRedisClient.ts
 *   ~1300, `this.client.get(...)`), independent of any outer `timeout` wrapper.
 * @property {() => number} [now]
 *   Clock used for the message `callback.time`. Defaults to `Date.now`.
 * @property {() => number} [uniqueId]
 *   Supplies the probe-unique `callback.id`. Defaults to a large random integer
 *   chosen outside the controller's `callbackId` space so the reply is matched
 *   only by this probe and never consumed by the controller's callback table.
 */

/**
 * @typedef {object} ProbeResult
 * @property {ProbeOutcome[keyof ProbeOutcome]} outcome - The probe outcome.
 * @property {string} detail - A short human-readable explanation (for logs).
 */

/**
 * Actively verify the local host's inbound messagebox round-trip is alive.
 *
 * The flow mirrors the controller's own `getVersionFromHost`:
 *   1. build the states client with a `connected` callback and a `change` handler;
 *   2. positively confirm DB reachability (the `connected` callback fires OR a
 *      non-null `getState('system.host.<name>.alive')` resolves);
 *   2b. await pub/sub readiness via the `connected` callback BEFORE subscribing —
 *      a successful `getState` proves DB reachability but NOT that the system
 *      pub/sub connection is ready, and subscribing before it is silently a no-op
 *      (review finding #1; see the module header). If `connected` never fires
 *      within the deadline the round-trip was never sent => `inconclusive`;
 *   3. `subscribeMessage(<replyChannel>)` where the reply channel is a
 *      probe-unique `from` id so the host's reply is routed to THIS probe's
 *      listener and never consumed by the controller's callback table;
 *   4. `pushMessage('system.host.<name>', { command: 'getVersion', message: null,
 *      from: <replyChannel>, callback: { message: null, id: <uniqueId>,
 *      ack: false, time } })`;
 *   5. resolve `ok` when the `change` handler sees the reply (matched by the
 *      unique `callback.id` with `callback.ack === true`) before the deadline;
 *   6. resolve `failed` when the DB was positively reachable but no reply arrived
 *      before the deadline;
 *   7. resolve `inconclusive` when the DB was never confirmed reachable or any
 *      setup error occurred (see the module header — this is NOT a messagebox
 *      failure).
 *
 * SINGLE OVERALL DEADLINE (review fix): one `timeoutMs` deadline is armed at the
 * very start and governs the WHOLE probe — connect, `getState`, subscribe,
 * publish, reply wait, and cleanup. No phase has a separate timer. If the
 * deadline fires we short-circuit to a result based on what we had positively
 * confirmed so far (DB reachable + no reply observed => `failed`; DB never
 * confirmed, or reachable but round-trip not completed => `inconclusive`) and
 * then run (hard-bounded) cleanup. This matters because `getState` can block
 * when the DB is unreachable (the redis client queues commands offline —
 * statesInRedisClient.ts ~1300, `this.client.get(...)`), so bounding ONLY the
 * reply wait would leave the connect phase able to hang; and because the earlier
 * design let an outer `timeout` of the SAME duration preempt the reply wait
 * before `failed` could ever be emitted.
 *
 * Cleanup (`unsubscribeMessage` then `destroy`) always runs via a `finally`, each
 * step itself hard-bounded so the probe never leaves a subscription registered
 * and never hangs, regardless of outcome.
 *
 * @param {ProbeOptions} options - Injected dependencies and tuning.
 * @returns {Promise<ProbeResult>} The resolved outcome and a short detail string.
 */
export async function probeMessagebox({
  createStatesClient,
  hostName,
  timeoutMs = 5000,
  now = Date.now,
  uniqueId = defaultUniqueId,
}) {
  const hostId = `system.host.${hostName}`;
  // A probe-unique `from` id (inside the host namespace so js-controller's sendTo
  // leaves it untouched) whose messagebox channel only this probe listens on.
  const replyFrom = `${hostId}.messagebox-probe`;
  const callbackId = uniqueId();

  let dbReachable = false;
  let replyReceived = false;
  let deadlineFired = false;
  let pubSubReady = false;
  /** @type {StatesClientLike | null} */
  let client = null;

  // ---- The single overall deadline -------------------------------------
  // One timer bounds the ENTIRE probe, cleanup included. `deadline` resolves
  // (never rejects) with the TIMED_OUT sentinel when it fires. Every await below
  // — including the teardown in `finally` — is raced against this one deadline,
  // so no phase can hang past `timeoutMs`, independent of any outer wrapper.
  const TIMED_OUT = Symbol('timed-out');
  // A distinct sentinel for an OPERATION that REJECTED (as opposed to the overall
  // deadline firing). Keeping these separate is what prevents a DB/transport error
  // from being misread as a messagebox round-trip timeout (review finding #1).
  const OP_REJECTED = Symbol('op-rejected');
  let deadlineTimer = null;
  const deadline = new Promise((resolve) => {
    deadlineTimer = setTimeout(() => {
      deadlineFired = true;
      resolve(TIMED_OUT);
    }, timeoutMs);
  });
  // Race an operation against the deadline. Resolves to: the operation's value;
  // TIMED_OUT if the deadline won; or OP_REJECTED if the operation itself threw.
  // The three cases are DISTINCT so callers can tell a rejected setup operation
  // (=> inconclusive) apart from the overall deadline expiring.
  const raceDeadline = (p) =>
    Promise.race([
      Promise.resolve(p).then(
        (v) => v,
        () => OP_REJECTED,
      ),
      deadline,
    ]);

  try {
    // The `change` handler sees `messagebox.<replyFrom>` for our reply channel
    // (same delivery path the controller uses for `messagebox.<host>`). We accept
    // the reply only when it carries our unique callback id with ack === true.
    let resolveReply;
    const replyArrived = new Promise((resolve) => {
      resolveReply = resolve;
    });
    const change = (id, message) => {
      if (replyReceived || id !== `messagebox.${replyFrom}`) {
        return;
      }
      const cb = message && message.callback;
      if (cb && cb.ack === true && cb.id === callbackId) {
        replyReceived = true;
        resolveReply();
      }
    };

    // The `connected` callback is the ONLY signal that the system pub/sub side
    // (`subSystem`) is ready, which is what `subscribeMessage` needs (see the
    // module header "SUBSCRIBE READINESS" note). It also proves DB reachability.
    // We capture it as a promise so we can AWAIT readiness before subscribing.
    let resolveConnected;
    const connectedReady = new Promise((resolve) => {
      resolveConnected = resolve;
    });
    const connected = () => {
      dbReachable = true;
      pubSubReady = true;
      resolveConnected();
    };

    client = createStatesClient({
      namespace: `system.host.${hostName}.messagebox-probe`,
      hostname: hostName,
      connected,
      change,
    });

    // Positively confirm DB reachability, bounded by the overall deadline. A
    // NON-NULL getState value proves the DB answered; the `connected` callback is
    // the other positive signal. A `null` result does NOT prove reachability (the
    // real client returns null on a GET error — see the module header), and a
    // rejected/timed-out getState is likewise no evidence. Any of those simply
    // leaves dbReachable as whatever `connected` set — never a messagebox failure.
    //
    // A getState attempted during the client's async connect can REJECT with
    // ERROR_DB_CLOSED before `connected` has fired, even on a perfectly healthy DB
    // that is merely slow to finish initializing (the real client only completes
    // init — _determineProtocolVersion, subSystem ready — some ticks after
    // construction). So an immediate getState rejection/null is NOT final: if it
    // did not positively confirm reachability we WAIT for the `connected` callback
    // (bounded by the overall deadline) before concluding the DB is unreachable.
    // This both avoids a fresh-client false negative and prevents tearing the
    // client down mid-init (which would surface the client's own init error).
    const alive = await raceDeadline(client.getState(`${hostId}.alive`));
    if (alive !== TIMED_OUT && alive !== OP_REJECTED && alive !== null && alive !== undefined) {
      dbReachable = true;
    }

    if (!dbReachable && !deadlineFired) {
      // getState did not positively confirm reachability yet. Give the client's
      // async connect a chance to finish: await `connected` within the deadline.
      await Promise.race([connectedReady, deadline]);
      // `connected` sets dbReachable; nothing else does here.
    }

    if (!dbReachable) {
      // The DB was never positively confirmed reachable (deadline fired first, or
      // getState rejected / returned null, and `connected` never fired). This is a
      // DB-reachability problem, already covered by `iobroker status` — never a
      // messagebox failure. Reporting it as one would double-penalize a DB outage
      // and drive a restart loop.
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: deadlineFired
          ? `states DB not confirmed reachable within ${timeoutMs}ms (not a messagebox failure; see iobroker status)`
          : 'states DB not confirmed reachable (not a messagebox failure; see iobroker status)',
      };
    }

    if (deadlineFired) {
      // DB was confirmed reachable (e.g. via `connected`) but the deadline is
      // already spent, so we never attempted/observed the round-trip. Report
      // inconclusive rather than failed: we did NOT positively observe a missed
      // messagebox reply, and must not flag a messagebox failure without it.
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: `deadline elapsed during DB confirmation (${timeoutMs}ms); messagebox round-trip not attempted`,
      };
    }

    // Await pub/sub readiness BEFORE subscribing (review finding #1). A non-null
    // `getState` proved the DB is reachable, but it does NOT prove the system
    // pub/sub connection (`subSystem`) is ready — the main connection reaches
    // `ready` first, and `subscribeMessage` silently no-ops (resolving, not
    // rejecting) while `subSystem` is still null (see the module header). Only the
    // `connected` callback signals that `subSystem` is ready. We wait for it within
    // the overall deadline. If it has not fired by now, wait (bounded) for it.
    if (!pubSubReady) {
      await Promise.race([connectedReady, deadline]);
    }
    if (!pubSubReady) {
      // The system pub/sub side never became ready within the deadline. A
      // subscription issued now would silently register nothing, so the round-trip
      // could never be cleanly sent. That is NOT a messagebox failure (we never
      // positively observed a missed reply on a ready channel); report inconclusive
      // so a fresh-client race at boot/reconnect cannot be misread as #3524.
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: deadlineFired
          ? `pub/sub (subSystem) not ready within ${timeoutMs}ms; round-trip never sent`
          : 'pub/sub (subSystem) not ready; round-trip never sent',
      };
    }

    // Subscribe to our own reply channel, then send the host a getVersion probe —
    // both bounded by the overall deadline. BOTH must COMPLETE SUCCESSFULLY before
    // a no-reply timeout may count as `failed`: if either rejects (e.g.
    // ERROR_DB_CLOSED — the real client throws from pushMessage and rejects from
    // subscribeMessage, see the module header) or the deadline fires here, the
    // round-trip was never cleanly sent, so the result is `inconclusive`, NOT a
    // dead messagebox. This is the second half of review finding #1.
    const subResult = await raceDeadline(client.subscribeMessage(replyFrom));
    if (subResult === OP_REJECTED) {
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: 'subscribeMessage failed (not a messagebox failure; round-trip never sent)',
      };
    }
    if (subResult === TIMED_OUT || deadlineFired) {
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: `deadline elapsed during subscribe (${timeoutMs}ms); round-trip never sent`,
      };
    }

    const pushResult = await raceDeadline(
      client.pushMessage(hostId, {
        command: 'getVersion',
        message: null,
        from: replyFrom,
        callback: {
          message: null,
          id: callbackId,
          ack: false,
          time: now(),
        },
      }),
    );
    if (pushResult === OP_REJECTED) {
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: 'pushMessage failed (not a messagebox failure; round-trip never sent)',
      };
    }
    if (pushResult === TIMED_OUT || deadlineFired) {
      return {
        outcome: ProbeOutcome.INCONCLUSIVE,
        detail: `deadline elapsed during publish (${timeoutMs}ms); round-trip not confirmed sent`,
      };
    }

    // The round-trip was cleanly sent on a positively-reachable DB. Wait for the
    // reply or the overall deadline, whichever comes first. A deadline here (no
    // reply) is the #3524 signature => failed.
    if (!replyReceived) {
      await Promise.race([replyArrived, deadline]);
    }

    if (replyReceived) {
      return { outcome: ProbeOutcome.OK, detail: 'messagebox round-trip succeeded' };
    }
    return {
      outcome: ProbeOutcome.FAILED,
      detail: `no messagebox reply within ${timeoutMs}ms (DB reachable, round-trip sent) — #3524 signature`,
    };
  } catch (err) {
    // Any setup/transport error is inconclusive: we never positively observed a
    // missed messagebox reply on a reachable DB.
    return {
      outcome: ProbeOutcome.INCONCLUSIVE,
      detail: `probe setup error: ${err && err.message ? err.message : String(err)}`,
    };
  } finally {
    // Always leave no subscription registered and release the DB connections, on
    // every exit path, bounded so teardown can never hang (review finding #2).
    //
    // Both teardown steps race ONE shared `cleanupDeadline`, so the WHOLE teardown
    // (not each step) is bounded:
    //   - If the overall deadline has NOT yet fired, cleanup shares it, so the
    //     whole probe including teardown finishes within `timeoutMs`.
    //   - If the overall deadline has ALREADY fired (racing against it would
    //     resolve instantly and skip teardown), a single small `CLEANUP_GRACE_MS`
    //     backstop caps BOTH steps together, so the worst-case total is
    //     `timeoutMs + CLEANUP_GRACE_MS` — not `timeoutMs + N × budget`.
    // The shell sizes its outer `timeout` backstop against the time already elapsed
    // in the healthcheck (status + fact gathering) so the WHOLE script stays inside
    // Docker's 30s bound (review finding #2), and the module clamp is a second bound.
    if (client) {
      let graceTimer = null;
      const cleanupDeadline = deadlineFired
        ? new Promise((resolve) => {
            graceTimer = setTimeout(resolve, CLEANUP_GRACE_MS);
          })
        : deadline;
      try {
        await raceCleanup(() => client.unsubscribeMessage(replyFrom), cleanupDeadline);
        await raceCleanup(() => client.destroy(), cleanupDeadline);
      } finally {
        if (graceTimer) {
          clearTimeout(graceTimer);
        }
      }
    }
    if (deadlineTimer) {
      clearTimeout(deadlineTimer);
      deadlineTimer = null;
    }
  }
}

// Small backstop (ms) for the teardown steps ONLY when the overall deadline has
// already fired (so it can no longer bound them). Shared across both teardown
// steps, so the worst-case extra time after an expired deadline is a single
// CLEANUP_GRACE_MS, not one per step.
const CLEANUP_GRACE_MS = 1000;

/**
 * Run a cleanup step bounded by a shared cleanup deadline promise, swallowing any
 * error or timeout so cleanup can never hang the probe or surface a late failure.
 * Both teardown steps (`unsubscribeMessage`, `destroy`) race the SAME shared
 * deadline, so the whole teardown — not each step — is bounded (review finding #2).
 *
 * @param {() => Promise<unknown>} fn - The cleanup action to invoke.
 * @param {Promise<unknown>} cleanupDeadline - The shared cleanup-deadline promise.
 * @returns {Promise<void>}
 */
async function raceCleanup(fn, cleanupDeadline) {
  await Promise.race([
    Promise.resolve()
      .then(fn)
      .catch(() => {}),
    cleanupDeadline,
  ]);
}

/**
 * Default probe-unique callback id: a large random integer in the upper 32-bit
 * range, deliberately outside the controller's `callbackId` space (which starts
 * at 1 and wraps at 0xffffffff), so the host's reply is matched only by this
 * probe and never collides with a live controller callback.
 *
 * @returns {number} A probe-unique callback id.
 */
function defaultUniqueId() {
  // 0x40000000..0x7fffffff — large, positive, and practically never used by the
  // controller's sequential callbackId within a probe's short lifetime.
  return 0x40000000 + Math.floor(Math.random() * 0x3fffffff);
}

/**
 * Resolve the ioBroker config file path the way js-controller does (honoring the
 * data-dir env), with the image's documented default.
 *
 * @returns {string} Absolute path to `iobroker.json`.
 */
function resolveConfigPath() {
  if (process.env.IOB_JSON) {
    return process.env.IOB_JSON;
  }
  const dataDir =
    process.env.IOBROKER_DATA_DIR ||
    (process.env.IOB_ROOT
      ? path.join(process.env.IOB_ROOT, 'iobroker-data')
      : '/opt/iobroker/iobroker-data');
  return path.join(dataDir, 'iobroker.json');
}

/**
 * Resolve the host name with the SAME precedence as js-controller's `getHostName`
 * (common-db tools.ts ~1456): IOB_HOSTNAME → config.system.hostname → os.hostname().
 *
 * @param {object} config - The parsed `iobroker.json`.
 * @returns {string} The resolved host name.
 */
function resolveHostName(config) {
  if (process.env.IOB_HOSTNAME) {
    return process.env.IOB_HOSTNAME;
  }
  return config?.system?.hostname || os.hostname();
}

/**
 * Resolve the ioBroker install root, where `@iobroker/*` packages are installed.
 * In the shipped image that is `/opt/iobroker` (the node_modules VOLUME lives at
 * `/opt/iobroker/node_modules`), while THIS module lives separately under
 * `/opt/lib` — so a bare `import('@iobroker/db-states-*')` would resolve from
 * `/opt/lib`'s ancestry and miss the packages. We therefore resolve against the
 * install root explicitly. Overridable via `IOB_ROOT` (default `/opt/iobroker`).
 *
 * @returns {string} Absolute path to the ioBroker install root.
 */
function resolveIobRoot() {
  return process.env.IOB_ROOT || '/opt/iobroker';
}

/**
 * Build the REAL states-client factory for the CLI entry: it selects the client
 * package from the states DB type exactly like js-controller's
 * `getStatesConstructor` (common states.ts ~15:
 * `(await import('@iobroker/db-states-' + config.states.type)).Client`) and
 * constructs it with the connection config from `iobroker.json`.
 *
 * Package resolution (review fix #1): because this module ships under `/opt/lib`
 * while the `@iobroker/*` packages are installed under `<IOB_ROOT>/node_modules`
 * (`/opt/iobroker/node_modules`), a bare dynamic import would fail with
 * ERR_MODULE_NOT_FOUND in the image (Node resolves bare specifiers from the
 * importing module's directory ancestry, not from the sibling install tree, and
 * no NODE_PATH bridge is defined). We resolve the package file from the install
 * root with `createRequire(<IOB_ROOT>/package.json).resolve(pkg)` and import it
 * via a `file://` URL so the correct installed copy is always loaded.
 *
 * @param {object} statesConfig - The `states` section of `iobroker.json`.
 * @returns {(settings: object) => StatesClientLike} A states-client factory.
 */
async function buildRealClientFactory(statesConfig) {
  const packageName = `@iobroker/db-states-${statesConfig.type}`;
  const iobRoot = resolveIobRoot();
  // Anchor resolution at the install root's package.json so Node's resolver walks
  // <IOB_ROOT>/node_modules, where ioBroker and its DB clients actually live.
  const requireFromRoot = createRequire(path.join(iobRoot, 'package.json'));
  const resolvedPath = requireFromRoot.resolve(packageName);
  const mod = await import(pathToFileURL(resolvedPath).href);
  const Client = mod.Client;
  return (settings) =>
    new Client({
      ...settings,
      connection: statesConfig,
    });
}

/**
 * CLI entry: run the probe inside the container and print a single machine-readable
 * line (`messagebox-probe: outcome=<ok|failed|inconclusive>`) to stdout, exiting 0
 * regardless. The bash healthcheck layer reads the outcome, never the exit code,
 * so a crash here maps to `inconclusive` (never a messagebox failure).
 *
 * @returns {Promise<void>}
 */
async function main() {
  let outcome = ProbeOutcome.INCONCLUSIVE;
  let detail = '';
  try {
    const configPath = resolveConfigPath();
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const statesConfig = config.states;
    if (!statesConfig || !statesConfig.type) {
      detail = 'states config missing/type unset';
    } else {
      const hostName = resolveHostName(config);
      // Clamp the probe timeout to a sane range (1..15s, default 5) as a second,
      // independent bound (the shell already budgets the OUTER backstop against the
      // whole-healthcheck Docker --timeout; review finding #2). An out-of-range or
      // invalid value falls back to the 5s default rather than letting a large knob
      // make the whole healthcheck time out.
      const requested = Number(process.env.IOB_MESSAGEBOX_PROBE_TIMEOUT);
      const timeoutSeconds =
        Number.isFinite(requested) && requested >= 1 && requested <= 15 ? requested : 5;
      const createStatesClient = await buildRealClientFactory(statesConfig);
      const result = await probeMessagebox({
        createStatesClient,
        hostName,
        timeoutMs: timeoutSeconds * 1000,
      });
      outcome = result.outcome;
      detail = result.detail;
    }
  } catch (err) {
    // Any error (unreadable config, import failure, …) is inconclusive — never a
    // messagebox failure (see the module header's DB-down decision).
    outcome = ProbeOutcome.INCONCLUSIVE;
    detail = `cli error: ${err && err.message ? err.message : String(err)}`;
  }
  // Single, stable, parseable line for scripts/healthcheck.sh.
  process.stdout.write(
    `messagebox-probe: outcome=${outcome}${detail ? ` detail=${detail}` : ''}\n`,
  );
}

// Direct-CLI guard: only run when invoked as `node lib/messagebox-probe.js`.
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
