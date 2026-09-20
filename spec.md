# Architectural & Functional Specification: MQL5 VWAP Mean Reversion EA

## 1. System Overview & Tech Stack
- **Target Platform:** MetaTrader 5 (MT5)
- **Language / Standards:** Native MQL5 (Strict Object-Oriented C++ dialect, `#property strict`)
- **Target Asset:** NASDAQ 100 CFD (e.g., `US100`, `NAS100`, `USTEC`)
- **Execution Timeframe:** M5 (5 Minutes)
- **Execution Logic:**
  - **Signal Generation & Order Entry:** Strict Bar-Close evaluation on the very first tick of a newly formed M5 bar (Index 0). In-progress bar ticks are ignored for entry logic to eliminate repainting.
  - **Trade Management (Break-Even & Exits):** Tick-by-tick evaluation inside the main tick event loop.
- **Trade Execution Architecture:** Native standard library trade classes (`#include <Trade\Trade.mqh>`).

---

## 2. Session & Temporal Synchronization Engine

### Operational Window (Italian Local Time CET / CEST)
- **Trigger Window Open:** 15:30 Italian Time (coinciding with the US Cash Equity Open).
- **Trigger Window Close:** 22:00 Italian Time (end of cash session; no new positions can be initiated).
- **Time Conversion Requirement:** The EA must translate MT5 Broker Server Time into Italian Local Time using explicit, configurable GMT offset inputs (Broker Offset and Italian Offset) to dynamically handle daylight saving transitions.

### VWAP Anchor / Reset Rule
- **Reset Frequency:** Daily Anchor (strictly matching TradingView `timeframe.change("D")` parity).
- **Reset Trigger:** The VWAP cumulative accumulators reset strictly at `00:00` of the server trading day.
- **Structural Purpose:** By the time the trading session reaches 15:30 Italian Time, the VWAP and standard deviation bands will have already accumulated the trading volume of both the Asian and European sessions, establishing stable baseline statistical boundaries.

---

## 3. Mathematical Indicator Engine (TradingView Parity)

The calculation engine must operate via a single-pass cumulative algorithm over closed bars starting from the midnight reset bar of the active day, using the broker's tick volume.

### TradingView Parameter Parity

| Parameter | Value | Note |
|---|---|---|
| **Source** | `Open` (`iOpen`) | **NOT** `hlc3` (Typical Price) |
| **Anchor** | Session / Daily | Reset at `00:00` server time (`timeframe.change("D")`) |
| **Offset** | 0 | No bar displacement |
| **Bands Calc Mode** | Standard Deviation | Volume-weighted cumulative StdDev |
| **Band #1** | Active, multiplier = **1.5** | Only active band |
| **Band #2** | Inactive | — |
| **Band #3** | Inactive | — |
| **Timeframe** | Chart (M5) | — |
| **Wait for TF close** | `true` | VWAP/Band values for entry triggers must come from fully closed bars only (`barIndex ≥ 1`) |

### Mathematical Formulation
1. **Price Source ($P$):**
   $$P_i = \text{Open}_i$$

2. **Accumulators (from session midnight bar up to index $i$):**
   - Cumulative Volume ($\text{CumVol}$) = $\sum (\text{Volume}_i)$
   - Cumulative Price × Volume ($\text{CumPV}$) = $\sum (P_i \times \text{Volume}_i)$
   - Cumulative Price² × Volume ($\text{CumP2V}$) = $\sum (P_i^2 \times \text{Volume}_i)$

3. **VWAP & Bands ($k = 1.5$):**
   - $\text{VWAP} = \frac{\text{CumPV}}{\text{CumVol}}$
   - $\text{Variance} = \frac{\text{CumP2V}}{\text{CumVol}} - \text{VWAP}^2$
   - $\text{Standard Deviation (StdDev)} = \sqrt{\max(0.0, \text{Variance})}$
   - $\text{Upper Band} = \text{VWAP} + (1.5 \times \text{StdDev})$
   - $\text{Lower Band} = \text{VWAP} - (1.5 \times \text{StdDev})$

---

## 4. Entry & Exit Strategy Rules

All conditions are evaluated on closed bars: `Bar 1` (just closed) and `Bar 2` (preceding closed bar).

