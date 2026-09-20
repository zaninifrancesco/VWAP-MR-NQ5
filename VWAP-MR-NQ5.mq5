//+------------------------------------------------------------------+
//|                                                  VWAP-MR-NQ5.mq5 |
//|                                                 Francesco Zanini  |
//|                         VWAP Mean Reversion EA – NAS100 CFD (M5)  |
//+------------------------------------------------------------------+
#property copyright "Francesco Zanini"
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict
#property description "VWAP Mean Reversion Strategy for NAS100 CFD on M5"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//|                         INPUT PARAMETERS                          |
//+------------------------------------------------------------------+
input group "=== Session Settings ==="
input int    InpBrokerGMTOffset  = 3;      // Broker Server GMT Offset
input int    InpItalianGMTOffset = 2;      // Italian GMT Offset (2=CEST, 1=CET)
input int    InpSessionStartHour = 15;     // Session Start Hour (Italian Time)
input int    InpSessionStartMin  = 30;     // Session Start Minute
input int    InpSessionEndHour   = 22;     // Session End Hour (Italian Time)
input int    InpSessionEndMin    = 0;      // Session End Minute

input group "=== Risk Management ==="
input double InpRiskPercent      = 1.0;    // Risk Per Trade (%)
input int    InpMagicNumber      = 100001; // EA Magic Number

//+------------------------------------------------------------------+
//|                         CONSTANTS                                 |
//+------------------------------------------------------------------+
#define PREFIX       "VWAP_"             // Object name prefix for cleanup
#define BOX_HOURS    3                   // Width of TP/SL rectangles (hours)

//+------------------------------------------------------------------+
//|                         GLOBAL STATE                              |
//+------------------------------------------------------------------+
CTrade   m_trade;                          // Trade execution object

//--- New bar detection
datetime m_lastBarTime      = 0;

//--- Daily trade limiter
bool     m_tradeTakenToday  = false;
datetime m_currentDayD1     = 0;          // D1 bar open time – daily anchor (Bug 2 fix)

//--- Position tracking & break-even
bool     m_breakEvenDone    = false;
double   m_entryPrice       = 0.0;
double   m_initialSL        = 0.0;
double   m_initialTP        = 0.0;
ulong    m_posTicket        = 0;
datetime m_entryTime        = 0;

//--- VWAP snapshots at Bar[1] and Bar[2]
double   m_vwap1  = 0.0, m_upper1 = 0.0, m_lower1 = 0.0;
double   m_vwap2  = 0.0, m_upper2 = 0.0, m_lower2 = 0.0;


//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Configure trade object
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(10);
   m_trade.SetTypeFilling(DetectFillingMode());

   //--- Bug 2 fix: anchor daily reset on D1 bar open (same source as VWAP)
   m_currentDayD1 = iTime(_Symbol, PERIOD_D1, 0);

   //--- Recover state if a position from this EA is already open
   bool positionOpen = FindOwnPosition();
   if(positionOpen)
   {
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(MathAbs(m_initialSL - m_entryPrice) < tickSize * 2.0)
         m_breakEvenDone = true;
   }

   //--- Bug 3 fix: check deal history for a trade today.
   //    Fallback: if a position is already open (e.g. backtesting init with empty history),
   //    mark as traded regardless — prevents a double-entry on restart.
   m_tradeTakenToday = HasTradedToday();
   if(!m_tradeTakenToday && positionOpen)
   {
      m_tradeTakenToday = true;
      Print("[INIT] Position found but no history deal detected – setting tradeTakenToday=true as fallback.");
   }

   //--- Draw persistent UI elements
   DrawRulesPanel();
   DrawHUD();

   PrintFormat("VWAP-MR-NQ5 v1.11 | Magic %d | Risk %.1f%% | Broker GMT+%d | IT GMT+%d | D1=%s",
               InpMagicNumber, InpRiskPercent, InpBrokerGMTOffset, InpItalianGMTOffset,
               TimeToString(m_currentDayD1));

   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Remove all chart objects with our prefix
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw(0);
   PrintFormat("VWAP-MR-NQ5 removed. Reason=%d", reason);
}


