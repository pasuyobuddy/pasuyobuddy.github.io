//+------------------------------------------------------------------+
//|                                                 TrendRiderEA.mq5 |
//|  Trend-following Expert Advisor for MetaTrader 5                 |
//|                                                                  |
//|  Entry : Fast EMA crosses Slow EMA on a closed bar,              |
//|          price on the right side of the Trend EMA (200),         |
//|          RSI confirms momentum.                                  |
//|  Exits : ATR SL, TP = SL x RR (1:2), breakeven, opt. trailing,  |
//|          optional close on opposite signal.                      |
//|  Risk  : % of balance per trade, max spread, session filter,     |
//|          daily loss limit, margin check.                         |
//+------------------------------------------------------------------+
#property copyright "TrendRider EA"
#property version   "1.00"
#property description "EMA crossover + 200 EMA trend filter + RSI, ATR stops, % risk sizing."

#include <Trade\Trade.mqh>

//--- Signal
input group "Signal"
input ENUM_TIMEFRAMES InpTF            = PERIOD_M15;     // Signal timeframe
input int             InpFastEMA       = 20;             // Fast EMA period
input int             InpSlowEMA       = 50;             // Slow EMA period
input int             InpTrendEMA      = 200;            // Trend filter EMA period (0 = off)
input int             InpRSIPeriod     = 14;             // RSI period
input double          InpRSIBuyLevel   = 50.0;           // Buy only if RSI above
input double          InpRSISellLevel  = 50.0;           // Sell only if RSI below
input bool            InpCloseOnOpposite = true;         // Close positions on opposite signal

//--- Risk
input group "Risk"
input double InpRiskPercent     = 0.5;   // Risk per trade (% of balance)
input double InpFixedLot        = 0.0;   // Fixed lot (>0 overrides % risk)
input int    InpATRPeriod       = 14;    // ATR period
input double InpSLATR           = 1.5;   // Stop loss = ATR x
input double InpRR              = 2.0;   // Reward:Risk (TP = SL x RR, 2.0 = 1:2; 0 = no TP)
input int    InpMaxPositions    = 1;     // Max open positions (this EA, this symbol)
input int    InpMaxSpreadPts    = 20;    // Max spread in points (0 = off)
input double InpMaxDailyLossPct = 3.0;   // Stop trading for the day after this % loss (0 = off)

//--- Trade management
input group "Trade management"
input bool   InpUseBreakeven    = true;  // Move SL to breakeven
input double InpBETriggerR      = 1.0;   // Breakeven when profit >= R x (1R = SL distance)
input int    InpBEOffsetPts     = 10;    // Breakeven offset (points, locks small profit)
input bool   InpUseTrailing     = false; // Use ATR trailing stop (off keeps full 1:2 target)
input double InpTrailStartATR   = 1.5;   // Start trailing when profit >= ATR x
input double InpTrailDistATR    = 1.0;   // Trailing distance = ATR x

//--- Session
input group "Session (broker server time)"
input bool InpUseSession = true;         // Trade only inside session
input int  InpStartHour  = 7;            // Session start hour (0-23)
input int  InpEndHour    = 20;           // Session end hour (0-23, exclusive)

//--- Misc
input group "Misc"
input ulong  InpMagic       = 260117;     // Magic number
input int    InpSlippagePts = 20;         // Max slippage (points)
input string InpComment     = "TrendRider";