> [!NOTE]
> **Pre-Session Breakout Parity:**
> If the price is already outside the VWAP bands when the session opens at 15:30 Italian Time (e.g. breakout happened in Asian/European session or pre-market), there is NO requirement to wait for price to re-enter and break out again during the session. As soon as the price re-enters the band on a closed bar within the active session, the entry signal is immediately triggered.

### Long Setup (Mean Reversion from Lower Band)
1. **Breakout / Outside Condition:** `Bar 2` close is strictly below Lower Band (`Close[2] < LowerBand[2]`).
2. **Re-entry Condition:** `Bar 1` close is strictly above Lower Band (`Close[1] > LowerBand[1]`).
3. **Execution:** Instant Market BUY at current `Ask` at the open of `Bar 0`.
4. **Structural Stop Loss (SL):** Minimum between `Low[1]` and `Low[2]`, minus a small safety buffer (configurable points/spread).
5. **Take Profit (TP):** Fixed 1:2 Risk-to-Reward ratio:
   $$\text{TP} = \text{EntryPrice} + 2.0 \times (\text{EntryPrice} - \text{SL})$$

### Short Setup (Mean Reversion from Upper Band)
1. **Breakout Condition:** `Bar 2` close is strictly above Upper Band (`Close[2] > UpperBand[2]`).
2. **Re-entry Condition:** `Bar 1` close is strictly below Upper Band (`Close[1] < UpperBand[1]`).
3. **Execution:** Instant Market SELL at current `Bid` at the open of `Bar 0`.
4. **Structural Stop Loss (SL):** Maximum between `High[1]` and `High[2]`, plus a small safety buffer (configurable points/spread).
5. **Take Profit (TP):** Fixed 1:2 Risk-to-Reward ratio:
   $$\text{TP} = \text{EntryPrice} - 2.0 \times (\text{SL} - \text{EntryPrice})$$

---

## 5. Lifecycle, State Machine & Money Management

### A. Break-Even (BE) Management
- Evaluated on every tick inside the main tick event loop.
- Trigger threshold: When floating favorable price movement reaches a 1:1 Risk-to-Reward ratio:
  - For Longs: Current Bid reaches or exceeds $\text{EntryPrice} + (\text{EntryPrice} - \text{InitialSL})$.
  - For Shorts: Current Ask reaches or drops below $\text{EntryPrice} - (\text{InitialSL} - \text{EntryPrice})$.
- Action: Call position modification to adjust the Stop Loss to the original entry price plus a protective spread buffer.
- Safety / Latch: The modification must be protected by an idempotency check so that the modification call is issued only once per open trade.

### B. Daily Frequency Limiter
- Maximum limit: Strictly **1 trade executed per calendar day**.
- State Tracking:
  - Reset a daily trade latch to `false` when a new daily session begins.
  - Set the latch to `true` as soon as an order is executed and confirmed by the broker.
  - New entry evaluations must be bypassed if the latch is active or if any position is currently open.

### C. Dynamic Position Sizing (Risk-Based Allocation)
The lot size is computed dynamically on the fly before dispatching the order:
- Risk Capital = $\text{Account Balance} \times \left(\frac{\text{RiskPercent}}{100.0}\right)$
- Point Distance = $\vert{}\text{EntryPrice} - \text{SL}\vert{}$
- Formula:
  $$\text{Raw Lots} = \frac{\text{Risk Capital}}{\left(\frac{\text{Point Distance}}{\text{Point Value}}\right) \times \text{Tick Value}}$$
- Validation & Normalization Rules:
  - Must round down to the nearest allowed volume step (`SYMBOL_VOLUME_STEP`).
  - Must verify that the normalized lot is between `SYMBOL_VOLUME_MIN` and `SYMBOL_VOLUME_MAX`.
  - If the computed lot is less than `SYMBOL_VOLUME_MIN`, abort order dispatch and print a diagnostic warning to the terminal logs.