//+------------------------------------------------------------------+
//| Expert tick function – Main event loop                            |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) Detect position closed by SL/TP (Bug 1 fix) ───────────
   //    If we tracked a ticket but FindOwnPosition() no longer finds it,
   //    the position was closed by SL/TP or broker — clean up immediately.
   bool hasPosition = FindOwnPosition();
   if(!hasPosition && m_posTicket != 0)
   {
      PrintFormat("[CLOSED] Position #%d closed by SL/TP/broker.", m_posTicket);
      DeletePositionBoxes();
      m_breakEvenDone = false;
      m_entryPrice    = 0.0;
      m_initialSL     = 0.0;
      m_initialTP     = 0.0;
      m_posTicket     = 0;
      m_entryTime     = 0;
   }

   //--- 2) EOD Hard Close check (every tick) ─────────────────────
   if(hasPosition && IsPastSessionEnd())
   {
      ForceClosePosition();
      return;
   }

   //--- 3) Break-even management (every tick) ────────────────────
   if(hasPosition && !m_breakEvenDone)
      ManageBreakEven();

   //--- 4) Update HUD (every tick when position open or on new bar)
   bool newBar = IsNewBar();
   if(hasPosition || newBar)
      UpdateHUD();

   //--- 5) Entry logic runs ONLY on the first tick of a new M5 bar
   if(!newBar)
      return;

   //--- 6) Daily reset (new calendar day → allow new trade)
   CheckDailyReset();

   //--- 7) Guard: already traded today?
   if(m_tradeTakenToday)
      return;

   //--- 8) Guard: position still open?
   if(FindOwnPosition())
      return;

   //--- 9) Guard: within operational session window?
   if(!IsInSession())
      return;

   //--- 10) Calculate VWAP from daily anchor to Bar[1] / Bar[2]
   if(!CalculateVWAP())
      return;

   //--- 11) Evaluate entry signal and execute if valid
   EvaluateEntry();
}


//+------------------------------------------------------------------+
//|                    SESSION & TIME UTILITIES                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| New Bar Detection (M5)                                            |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == 0 || t == m_lastBarTime)
      return false;

   m_lastBarTime = t;
   return true;
}


//+------------------------------------------------------------------+
//| Daily Reset – resets the trade latch when D1 bar changes         |
//| Anchored on iTime(D1,0) – same source as the VWAP engine.        |
//| This avoids any TZ drift between Italian time and broker time.   |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   //--- Use the D1 bar open time as the canonical "new day" signal.
   //    This is exactly what the VWAP engine uses as its anchor,
   //    so both the latch and the VWAP stay in perfect sync.
   datetime d1Open = iTime(_Symbol, PERIOD_D1, 0);
   if(d1Open == 0 || d1Open == m_currentDayD1)
      return;

   m_currentDayD1    = d1Open;
   m_tradeTakenToday = false;

   //--- Clear position tracking only when no position is held over
   if(!FindOwnPosition())
   {
      m_breakEvenDone = false;
      m_entryPrice    = 0.0;
      m_initialSL     = 0.0;
      m_initialTP     = 0.0;
      m_posTicket     = 0;
      m_entryTime     = 0;
   }

   MqlDateTime dt;
   TimeToStruct(d1Open, dt);
   PrintFormat("=== New trading day %d.%02d.%02d (D1 anchor: %s) ===",
               dt.year, dt.mon, dt.day, TimeToString(d1Open));
}


//+------------------------------------------------------------------+
//| Get current Italian time in minutes-of-day                        |
//+------------------------------------------------------------------+
int GetItalianMinutes()
{
   int offsetSec       = (InpItalianGMTOffset - InpBrokerGMTOffset) * 3600;
   datetime italianTime = TimeCurrent() + offsetSec;

   MqlDateTime dt;
   TimeToStruct(italianTime, dt);

   return dt.hour * 60 + dt.min;
}


