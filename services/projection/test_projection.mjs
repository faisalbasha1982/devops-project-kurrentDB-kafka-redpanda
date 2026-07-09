// Offline check of the projection fold logic (Phase 2c).
//
// KurrentDB runs the .js projections server-side, so we can't unit-test them in
// the DB cheaply. Instead this harness emulates just enough of the
// `fromAll().when()` engine to run the *real* handler files against a synthetic
// event log and assert the resulting read-model state — in particular the two
// load-bearing properties:
//   1. TradeSettled carries no symbol; it must still be attributed to the right
//      symbol via the `pending` map.
//   2. A redelivered TradeSettled must not double-count (idempotent fold).
//
// Run: node services/projection/test_projection.mjs
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

function runProjection(jsFile, events) {
  let handlers = null;
  const fromAll = () => ({ when: (h) => { handlers = h; } });
  const src = fs.readFileSync(path.join(HERE, jsFile), 'utf8');
  new Function('fromAll', src)(fromAll);
  const state = handlers.$init();
  for (const e of events) {
    const fn = handlers[e.eventType];
    if (fn) fn(state, { body: e.data });
  }
  return state;
}

function assert(cond, msg) {
  if (!cond) { console.error('FAIL:', msg); process.exit(1); }
}

const mk = (t, id, sym, extra = {}) =>
  ({ eventType: t, data: { trade_id: id, symbol: sym, ...extra } });

const log = [
  mk('TradeExecuted', 't1', 'BTC-USD', { qty: 0.5, price: 64000, side: 'buy' }),
  mk('TradeExecuted', 't2', 'ETH-USD', { qty: 2.0, price: 3400, side: 'sell' }),
  mk('TradeSettled', 't1', undefined, { quote_transfer_id: 'q', base_transfer_id: 'b' }),
  mk('TradeExecuted', 't3', 'BTC-USD', { qty: 0.1, price: 63000, side: 'buy' }),
  mk('TradeSettled', 't2', undefined, {}),
  mk('TradeSettled', 't1', undefined, {}),  // redelivered settle -> must be ignored
];

const status = runProjection('settlement_status.js', log);
const vol = runProjection('volume_by_instrument.js',
  log.filter((e) => e.eventType === 'TradeExecuted'));

const S = status.symbols;
assert(S['BTC-USD'].executed === 2, 'BTC executed == 2 (t1,t3)');
assert(S['BTC-USD'].settled === 1, 'BTC settled == 1 (t1; redelivered settle ignored)');
assert(S['ETH-USD'].executed === 1 && S['ETH-USD'].settled === 1, 'ETH 1/1');
assert(status.pending['t3'] === 'BTC-USD', 't3 remains unsettled in pending');
assert(status.pending['t1'] === undefined, 't1 cleared from pending after settle');
assert(Math.abs(vol.symbols['ETH-USD'].notional - 2.0 * 3400) < 1e-6, 'ETH notional');
assert(vol.symbols['BTC-USD'].fills === 2, 'BTC fills == 2');

console.log('projection fold OK:', JSON.stringify(status.symbols));