### D. Session End Hard Close (EOD Exit Rule)
- **Rule:** No position shall remain open overnight beyond the allowed session window.
- **Hard Close Time:** At **22:00 Italian Time** (or the time defined by `InpSessionEndHour` / `InpSessionEndMin`), any open position generated by this EA (`InpMagicNumber`) must be liquidated at market.
- **Operational Logic in `OnTick()`:**
  1. Convert the current server time to Italian local time.
  2. Check if the current time has reached or exceeded the session end (`currentMinutesOfDay >= endMinutesOfDay`).
  3. If an open position exists for the current symbol with the EA's `MagicNumber`:
     - Execute immediate market close via `CTrade::PositionClose()`.
     - Log to terminal: `"[EOD] Forced close – session end reached."`.
     - Delete associated chart objects (SL/TP rectangles).
- **Daily Trade Latch:** The forced close keeps `m_tradeTakenToday = true`, preventing any new trade until the next day.

---

## 6. Implementation & Safety Requirements

1. **New Bar Detection:** Implement a dedicated bar-detection utility tracking bar open times to ensure zero mid-candle logic executions.
2. **Hard SL/TP Enforcement:** Stop Loss and Take Profit levels must be passed as native arguments in the initial trade request so that the risk levels reside directly on the broker's servers.
3. **Magic Number Isolation:** All generated trade orders and positions must be tagged with a distinct integer Magic Number to prevent interference with other automated or manual orders on the account.
4. **Defensive Error Handling:** Every order placement and modification attempt must check broker return codes, logging descriptive error messages if rejected.
5. **Compilation Quality:** The implementation must achieve zero errors and zero compiler warnings under MT5 strict mode.

---

## 7. Chart GUI & Visual Elements

Implement an internal UI rendering subsystem directly in the main file. All objects use the prefix `"VWAP_"` for cleanup isolation.

### A. Strategy Rules Panel (On-Chart Reference Card)
Display a persistent semi-transparent panel on the chart summarizing the core strategy rules:

| Line | Content |
|---|---|
| Title | **VWAP Mean Reversion – NAS100 M5** |
| Rule 1 | `VWAP: Source=Open, Anchor=Session, Band=±1.5σ` |
| Rule 2 | `LONG: Close[2] < LowerBand[2] AND Close[1] > LowerBand[1]` |
| Rule 3 | `SHORT: Close[2] > UpperBand[2] AND Close[1] < UpperBand[1]` |
| Rule 4 | `SL: min(Low[1],Low[2]) / max(High[1],High[2])` |
| Rule 5 | `TP: 2:1 Risk-Reward` |
| Rule 6 | `BE: SL → Entry at 1:1 RR` |
| Rule 7 | `Session: 15:30–22:00 IT | Max 1 trade/day` |
| Rule 8 | `EOD: Hard close at session end` |

- Anchored to `CORNER_RIGHT_UPPER`, rendered as `OBJ_LABEL` objects.
- Semi-transparent background via `OBJ_RECTANGLE_LABEL`.
- Font: `"Consolas"` or `"Courier New"`, size 8–9.

### B. Position Box Visualization (TradingView Long/Short Tool style)
- On order confirmation, instantiate two `OBJ_RECTANGLE` objects:
  - **TP Box:** Bounded by `[EntryTime, EntryPrice]` → `[EntryTime + 3 hours, TakeProfit]`. Color: Semi-transparent Green (`C'0,180,80'`), filled, background.
  - **SL Box:** Bounded by `[EntryTime, EntryPrice]` → `[EntryTime + 3 hours, StopLoss]`. Color: Semi-transparent Red (`C'220,50,50'`), filled, background.
- If Break-Even triggers, update the SL rectangle boundary to match the new SL level.
- On position exit (SL/TP hit or EOD close), delete both rectangle objects.

### C. Heads-Up Dashboard (HUD)
- Anchor lightweight text labels (`OBJ_LABEL`) to `CORNER_LEFT_UPPER`.
- Display:
  - `Strategy Name`: "VWAP-MR-NQ5"
  - `Session Status`: "ACTIVE (NY Session)" or "WAITING (Opens 15:30 IT)"
  - `Daily Trade Latch`: "0 / 1 (Ready)" or "1 / 1 (Max Reached)"
  - `Upper Band / VWAP / Lower Band`: Real-time computed values

### D. Cleanup Enforcement
- Implement complete cleanup inside `OnDeinit(const int reason)` to remove all created UI objects with the prefix (`ObjectsDeleteAll(0, "VWAP_")`) when the EA is removed from the chart.
