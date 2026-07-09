// Aequor — per-instrument volume read model (Phase 2)
//
// A second continuous projection, to show that read models are cheap to add once
// the event log exists. It accumulates traded quantity and quote-notional per
// symbol straight from TradeExecuted, giving an operational view (throughput /
// turnover per instrument) without touching the ledger or the settlement path.
//
// State shape:
//   { symbols: { "BTC-USD": { fills, qty, notional }, ... } }
//     fills    = number of TradeExecuted events
//     qty      = sum of base quantity
//     notional = sum of qty * price (quote units, e.g. USD)

fromAll().when({
    $init: function () {
        return { symbols: {} };
    },

    TradeExecuted: function (state, event) {
        var d = event.body || event.data;
        if (!d || !d.symbol) { return; }
        var s = state.symbols[d.symbol];
        if (!s) { s = { fills: 0, qty: 0, notional: 0 }; state.symbols[d.symbol] = s; }
        var qty = Number(d.qty) || 0;
        var price = Number(d.price) || 0;
        s.fills += 1;
        s.qty += qty;
        s.notional += qty * price;
    }
});