//+------------------------------------------------------------------+
//| Session Window Check (entry allowed?)                             |
//+------------------------------------------------------------------+
bool IsInSession()
{
   int nowMin   = GetItalianMinutes();
   int startMin = InpSessionStartHour * 60 + InpSessionStartMin;
   int endMin   = InpSessionEndHour   * 60 + InpSessionEndMin;

   return (nowMin >= startMin && nowMin < endMin);
}


//+------------------------------------------------------------------+
//| Check if we are past the session end (for EOD close)              |
//+------------------------------------------------------------------+
bool IsPastSessionEnd()
{
   int nowMin = GetItalianMinutes();
   int endMin = InpSessionEndHour * 60 + InpSessionEndMin;

   return (nowMin >= endMin);
}


//+------------------------------------------------------------------+
//|              VWAP CALCULATION ENGINE                              |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Single-pass cumulative VWAP from daily anchor                     |
//| Source = Open  |  k = 1.5  |  Anchor = D1 bar start              |
//| Saves snapshots at Bar[2] and Bar[1] for signal evaluation        |
//+------------------------------------------------------------------+
bool CalculateVWAP()
{
   //--- Anchor: start of the current D1 bar
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return false;

   //--- Find the corresponding M5 bar index
   int startBar = iBarShift(_Symbol, PERIOD_M5, dayStart, false);
   if(startBar < 0)
      return false;

   //--- Ensure the start bar belongs to the current day
   if(iTime(_Symbol, PERIOD_M5, startBar) < dayStart)
   {
      startBar--;
      if(startBar < 0)
         return false;
   }

   //--- Need at least bars [2] and [1] from today
   if(startBar < 2)
      return false;

   //--- Accumulators
   double cumVol = 0.0, cumPV = 0.0, cumP2V = 0.0;

   //--- Reset snapshots
   m_vwap1 = m_upper1 = m_lower1 = 0.0;
   m_vwap2 = m_upper2 = m_lower2 = 0.0;

   //--- Iterate from oldest bar of today → newest closed bar (index 1)
   for(int i = startBar; i >= 1; i--)
   {
      double p = iOpen(_Symbol, PERIOD_M5, i);
      double v = (double)iVolume(_Symbol, PERIOD_M5, i);

      cumVol += v;
      cumPV  += p * v;
      cumP2V += p * p * v;

      //--- Snapshot at Bar[2]
      if(i == 2 && cumVol > 0.0)
      {
         m_vwap2  = cumPV / cumVol;
         double variance = (cumP2V / cumVol) - m_vwap2 * m_vwap2;
         double stdev    = MathSqrt(MathMax(0.0, variance));
         m_upper2 = m_vwap2 + 1.5 * stdev;
         m_lower2 = m_vwap2 - 1.5 * stdev;
      }

      //--- Snapshot at Bar[1]
      if(i == 1 && cumVol > 0.0)
      {
         m_vwap1  = cumPV / cumVol;
         double variance = (cumP2V / cumVol) - m_vwap1 * m_vwap1;
         double stdev    = MathSqrt(MathMax(0.0, variance));
         m_upper1 = m_vwap1 + 1.5 * stdev;
         m_lower1 = m_vwap1 - 1.5 * stdev;
      }
   }

   return (m_vwap1 > 0.0 && m_vwap2 > 0.0);
}