//--- globals
CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hTrend = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE, hATR  = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA <= 0 || InpSlowEMA <= 0 || InpFastEMA >= InpSlowEMA)
   { Print("Invalid EMA settings: Fast must be > 0 and < Slow."); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent <= 0 && InpFixedLot <= 0)
   { Print("Set RiskPercent or FixedLot."); return INIT_PARAMETERS_INCORRECT; }
   if(InpSLATR <= 0)
   { Print("Stop loss ATR multiplier must be > 0."); return INIT_PARAMETERS_INCORRECT; }

   hFast = iMA(_Symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(InpTrendEMA > 0)
      hTrend = iMA(_Symbol, InpTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpTF, InpATRPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || (InpTrendEMA > 0 && hTrend == INVALID_HANDLE))
   { Print("Failed to create indicator handles. Error ", GetLastError()); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFast  != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow  != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend);
   if(hRSI   != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR   != INVALID_HANDLE) IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
void OnTick()
{
   double atr = GetBuffer(hATR, 1);
   if(atr <= 0) return;

   // Manage open trades on every tick
   ManagePositions(atr);

   // Signals only once per new closed bar
   datetime barTime = iTime(_Symbol, InpTF, 0);
   if(barTime == 0 || barTime == lastBarTime) return;
   lastBarTime = barTime;

   int signal = GetSignal(); // 1 = buy, -1 = sell, 0 = none
   if(signal == 0) return;

   if(InpCloseOnOpposite)
      ClosePositions(signal == 1 ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);

   if(!CanOpenTrade()) return;

   OpenTrade(signal, atr);
}

//+------------------------------------------------------------------+
//| Read one value from an indicator buffer at bar 'shift'           |
//+------------------------------------------------------------------+
double GetBuffer(int handle, int shift)
{
   double buf[];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Signal on closed bars: bar 1 vs bar 2                            |
//+------------------------------------------------------------------+
int GetSignal()
{
   double fast1 = GetBuffer(hFast, 1), fast2 = GetBuffer(hFast, 2);
   double slow1 = GetBuffer(hSlow, 1), slow2 = GetBuffer(hSlow, 2);
   double rsi1  = GetBuffer(hRSI, 1);
   if(fast1 == 0 || fast2 == 0 || slow1 == 0 || slow2 == 0 || rsi1 == 0) return 0;

   double close1 = iClose(_Symbol, InpTF, 1);
   bool upTrend = true, downTrend = true;
   if(InpTrendEMA > 0)
   {
      double trend1 = GetBuffer(hTrend, 1);
      if(trend1 == 0) return 0;
      upTrend   = close1 > trend1;
      downTrend = close1 < trend1;
   }

   bool crossUp   = fast1 > slow1 && fast2 <= slow2;
   bool crossDown = fast1 < slow1 && fast2 >= slow2;

   if(crossUp   && upTrend   && rsi1 > InpRSIBuyLevel)  return  1;
   if(crossDown && downTrend && rsi1 < InpRSISellLevel) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Filters before opening a trade                                   |
//+------------------------------------------------------------------+
bool CanOpenTrade()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   { Print("Algo trading is disabled."); return false; }

   if(CountPositions(-1) >= InpMaxPositions) return false;

   if(InpMaxSpreadPts > 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPts)
      { PrintFormat("Spread %d > max %d, skipping.", spread, InpMaxSpreadPts); return false; }
   }

   if(InpUseSession && !InSession()) return false;

   if(DailyLossHit())
   { Print("Daily loss limit reached, no new trades today."); return false; }

   return true;
}

bool InSession()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpStartHour == InpEndHour) return true;
   if(InpStartHour < InpEndHour) return (t.hour >= InpStartHour && t.hour < InpEndHour);
   return (t.hour >= InpStartHour || t.hour < InpEndHour); // overnight session
}

//+------------------------------------------------------------------+
//| Today's realized + floating P/L for this EA vs start-of-day bal. |
//+------------------------------------------------------------------+
bool DailyLossHit()
{
   if(InpMaxDailyLossPct <= 0) return false;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   datetime dayStart = StructToTime(t);

   double closedPL = 0.0;
   if(HistorySelect(dayStart, TimeCurrent()))
   {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
         closedPL += HistoryDealGetDouble(d, DEAL_PROFIT)
                   + HistoryDealGetDouble(d, DEAL_SWAP)
                   + HistoryDealGetDouble(d, DEAL_COMMISSION);
      }
   }

   double floatingPL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition()) continue;
      floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - closedPL;
   if(startBalance <= 0) return true;
   return (closedPL + floatingPL) <= -startBalance * InpMaxDailyLossPct / 100.0;
}

