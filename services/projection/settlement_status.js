// Aequor — settlement-status read model (Phase 2c)
//
// A CONTINUOUS KurrentDB projection: JavaScript that runs *inside* the database
// and folds the trade event log into a compact read model of settlement status
// per symbol. It maintains state only (emit disabled) — the projection service
// polls that state via get_projection_state() and exports it to Prometheus.
//
// State shape:
//   {
//     symbols: { "BTC-USD": { executed, settled }, "ETH-USD": {...} },
//     pending: { "<trade_id>": "<symbol>" }   // executed-but-not-yet-settled
//   }
//
// TradeSettled carries no symbol (its payload is transfer ids), so `pending`
// correlates a settle back to the symbol its TradeExecuted recorded. This keeps
// the projection self-contained — it needs no change to the settlement service —
// and `pending` stays bounded: it drains to ~0 as settlement catches up, exactly
// mirroring aequor_unsettled_trades.
//
// fromAll() sees every event, but the typed handlers only fire for our two event
// types, which exist solely in trade-<id> streams. No emit, no side effects.

fromAll().when({
    $init: function () {
        return { symbols: {}, pending: {} };
    },

    TradeExecuted: function (state, event) {
        var d = event.body || event.data;
        if (!d || !d.symbol || !d.trade_id) { return; }
        var s = state.symbols[d.symbol];
        if (!s) { s = { executed: 0, settled: 0 }; state.symbols[d.symbol] = s; }
        s.executed += 1;
        state.pending[d.trade_id] = d.symbol;
    },

    TradeSettled: function (state, event) {
        var d = event.body || event.data;
        if (!d || !d.trade_id) { return; }
        var sym = state.pending[d.trade_id];
        if (!sym) { return; }
        var s = state.symbols[sym];
        if (!s) { s = { executed: 0, settled: 0 }; state.symbols[sym] = s; }
        s.settled += 1;
        delete state.pending[d.trade_id];
    }
});