//+------------------------------------------------------------------+
//|              ENTRY SIGNAL EVALUATION                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Evaluate mean-reversion entry on closed bars [1] and [2]          |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   double close2 = iClose(_Symbol, PERIOD_M5, 2);

   //--- LONG: Mean Reversion from Lower Band ──────────────────────
   if(close2 < m_lower2 && close1 > m_lower1)
   {
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl   = MathMin(iLow(_Symbol, PERIOD_M5, 1), iLow(_Symbol, PERIOD_M5, 2));
      double risk = ask - sl;

      if(risk <= 0.0)
      {
         PrintFormat("Long skipped: SL(%.2f) >= Ask(%.2f)", sl, ask);
         return;
      }

      double tp = ask + 2.0 * risk;
      ExecuteTrade(ORDER_TYPE_BUY, sl, tp, risk);
      return;
   }

   //--- SHORT: Mean Reversion from Upper Band ─────────────────────
   if(close2 > m_upper2 && close1 < m_upper1)
   {
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl   = MathMax(iHigh(_Symbol, PERIOD_M5, 1), iHigh(_Symbol, PERIOD_M5, 2));
      double risk = sl - bid;

      if(risk <= 0.0)
      {
         PrintFormat("Short skipped: SL(%.2f) <= Bid(%.2f)", sl, bid);
         return;
      }

      double tp = bid - 2.0 * risk;
      ExecuteTrade(ORDER_TYPE_SELL, sl, tp, risk);
      return;
   }
}


//+------------------------------------------------------------------+
//|              TRADE EXECUTION                                     |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Execute market order with hard SL/TP and dynamic lot sizing       |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double sl, double tp, double riskDist)
{
   //--- Compute lot size
   double lots = CalcLotSize(riskDist);
   if(lots <= 0.0)
      return;

   //--- Normalize SL/TP to tick size grid
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   sl = MathRound(sl / ts) * ts;
   tp = MathRound(tp / ts) * ts;

   //--- Dispatch order
   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = m_trade.Buy(lots, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, "VWAP-MR");
   else
      ok = m_trade.Sell(lots, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, "VWAP-MR");

   //--- Process result
   if(ok && m_trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      m_tradeTakenToday = true;
      m_breakEvenDone   = false;
      m_entryPrice      = m_trade.ResultPrice();
      m_initialSL       = sl;
      m_initialTP       = tp;
      m_entryTime       = TimeCurrent();

      //--- Draw position boxes on chart
      DrawPositionBoxes(m_entryPrice, sl, tp, m_entryTime);

      PrintFormat("[TRADE] %s %.2f lots @ %.2f | SL=%.2f  TP=%.2f | Risk=%.1f pts",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lots, m_entryPrice, sl, tp, riskDist);
   }
   else
   {
      PrintFormat("[ERROR] Order rejected: code=%d  %s",
                  m_trade.ResultRetcode(), m_trade.ResultComment());
   }
}


//+------------------------------------------------------------------+
//| Dynamic position sizing – risk-based allocation                   |
//+------------------------------------------------------------------+
double CalcLotSize(double riskDist)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskCap   = balance * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
   {
      Print("[ERROR] Invalid SYMBOL_TRADE_TICK_SIZE or SYMBOL_TRADE_TICK_VALUE");
      return 0.0;
   }

   double rawLots = riskCap / ((riskDist / tickSize) * tickValue);

   //--- Normalize: floor to nearest volume step
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = MathFloor(rawLots / step) * step;
   lots = MathMin(lots, maxLot);

   if(lots < minLot)
   {
      PrintFormat("[WARNING] Lot=%.4f < min=%.4f. Order aborted. "
                  "Balance=%.2f  RiskCap=%.2f  RiskDist=%.2f",
                  lots, minLot, balance, riskCap, riskDist);
      return 0.0;
   }

   return lots;
}