//+------------------------------------------------------------------+
//| Open a market order with ATR-based SL/TP and risk-based lots     |
//+------------------------------------------------------------------+
void OpenTrade(int signal, double atr)
{
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStop  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   double slDist = MathMax(atr * InpSLATR, minStop + 2 * point);
   double tpDist = (InpRR > 0) ? MathMax(slDist * InpRR, minStop + 2 * point) : 0.0;

   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   if(signal == 1)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = (tpDist > 0) ? NormalizeDouble(ask + tpDist, digits) : 0.0;
      if(!HasMargin(ORDER_TYPE_BUY, lots, ask)) return;
      if(!trade.Buy(lots, _Symbol, ask, sl, tp, InpComment))
         PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = (tpDist > 0) ? NormalizeDouble(bid - tpDist, digits) : 0.0;
      if(!HasMargin(ORDER_TYPE_SELL, lots, bid)) return;
      if(!trade.Sell(lots, _Symbol, bid, sl, tp, InpComment))
         PrintFormat("Sell failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

double CalcLots(double slDist)
{
   if(InpFixedLot > 0) return NormalizeLots(InpFixedLot);

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || slDist <= 0) return 0.0;

   double lossPerLot = slDist / tickSize * tickValue;
   double lots = NormalizeLots(riskMoney / lossPerLot);
   if(lots <= 0)
      Print("Calculated lot is below broker minimum for this risk. Trade skipped (not over-risking).");
   return lots;
}

double NormalizeLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;

   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0.0;
   lots = MathMin(lots, maxL);

   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
}

bool HasMargin(ENUM_ORDER_TYPE type, double lots, double price)
{
   double margin;
   if(!OrderCalcMargin(type, _Symbol, lots, price, margin)) return true; // let server decide
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   { PrintFormat("Not enough free margin for %.2f lots.", lots); return false; }
   return true;
}

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
bool IsOurPosition() // assumes position already selected
{
   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
}

// type: -1 = all, otherwise ENUM_POSITION_TYPE
int CountPositions(int type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition()) continue;
      if(type == -1 || PositionGetInteger(POSITION_TYPE) == type) count++;
   }
   return count;
}

void ClosePositions(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition()) continue;
      if(PositionGetInteger(POSITION_TYPE) != type) continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("Close %I64u failed: %d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Breakeven + ATR trailing stop                                    |
//+------------------------------------------------------------------+
void ManagePositions(double atr)
{
   if(!InpUseBreakeven && !InpUseTrailing) return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition()) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double newSL = sl;

      if(type == POSITION_TYPE_BUY)
      {
         double profit = bid - open;
         if(InpUseBreakeven && profit >= InpBETriggerR * InpSLATR * atr)
         {
            double be = open + InpBEOffsetPts * point;
            if(sl < be) newSL = be;
         }
         if(InpUseTrailing && profit >= InpTrailStartATR * atr)
         {
            double trail = bid - InpTrailDistATR * atr;
            if(trail > newSL) newSL = trail;
         }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > sl + point && newSL < bid - minStop)
            if(!trade.PositionModify(ticket, newSL, tp))
               PrintFormat("Modify %I64u failed: %d", ticket, trade.ResultRetcode());
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit = open - ask;
         if(InpUseBreakeven && profit >= InpBETriggerR * InpSLATR * atr)
         {
            double be = open - InpBEOffsetPts * point;
            if(sl == 0 || sl > be) newSL = be;
         }
         if(InpUseTrailing && profit >= InpTrailStartATR * atr)
         {
            double trail = ask + InpTrailDistATR * atr;
            if(newSL == 0 || trail < newSL) newSL = trail;
         }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > 0 && (sl == 0 || newSL < sl - point) && newSL > ask + minStop)
            if(!trade.PositionModify(ticket, newSL, tp))
               PrintFormat("Modify %I64u failed: %d", ticket, trade.ResultRetcode());
      }
   }
}
//+------------------------------------------------------------------+