//+------------------------------------------------------------------+
//|              BREAK-EVEN MANAGEMENT                               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Move SL to entry price when price reaches 1:1 RR (tick-by-tick)   |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(m_posTicket == 0 || m_entryPrice == 0.0 || m_initialSL == 0.0)
      return;

   if(!PositionSelectByTicket(m_posTicket))
      return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double riskDist = MathAbs(m_entryPrice - m_initialSL);
   if(riskDist <= 0.0)
      return;

   //--- Check if price has reached the 1:1 RR threshold
   bool trigger = false;
   if(posType == POSITION_TYPE_BUY)
      trigger = (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= m_entryPrice + riskDist);
   else
      trigger = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= m_entryPrice - riskDist);

   if(!trigger)
      return;

   //--- Move SL to entry price
   double newSL = m_entryPrice;
   double ts    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   newSL = MathRound(newSL / ts) * ts;

   double currentTP = PositionGetDouble(POSITION_TP);

   if(m_trade.PositionModify(m_posTicket, newSL, currentTP))
   {
      m_breakEvenDone = true;
      //--- Update SL box on chart
      UpdateSLBox(newSL);
      PrintFormat("[BE] Break-even applied: SL moved to %.2f", newSL);
   }
   else
   {
      PrintFormat("[BE ERROR] Modify failed: code=%d  %s",
                  m_trade.ResultRetcode(), m_trade.ResultComment());
   }
}


//+------------------------------------------------------------------+
//|              EOD HARD CLOSE                                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Force-close any open position at session end                      |
//+------------------------------------------------------------------+
void ForceClosePosition()
{
   if(m_posTicket == 0)
      return;

   if(m_trade.PositionClose(m_posTicket))
   {
      PrintFormat("[EOD] Forced close – session end reached. Ticket=%d", m_posTicket);

      //--- Remove position boxes
      DeletePositionBoxes();

      //--- Reset tracking but keep daily latch active
      m_breakEvenDone = false;
      m_entryPrice    = 0.0;
      m_initialSL     = 0.0;
      m_initialTP     = 0.0;
      m_posTicket     = 0;
      m_entryTime     = 0;
      // m_tradeTakenToday stays true → no more trades today
   }
   else
   {
      PrintFormat("[EOD ERROR] Close failed: code=%d  %s",
                  m_trade.ResultRetcode(), m_trade.ResultComment());
   }
}


//+------------------------------------------------------------------+
//|              POSITION & HISTORY HELPERS                          |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Find our open position by Magic Number + Symbol                   |
//+------------------------------------------------------------------+
bool FindOwnPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL)  == _Symbol)
      {
         m_posTicket = ticket;

         //--- Recover tracking state (e.g. after EA restart)
         if(m_entryPrice == 0.0)
         {
            m_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            m_initialSL  = PositionGetDouble(POSITION_SL);
            m_initialTP  = PositionGetDouble(POSITION_TP);
            m_entryTime  = (datetime)PositionGetInteger(POSITION_TIME);
         }
         return true;
      }
   }
   return false;
}


//+------------------------------------------------------------------+
//| Scan today's deal history for an entry from this EA               |
//+------------------------------------------------------------------+
bool HasTradedToday()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime midnight = StructToTime(dt);

   if(!HistorySelect(midnight, TimeCurrent()))
      return false;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber &&
         HistoryDealGetString(ticket, DEAL_SYMBOL)  == _Symbol      &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY)  == DEAL_ENTRY_IN)
      {
         return true;
      }
   }

   return false;
}


//+------------------------------------------------------------------+
//| Auto-detect broker-supported order filling mode                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}


//+------------------------------------------------------------------+
//|              CHART GUI – VISUAL ELEMENTS                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Draw Strategy Rules Panel (top-right corner)                      |
//+------------------------------------------------------------------+
void DrawRulesPanel()
{
   string lines[] =
   {
      "VWAP Mean Reversion - NAS100 M5",
      "--------------------------------",
      "VWAP: Src=Open  Anchor=Session  Band=+/-1.5s",
      "LONG:  C[2]<LB[2] AND C[1]>LB[1]",
      "SHORT: C[2]>UB[2] AND C[1]<UB[1]",
      "SL: min(L1,L2) / max(H1,H2)",
      "TP: 2:1 Risk-Reward",
      "BE: SL->Entry at 1:1 RR",
      "Session: 15:30-22:00 IT | 1 trade/day",
      "EOD: Hard close at session end"
   };

   int totalLines = ArraySize(lines);
   int fontSize   = 8;
   int lineHeight = 14;
   int panelW     = 280;
   int panelH     = totalLines * lineHeight + 16;
   int panelX     = 10;
   int panelY     = 20;

   //--- Background panel
   string bgName = PREFIX + "RulesBG";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE,     panelW);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE,     panelH);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR,   C'20,20,30');
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, C'60,60,80');
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, bgName, OBJPROP_HIDDEN,      true);

   //--- Text lines
   for(int i = 0; i < totalLines; i++)
   {
      string name = PREFIX + "Rule" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, panelX + panelW - 8);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, panelY + 8 + i * lineHeight);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,    ANCHOR_RIGHT_UPPER);
      ObjectSetString(0, name, OBJPROP_TEXT,       lines[i]);
      ObjectSetString(0, name, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     (i == 0) ? C'100,200,255' : C'180,180,200');
      ObjectSetInteger(0, name, OBJPROP_BACK,      false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   }
}


//+------------------------------------------------------------------+
//| Draw HUD dashboard (top-left corner)                              |
//+------------------------------------------------------------------+
void DrawHUD()
{
   string labels[] =
   {
      "VWAP-MR-NQ5",
      "Session: ---",
      "Trade: 0 / 1 (Ready)",
      "Upper:  ---",
      "VWAP:   ---",
      "Lower:  ---"
   };

   int totalLabels = ArraySize(labels);
   int fontSize    = 9;
   int lineHeight  = 16;
   int panelW      = 220;
   int panelH      = totalLabels * lineHeight + 16;
   int panelX      = 10;
   int panelY      = 20;

   //--- Background
   string bgName = PREFIX + "HudBG";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE,     panelW);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE,     panelH);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR,   C'20,20,30');
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, C'60,60,80');
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, bgName, OBJPROP_HIDDEN,      true);

   //--- Text labels
   for(int i = 0; i < totalLabels; i++)
   {
      string name = PREFIX + "Hud" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, panelX + 8);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, panelY + 8 + i * lineHeight);
      ObjectSetString(0, name, OBJPROP_TEXT,       labels[i]);
      ObjectSetString(0, name, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     (i == 0) ? C'100,200,255' : C'180,180,200');
      ObjectSetInteger(0, name, OBJPROP_BACK,      false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   }
}


//+------------------------------------------------------------------+
//| Update HUD with live values                                       |
//+------------------------------------------------------------------+
void UpdateHUD()
{
   //--- Session status
   string sessionText;
   if(IsPastSessionEnd())
      sessionText = "CLOSED (Post 22:00 IT)";
   else if(IsInSession())
      sessionText = "ACTIVE (NY Session)";
   else
      sessionText = StringFormat("WAITING (Opens %02d:%02d IT)", InpSessionStartHour, InpSessionStartMin);

   ObjectSetString(0, PREFIX + "Hud1", OBJPROP_TEXT, "Session: " + sessionText);
   ObjectSetInteger(0, PREFIX + "Hud1", OBJPROP_COLOR,
                    IsInSession() ? C'0,200,100' : C'200,200,80');

   //--- Daily trade latch
   string tradeText;
   if(m_tradeTakenToday)
      tradeText = "Trade: 1 / 1 (Max Reached)";
   else
      tradeText = "Trade: 0 / 1 (Ready)";

   ObjectSetString(0, PREFIX + "Hud2", OBJPROP_TEXT, tradeText);
   ObjectSetInteger(0, PREFIX + "Hud2", OBJPROP_COLOR,
                    m_tradeTakenToday ? C'220,100,60' : C'0,200,100');

   //--- VWAP values (use Bar[1] snapshot if available)
   if(m_upper1 > 0.0)
   {
      ObjectSetString(0, PREFIX + "Hud3", OBJPROP_TEXT, StringFormat("Upper:  %.2f", m_upper1));
      ObjectSetString(0, PREFIX + "Hud4", OBJPROP_TEXT, StringFormat("VWAP:   %.2f", m_vwap1));
      ObjectSetString(0, PREFIX + "Hud5", OBJPROP_TEXT, StringFormat("Lower:  %.2f", m_lower1));
      ObjectSetInteger(0, PREFIX + "Hud3", OBJPROP_COLOR, C'220,80,80');
      ObjectSetInteger(0, PREFIX + "Hud4", OBJPROP_COLOR, C'100,200,255');
      ObjectSetInteger(0, PREFIX + "Hud5", OBJPROP_COLOR, C'80,200,80');
   }
   else
   {
      ObjectSetString(0, PREFIX + "Hud3", OBJPROP_TEXT, "Upper:  ---");
      ObjectSetString(0, PREFIX + "Hud4", OBJPROP_TEXT, "VWAP:   ---");
      ObjectSetString(0, PREFIX + "Hud5", OBJPROP_TEXT, "Lower:  ---");
   }

   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| Draw TP/SL position rectangles (TradingView style)                |
//+------------------------------------------------------------------+
void DrawPositionBoxes(double entry, double sl, double tp, datetime entryT)
{
   datetime endTime = entryT + BOX_HOURS * 3600;

   //--- TP Box (green)
   string tpName = PREFIX + "TP_Box";
   ObjectCreate(0, tpName, OBJ_RECTANGLE, 0, entryT, entry, endTime, tp);
   ObjectSetInteger(0, tpName, OBJPROP_COLOR,     C'0,180,80');
   ObjectSetInteger(0, tpName, OBJPROP_FILL,      true);
   ObjectSetInteger(0, tpName, OBJPROP_BACK,      true);
   ObjectSetInteger(0, tpName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, tpName, OBJPROP_HIDDEN,     true);

   //--- SL Box (red)
   string slName = PREFIX + "SL_Box";
   ObjectCreate(0, slName, OBJ_RECTANGLE, 0, entryT, entry, endTime, sl);
   ObjectSetInteger(0, slName, OBJPROP_COLOR,     C'220,50,50');
   ObjectSetInteger(0, slName, OBJPROP_FILL,      true);
   ObjectSetInteger(0, slName, OBJPROP_BACK,      true);
   ObjectSetInteger(0, slName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, slName, OBJPROP_HIDDEN,     true);

   //--- Entry line label
   string entryLabel = PREFIX + "Entry_Line";
   ObjectCreate(0, entryLabel, OBJ_TREND, 0, entryT, entry, endTime, entry);
   ObjectSetInteger(0, entryLabel, OBJPROP_COLOR,     C'255,255,255');
   ObjectSetInteger(0, entryLabel, OBJPROP_STYLE,     STYLE_DOT);
   ObjectSetInteger(0, entryLabel, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, entryLabel, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, entryLabel, OBJPROP_BACK,      true);
   ObjectSetInteger(0, entryLabel, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, entryLabel, OBJPROP_HIDDEN,     true);

   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| Update SL box when break-even is applied                          |
//+------------------------------------------------------------------+
void UpdateSLBox(double newSL)
{
   string slName = PREFIX + "SL_Box";
   if(ObjectFind(0, slName) >= 0)
   {
      //--- Move the SL edge (price2) to the new SL level
      ObjectSetDouble(0, slName, OBJPROP_PRICE, 1, newSL);
      //--- Change color to orange to indicate BE
      ObjectSetInteger(0, slName, OBJPROP_COLOR, C'255,165,0');
      ChartRedraw(0);
   }
}


//+------------------------------------------------------------------+
//| Delete position boxes from chart                                  |
//+------------------------------------------------------------------+
void DeletePositionBoxes()
{
   ObjectDelete(0, PREFIX + "TP_Box");
   ObjectDelete(0, PREFIX + "SL_Box");
   ObjectDelete(0, PREFIX + "Entry_Line");
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
