//+------------------------------------------------------------------------------------+
//|  LOU A+ SETUP DETECTOR - EA V1.9.2  (MT5 port of the TradingView strategy V1.9.6)  |
//|                                                                                    |
//|  Four independent range setups, each with its own on/off switch, time windows,     |
//|  filters and trade counter. All four follow exactly the same rules:                |
//|                                                                                    |
//|    ASIA    02:00-06:00   entries 06:00-10:00                                       |
//|    LONDON  07:12-08:12   entries 08:12-10:00                                       |
//|    LUNCH   12:00-13:00   entries 13:00-14:15                                       |
//|    NY      14:12-15:12   entries 15:30-16:30                                       |
//|                                                                                    |
//|  Entry models (shared by all four)                                                 |
//|    1  OB   first M5 candle closing outside the range becomes the orderblock.       |
//|            Entry on the close back beyond that OB and inside the range.            |
//|    2  FIB  fib from the sweep extreme to the reclaim extreme, limit at 0.618.      |
//|                                                                                    |
//|  Legacy models (off by default): Asia OB with R targets, and the original London   |
//|  model with the Asia location filter plus double sweep.                            |
//|                                                                                    |
//|  Account guards: daily/weekly profit target and max loss, max open risk.           |
//|  Multi-symbol: load on ONE chart, trade every symbol listed in "Symbole".          |
//|  Time: Europe/Vienna incl. DST, broker offset configurable.                        |
//+------------------------------------------------------------------------------------+
#property copyright "A+ Setup Detector"
#property version   "1.92"
#property description "Lou-A+ V1.6.3 – Asia / London / Lunch / NY, per-range signal timeframe, Multi-Symbol"

#include <Trade\Trade.mqh>

//====================================================================================
// 0. ENUMS / KONSTANTEN
//====================================================================================
enum ENUM_RUNMODE { MODE_DRAW = 0,      // Nur zeichnen + Alerts
                    MODE_AUTO = 1 };    // Automatisch handeln
enum ENUM_TZMODE  { TZ_VIENNA = 0,      // Europe/Vienna (MEZ/MESZ)
                    TZ_UTC1   = 1 };    // Fix UTC+1 (ohne Sommerzeit)
enum ENUM_OFFMODE { OFF_NYCLOSE = 0,    // Automatisch: NY-Close (Winter-Offset, +1 bei US-Sommerzeit)
                    OFF_MANUAL  = 1 };  // Manuell (fixer Offset)
enum ENUM_DSMODE  { DS_REQ = 0,         // Pflicht (Asia + Pre sweepen)
                    DS_OPT = 1 };       // Optional (Asia reicht)
enum ENUM_SIGTF   { SIG_M1  = 1,        // M1
                    SIG_M3  = 3,        // M3
                    SIG_M5  = 5,        // M5
                    SIG_M15 = 15 };     // M15
enum ENUM_OBTRIG  { OB_BODY = 0,        // OB Body (Open/Close)
                    OB_WICK = 1 };      // OB Docht (High/Low)
enum ENUM_TPMODE  { TP_DUAL = 0,        // Dual TP – TP1 + TP2
                    TP_FULL = 1,        // Single TP – nur TP2-Level
                    TP_HALF = 2,        // Single TP – nur TP1-Level
                    TP_CUSTR = 3 };     // Custom R – TP1 = volle Range, TP2 = X R (Runner)
enum ENUM_DIRF    { DIRF_BOTH  = 0,     // Both directions
                    DIRF_LONG  = 1,     // Long only
                    DIRF_SHORT = 2 };   // Short only
enum ENUM_ATPMODE { ATP_DUAL = 0,       // Dual TP (TP1 + TP2 in R)
                    ATP_SINGLE = 1 };   // Single TP (TP2 in R)
enum ENUM_LOCK    { LOCK_FIRST = 0,     // Erstes TP (TP1 bzw. Single TP)
                    LOCK_FINAL = 1,     // Nur finaler TP
                    LOCK_OFF   = 2 };   // Aus

#define NA EMPTY_VALUE

// States Pre-Range-Setup (London / NY)
#define ST_IDLE          0
#define ST_BUILD_ASIA    1
#define ST_BUILD_PRE     2
#define ST_WAIT_SWEEP    3
#define ST_WAIT_RECLAIM  4
#define ST_WAIT_ENTRY    5
#define ST_CUTOFF        6
#define ST_MAX_TRADES    7
#define ST_INVALID_LOC   8
#define ST_NO_DATA       9
// States Asia OB
#define AS_WAIT_RANGE    0
#define AS_WAIT_SWEEP    1
#define AS_WAIT_RECLAIM  2
#define AS_CUTOFF        3
#define AS_MAX_TRADES    4

//====================================================================================
// 1. INPUTS
//====================================================================================
input group "0 General"
input ENUM_RUNMODE InpMode        = MODE_DRAW;   // Modus
input string       InpSymbols     = "";          // Symbole, kommagetrennt (leer = Chart-Symbol)
input long         InpMagic       = 7771200;     // Magic Number
input double       InpRiskPct     = 1.0;         // Risiko pro Trade (% Equity)
input bool         InpSpreadSL    = true;        // SL um aktuellen Spread erweitern
input int          InpSlippage    = 20;          // Max. Slippage (Points)
input ENUM_LOCK    InpLockMode    = LOCK_OFF;    // Session-Sperre auslösen nach
input int          InpWarmupDays  = 5;           // Historie beim Start verarbeiten (Tage)

input group "1b Account guards (0 = off)"
input double InpDailyGoal    = 0.0;  // Daily Profit-Ziel (% Equity) – danach keine neuen Trades
input double InpDailyMaxLoss = 0.0;  // Daily Max-Loss (% Equity)
input double InpWeekGoal     = 0.0;  // Weekly Profit-Ziel (% Equity)
input double InpWeekMaxLoss  = 0.0;  // Weekly Max-Loss (% Equity)
input double InpMaxOpenRisk  = 0.0;  // Max. gleichzeitig offenes Risiko (% Equity)
input int    InpDayMaxSL     = 0;    // Stop for the day after X stop-losses (0 = off)
input bool   InpDayStopTP    = false;// Stop for the day after one full target
input bool   InpAllowCounter = false;// Allow counter-direction trades
input bool   InpFlattenOrph  = true; // Close positions the EA no longer tracks

input group "1 Time / sessions (Central European local time)"
input ENUM_TZMODE  InpTZ          = TZ_VIENNA;   // Zeitzone
input ENUM_OFFMODE InpOffMode     = OFF_NYCLOSE; // Broker-Zeitoffset
input int          InpOffWinter   = 2;           // Broker GMT-Offset Winter (bzw. manuell), Std.

input group "2a Asia range"
input bool   InpUseAsia     = true;         // Asia range active
input string InpAsiaSess    = "0200-0600";  // Asia range
input string InpAsiaWin     = "0600-1000";  // Entry window
input int    InpAsiaFibEndH = 11;           // Fib limit valid until (hour)
input int    InpAsiaFibEndM = 0;            // Fib limit valid until (minute)
input double InpAsiaSwDist  = 0.0;          // Min. sweep distance (% of range)
input double InpAsiaObDepth = 25.0;         // OB: max. entry depth (% of range)
input double InpAsiaFibDep  = 50.0;         // Fib: min. reclaim depth (% of range)
input int    InpAsiaMax     = 2;            // Max. trades per Asia session
input ENUM_SIGTF InpAsiaSigTF = SIG_M5;      // Signal timeframe (confirmation candles)
input int    InpAsiaCloseH = 0;            // Force-close open trades at (hour, 0 = off)
input int    InpAsiaCloseM = 0;            // Force-close: minute

input group "2b London range"
input bool   InpUseLdn      = true;         // London range active
input string InpPreSess     = "0712-0812";  // London range
input string InpLdnEntry    = "0812-1000";  // Entry window
input int    InpLdnFibEndH  = 11;           // Fib limit valid until (hour)
input int    InpLdnFibEndM  = 0;            // Fib limit valid until (minute)
input double InpLdnSwDist   = 0.0;          // Min. sweep distance (% of range)
input double InpLdnObDepth  = 25.0;         // OB: max. entry depth (% of range)
input double InpLdnFibDep   = 50.0;         // Fib: min. reclaim depth (% of range)
input int    InpLdnMax      = 2;            // Max. trades per London session
input ENUM_SIGTF InpLdnSigTF  = SIG_M5;      // Signal timeframe (confirmation candles)
input int    InpLdnCloseH  = 0;            // Force-close open trades at (hour, 0 = off)
input int    InpLdnCloseM  = 0;            // Force-close: minute

input group "2c Lunch range"
input bool   InpUseLunch     = true;         // Lunch range active
input string InpLunchSess    = "1200-1300";  // Lunch range
input string InpLunchEntry   = "1300-1415";  // Entry window
input double InpLunSwDist    = 0.0;          // Min. sweep distance (% of range)
input double InpLunObDepth   = 25.0;         // OB: max. entry depth (% of range)
input double InpLunFibDep    = 50.0;         // Fib: min. reclaim depth (% of range)
input int    InpLunFibEndH   = 15;           // Fib limit valid until (hour)
input int    InpLunFibEndM   = 0;            // Fib limit valid until (minute)
input int    InpLunchMax     = 2;            // Max. trades per lunch session
input ENUM_SIGTF InpLunSigTF   = SIG_M5;      // Signal timeframe (confirmation candles)
input int    InpLunCloseH  = 0;            // Force-close open trades at (hour, 0 = off)
input int    InpLunCloseM  = 0;            // Force-close: minute

input group "2d NY range"
input bool   InpUseNY       = true;         // NY range active
input string InpNyPreSess   = "1412-1512";  // NY range
input string InpNyEntrySess = "1530-1630";  // Entry window
input double InpNySwDist    = 0.0;          // Min. sweep distance (% of range)
input double InpNyObDepth   = 25.0;         // OB: max. entry depth (% of range)
input double InpNyFibDep    = 50.0;         // Fib: min. reclaim depth (% of range)
input int    InpNyFibEndH   = 18;           // Fib limit valid until (hour)
input int    InpNyFibEndM   = 0;            // Fib limit valid until (minute)
input int    InpNyMax       = 2;            // Max. trades per NY session
input ENUM_SIGTF InpNySigTF   = SIG_M1;      // Signal timeframe (confirmation candles)
input int    InpNyCloseH   = 0;            // Force-close open trades at (hour, 0 = off)
input int    InpNyCloseM   = 0;            // Force-close: minute
input bool   InpLdnLocksNY  = false;        // Earlier session TP locks NY

input group "3 Entry model 1: Orderblock (all ranges)"
input bool        InpUseOB      = true;    // Model 1 master switch
input ENUM_OBTRIG InpObTrig     = OB_BODY; // Reclaim/entry: M5 close beyond

input group "3b Models per session on/off"
input bool InpAsiaOB = true;   // Asia: OB entry
input bool InpAsiaFib= true;   // Asia: Fib entry
input bool InpLdnOB  = true;   // London: OB entry
input bool InpLdnFib = true;   // London: Fib entry
input bool InpLunOB  = true;   // Lunch: OB entry
input bool InpLunFib = true;   // Lunch: Fib entry
input bool InpNyOB   = true;   // NY: OB entry
input bool InpNyFib  = true;   // NY: Fib entry

input group "4c Entry model 3: 3-candle engulfing"
input bool   InpUseEng      = false;  // Model 3 master switch
input bool   InpEngAsia     = true;   // Asia
input bool   InpEngLdn      = true;   // London
input bool   InpEngLun      = true;   // Lunch
input bool   InpEngNy       = true;   // NY
input double InpEngBodyPct  = 50.0;   // Candle strength: body >= % of candle range
input bool   InpEngRolling  = true;   // Series: rolling last three (off = exactly three)
input bool   InpEngNeedSweep= true;   // Low/high of the three must be swept first
input double InpEngDistPct  = 100.0;  // Max. distance from the range (% of range)
input bool   InpEngLastBody = false;  // Limit level: body of the last candle (off = outer body)
input int    InpEngOwnMax   = 0;      // Own trade budget per range (0 = share)
input bool   InpEngBlocksOB = false;  // Three-candle break disables the OB entry
input bool   InpEngRejCancel= true;   // Cancel limit if price reaches a range edge first

input group "4d Entry model 4: FVG inversion"
input bool   InpUseFiv      = false;  // Model 4 master switch
input bool   InpFivAsia     = true;   // Asia
input bool   InpFivLdn      = true;   // London
input bool   InpFivLun      = true;   // Lunch
input bool   InpFivNy       = true;   // NY
input bool   InpFivM5       = true;   // FVG timeframe M5
input bool   InpFivM15      = true;   // FVG timeframe M15
input bool   InpFivH1       = false;  // FVG timeframe H1
input bool   InpFivH4       = false;  // FVG timeframe H4
input int    InpFivBrkBars  = 10;     // Breakout window: max. candles
input int    InpFivOwnMax   = 1;      // Own trade budget per range (0 = share)
input double InpFivDistPct  = 100.0;  // Max. distance from the range (% of range)

input group "5 Liquidity filters (model 1 only)"
input bool   InpUseSwingF   = false;  // Swing sweep required
input int    InpSwingLen    = 2;      // Swing fractal length (bars each side)
input bool   InpUseFvgF     = false;  // FVG dip required
input bool   InpFvgM5       = true;   // FVG timeframe M5
input bool   InpFvgM15      = true;   // FVG timeframe M15
input bool   InpFvgH1       = false;  // FVG timeframe H1
input bool   InpFvgH4       = false;  // FVG timeframe H4
input bool   InpUseObF      = false;  // Orderblock tap required
input double InpObDispPct   = 30.0;   // OB displacement (% of range)

input group "4 Entry model 2: Fib retrace limit (all ranges)"
input bool   InpUseFib      = true;   // Model 2 master switch
input double InpFibLevel    = 0.618;  // Fib level

input group "5a Stop loss / Take profit (all ranges)"
input double      InpSlBuf     = 0.0;      // SL-Puffer (% Referenz-Range)
input ENUM_TPMODE InpTpMode    = TP_DUAL;  // TP-Modell
input double      InpMinRR     = 1.0;      // Min. CRV (RR) zum ersten TP (0 = aus)
input double      InpMaxSlPct  = 0.0;      // Max. SL-Abstand (% der Range, 0 = aus)
input double      InpTp1Level  = 50.0;     // TP1-Level (% der Range, von der Sweep-Seite)
input double      InpTp2Level  = 75.0;     // TP2-Level (% der Range)
input double      InpTp1Split  = 70.0;     // Dual: Anteil auf TP1 (%)
input bool        InpBE        = false;    // Dual: SL auf BE nach TP1
input double      InpTp2R      = 6.0;      // Custom R: TP2 in R (nur TP-Modell "Custom R")
input bool        InpCustRNoCap = true;    // Custom R: TP2 darf ueber die Range hinaus laufen

input group "5d Direction filter"
input ENUM_DIRF InpDirFilter     = DIRF_BOTH; // Allowed direction (all symbols)
input string    InpLongOnlySyms  = "";        // Long-only symbols (comma list, empty = off)
input string    InpShortOnlySyms = "";        // Short-only symbols (comma list, empty = off)

input group "5b Session locks (after TP)"
input bool InpShareAsiaLdn   = false;  // Asia-TP sperrt London und umgekehrt
input bool InpPrevLocksLunch = false;  // Asia/London-TP sperrt Lunch

input group "5c No-trade zone (50 % mark)"
input bool   InpUseNoTrade   = true;  // Block entries at the 50 % mark
input double InpNoTradeZone  = 5.0;   // Zone: 50 % +/- X % of the range
input bool   InpNtzAsia      = false; // Also apply to legacy Asia OB

input group "6a Legacy Asia OB (R targets)"
input bool         InpUseAsiaOB   = false;       // Legacy Asia OB model active
input string       InpLegAsiaWin  = "0600-1000"; // Sweep & entry window
input double       InpLegAsiaSw   = 0.0;         // Min. sweep distance (% of Asia range)
input double       InpLegAsiaDep  = 25.0;        // Max. entry depth (% of Asia range)
input double       InpAsiaSlBuf   = 0.0;         // SL buffer (% of Asia range)
input ENUM_ATPMODE InpAsiaTpMode  = ATP_DUAL;    // Take-profit model
input double       InpAsiaRR1     = 1.0;         // TP1 (R)
input double       InpAsiaRR2     = 2.0;         // TP2 / target (R)
input bool         InpAsiaBE      = true;        // Dual: move SL to break-even after TP1

input group "6b Legacy London (location + double sweep)"
input bool   InpUseLegLdn  = false;   // Legacy London model active
input double InpLegSwDist  = 0.0;     // Legacy London: min. Asia sweep distance (%)
input int    InpCutoffH    = 10;      // Legacy London: no new trades from (hour)
input int    InpCutoffM    = 0;       // Legacy London: no new trades from (minute)
input int    InpLegLdnMax  = 2;       // Legacy London: max. trades
input double InpLegObDepth = 25.0;    // Legacy London: OB max. entry depth (%)
input double InpLegFibDep  = 50.0;    // Legacy London: fib min. reclaim depth (%)
input double InpLocShortMin = 80.0;   // SHORT von %
input double InpLocShortMax = 130.0;  // SHORT bis %
input double InpLocLongMin  = -30.0;  // LONG von %
input double InpLocLongMax  = 20.0;   // LONG bis %
input double InpLocMaxGap   = 10.0;   // Max. Abstand Pre-Kante ↔ Asia-Kante (% Asia Range)
input ENUM_DSMODE InpDoubleSweep = DS_REQ; // Legacy London: double sweep (Asia + Pre)

input group "7 Visuals (chart symbol only)"
input bool  InpShowRanges  = true;  // Ranges
input bool  InpShowSweep   = true;  // Sweep / Reclaim Labels
input bool  InpShowOB      = true;  // Orderblocks
input bool  InpShowFib     = true;  // Fib-Limit
input bool  InpShowTrades  = true;  // SL/TP-Zonen + Entry + Ergebnis
input bool  InpShowDebug   = true;  // Debug-Panel
input color InpColAsia     = C'70,20,45';    // Asia Box
input color InpColPre      = C'10,55,65';    // London Pre-Range Box
input color InpColLunch    = C'10,70,60';    // Lunch Box (türkis)
input color InpColNy       = C'80,60,10';    // NY Box (orange)
input color InpColLines    = clrSilver;      // Pre-Linien
input color InpColOB       = C'70,30,90';    // Orderblock
input color InpColAsiaOB   = C'95,35,35';    // Asia OB
input color InpColSweep    = clrOrange;      // Sweep
input color InpColReclaim  = clrDodgerBlue;  // Reclaim
input color InpColFib      = clrYellow;      // Fib
input color InpColRisk     = C'90,25,30';    // SL-Zone
input color InpColReward   = C'15,70,55';    // TP-Zone
input color InpColBull     = clrMediumSeaGreen; // Long
input color InpColBear     = clrTomato;      // Short

input group "8 Alerts"
input bool InpAlertPopup = true;  // Popup-Alert
input bool InpAlertPush  = true;  // Push-Benachrichtigung (Handy)


//====================================================================================
// 2. GLOBALE HELFER: ZEIT
//====================================================================================
CTrade   g_trade;
datetime g_start  = 0;
long     g_objSeq = 0;

bool IsNa(double v) { return v == NA; }

datetime MkTime(int y, int mo, int d, int h = 0, int mi = 0)
{
   MqlDateTime s; ZeroMemory(s);
   s.year = y; s.mon = mo; s.day = d; s.hour = h; s.min = mi; s.sec = 0;
   return StructToTime(s);
}
int Dow(datetime t) { MqlDateTime s; TimeToStruct(t, s); return s.day_of_week; }

datetime LastSunday(int y, int mo)
{
   datetime t = (mo == 12 ? MkTime(y + 1, 1, 1) : MkTime(y, mo + 1, 1)) - 86400;
   while(Dow(t) != 0) t -= 86400;
   return t;
}
datetime NthSunday(int y, int mo, int n)
{
   datetime t = MkTime(y, mo, 1);
   while(Dow(t) != 0) t += 86400;
   return t + (n - 1) * 7 * 86400;
}
// EU-Sommerzeit: letzter So. März 01:00 UTC bis letzter So. Oktober 01:00 UTC
bool IsEUDst(datetime utc)
{
   MqlDateTime s; TimeToStruct(utc, s);
   return utc >= LastSunday(s.year, 3) + 3600 && utc < LastSunday(s.year, 10) + 3600;
}
// US-Sommerzeit: 2. So. März 07:00 UTC bis 1. So. November 06:00 UTC
bool IsUSDst(datetime utc)
{
   MqlDateTime s; TimeToStruct(utc, s);
   return utc >= NthSunday(s.year, 3, 2) + 7 * 3600 && utc < NthSunday(s.year, 11, 1) + 6 * 3600;
}
int TzOff(datetime utc)     { return InpTZ == TZ_UTC1 ? 3600 : (IsEUDst(utc) ? 7200 : 3600); }
int BrokerOff(datetime utc) { return InpOffMode == OFF_MANUAL ? InpOffWinter * 3600 : (IsUSDst(utc) ? InpOffWinter + 1 : InpOffWinter) * 3600; }
datetime S2L(datetime srv)  { datetime utc = srv - BrokerOff(srv); return utc + TzOff(utc); }      // Server → Wien
datetime L2S(datetime loc)  { datetime utc = loc - TzOff(loc - 3600); return utc + BrokerOff(utc); } // Wien → Server
int DayKey(datetime loc)    { MqlDateTime s; TimeToStruct(loc, s); return s.year * 10000 + s.mon * 100 + s.day; }

bool ParseSess(string s, int &sh, int &sm, int &eh, int &em)
{
   if(StringLen(s) < 9) return false;
   sh = (int)StringToInteger(StringSubstr(s, 0, 2));
   sm = (int)StringToInteger(StringSubstr(s, 2, 2));
   eh = (int)StringToInteger(StringSubstr(s, 5, 2));
   em = (int)StringToInteger(StringSubstr(s, 7, 2));
   return true;
}

//====================================================================================
// 3. GLOBALE HELFER: ZEICHNEN
//====================================================================================
string NewName() { return "APX_" + IntegerToString(g_objSeq++); }

string DRect(datetime t1, double p1, datetime t2, double p2, color c)
{
   string n = NewName();
   ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FILL, true);
   ObjectSetInteger(0, n, OBJPROP_BACK, true);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   return n;
}
string DLine(datetime t1, double p1, datetime t2, double p2, color c, ENUM_LINE_STYLE st = STYLE_SOLID, int w = 1)
{
   string n = NewName();
   ObjectCreate(0, n, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   return n;
}
string DText(datetime t, double p, string txt, color c, ENUM_ANCHOR_POINT a = ANCHOR_LEFT, int size = 8)
{
   string n = NewName();
   ObjectCreate(0, n, OBJ_TEXT, 0, t, p);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, a);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   return n;
}
void MoveRight(string n, datetime srvT)
{
   if(n == "" || ObjectFind(0, n) < 0) return;
   ObjectMove(0, n, 1, srvT, ObjectGetDouble(0, n, OBJPROP_PRICE, 1));
}

//====================================================================================
// 3b. KONTO-GUARDS (Tages-/Wochenziele, Verlustlimits, offenes Risiko)
//====================================================================================
datetime DayStartSrv()
{
   MqlDateTime s; TimeToStruct(TimeCurrent(), s);
   return MkTime(s.year, s.mon, s.day);
}
datetime WeekStartSrv()
{
   datetime d = DayStartSrv();
   int dw = Dow(d);
   int back = (dw == 0 ? 6 : dw - 1);          // Montag als Wochenstart
   return d - back * 86400;
}
double RealizedPnL(datetime from)
{
   double sum = 0;
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT && HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_INOUT) continue;
      sum += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) + HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }
   return sum;
}
double FloatingPnL()
{
   double sum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return sum;
}
// Offenes Risiko aller EA-Positionen in Kontowährung (Abstand bis SL)
double OpenRiskMoney()
{
   double sum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sy  = PositionGetString(POSITION_SYMBOL);
      double sl  = PositionGetDouble(POSITION_SL);
      if(sl <= 0) continue;
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double tv  = SymbolInfoDouble(sy, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0) tv = SymbolInfoDouble(sy, SYMBOL_TRADE_TICK_VALUE);
      double ts  = SymbolInfoDouble(sy, SYMBOL_TRADE_TICK_SIZE);
      if(ts <= 0 || tv <= 0) continue;
      sum += MathAbs(op - sl) / ts * tv * vol;
   }
   return sum;
}
// true = neue Trades erlaubt; sonst Grund in why
bool GuardsOK(double newRiskMoney, string &why)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0) { why = "Equity 0"; return false; }
   double dayP  = RealizedPnL(DayStartSrv()) + FloatingPnL();
   double weekP = RealizedPnL(WeekStartSrv()) + FloatingPnL();
   if(InpDailyGoal    > 0 && dayP  >=  eq * InpDailyGoal    / 100.0) { why = "Daily Profit-Ziel erreicht";  return false; }
   if(InpWeekGoal     > 0 && weekP >=  eq * InpWeekGoal     / 100.0) { why = "Weekly Profit-Ziel erreicht"; return false; }
   if(InpDailyMaxLoss > 0 && dayP  <= -eq * InpDailyMaxLoss / 100.0) { why = "Daily Max-Loss erreicht";     return false; }
   if(InpWeekMaxLoss  > 0 && weekP <= -eq * InpWeekMaxLoss  / 100.0) { why = "Weekly Max-Loss erreicht";    return false; }
   if(InpMaxOpenRisk  > 0 && OpenRiskMoney() + newRiskMoney > eq * InpMaxOpenRisk / 100.0) { why = "Max. offenes Risiko erreicht"; return false; }
   return true;
}

//====================================================================================
// 4. DATENSTRUKTUREN
//====================================================================================
struct SRange
{
   double hi, lo; int bars; bool complete;
   void Reset() { hi = NA; lo = NA; bars = 0; complete = false; }
   void Update(double h, double l)
   {
      if(bars == 0) { hi = h; lo = l; }
      else { hi = MathMax(hi, h); lo = MathMin(lo, l); }
      bars++;
   }
};

// Liquiditäts-Objekte: Swing-Levels, FVGs und Orderblocks
struct SLvl { double px; datetime t; bool active; };
struct SZone
{
   double   bot, top, move, anchor;
   int      dir;                      // 1 = bullisch, -1 = bearisch
   datetime t, seen, invT;
   bool     dead, inv, used;
   string   tf;
};

struct SSess
{
   datetime asiaStart, asiaEnd, preStart, preEnd, cutoff;
   datetime asiaWinStart, asiaWinEnd, nyPreStart, nyPreEnd, nyEntryStart, nyEntryEnd;
   datetime lunchPreStart, lunchPreEnd, lunchEntryStart, lunchEntryEnd;
   datetime asiaEntryStart, asiaEntryEnd, asiaFibEnd, ldnEntryStart, ldnEntryEnd, legLdnFibEnd;
   datetime ldnFibEnd, nyFibEnd, lunchFibEnd;
   datetime asiaCloseT, ldnCloseT, lunchCloseT, nyCloseT;
};

struct STrade
{
   int      dir;
   string   model;
   double   entry, sl, tp1, tp2;
   bool     dual, tp1Hit, beActive, beOnTp1;
   string   grp;
   datetime entryTime, checkFrom, closeT;
   ulong    tk0, tk1;              // echte Positionen (0 = keine)
   string   riskBox, rewardBox, tp1Line;
};

// Pre-Range-Setup (London oder NY, eine State Machine)
class CSetup
{
public:
   int      state, dir, trades, invalidations, maxTrades;
   double   locPos, locGap;
   string   reason, tag, grp;
   bool     isNY, fibEligible;
   datetime sigTime, preEndT, entryStartT, entryEndT, fibEndT;
   double   swDistPct, obDepthPct, fibDepthPct;   // filters of this setup's own range
   // Liquiditäts-Filter (nur Modell 1)
   bool     liqSwept, fvgTapped, obTapped;
   double   liqLvl;
   // Modell 3: Drei-Kerzen-Engulfing
   bool     trioValid, trioSwept, sweepTrio, engArmed;
   int      trioAge;
   double   trioLo, trioTrig, trioLimit, trioExt, engLimit, engSL, engTP, engTP2, engRej;
   bool     engDual;
   datetime trioT;
   ulong    engTk0, engTk1;
   // Modell 4: FVG-Inversion
   bool     fivArmed, fivDual, brkOpen;
   double   fivLimit, fivSL, fivTP, fivTP2;
   int      brkBars, fivZone;
   datetime brkFrom, brkTo;
   ulong    fivTk0, fivTk1;
   // --- Signal-Timeframe: jedes Setup baut sich seine eigenen Bestaetigungskerzen aus M1 ---
   int      sigTF;                                // 1 / 3 / 5 / 15 Minuten
   bool     aOpen, hasPrev;
   datetime aT, aEnd;
   double   aO, aH, aL, aC, prevH, prevL;
   // Zyklus
   datetime cycStart, cycMaxAllT, cycMinAllT, cycMaxPostT, cycMinPostT, sweepExtT;
   double   cycMaxAll, cycMinAll, cycMaxPost, cycMinPost, sweepExt;
   bool     asiaSwept, preSwept;
   string   sweepLbl;
   // OB
   bool     obValid;
   double   obHi, obLo, obBodyHi, obBodyLo;
   datetime obTime;
   string   obBox;
   // Reclaim / Fib
   datetime reclaimTime, fibArmTime;
   double   reclaimDepth, recExt, fibLimit;
   bool     recFixed, fibArmed;
   string   fibLine;
   ulong    fibTk0, fibTk1;

   void Init(int d, string tg, bool ny, string g)
   {
      dir = d; tag = tg; isNY = ny; grp = g; state = ST_IDLE; trades = 0; invalidations = 0; maxTrades = 2;
      locPos = NA; locGap = NA; reason = ""; sigTime = 0; preEndT = 0; entryStartT = 0; entryEndT = 0; fibEndT = 0;
      swDistPct = 0; obDepthPct = 25.0; fibDepthPct = 50.0;
      liqSwept = false; fvgTapped = false; obTapped = false; liqLvl = NA;
      trioValid = false; trioSwept = false; sweepTrio = false; engArmed = false; trioAge = 0;
      trioLo = NA; trioTrig = NA; trioLimit = NA; trioExt = NA;
      engLimit = NA; engSL = NA; engTP = NA; engTP2 = NA; engRej = NA; engDual = false;
      trioT = 0; engTk0 = 0; engTk1 = 0;
      fivArmed = false; fivDual = false; brkOpen = false;
      fivLimit = NA; fivSL = NA; fivTP = NA; fivTP2 = NA;
      brkBars = 0; fivZone = -1; brkFrom = 0; brkTo = 0; fivTk0 = 0; fivTk1 = 0;
      sigTF = 5; aOpen = false; hasPrev = false; aT = 0; aEnd = 0;
      aO = NA; aH = NA; aL = NA; aC = NA; prevH = NA; prevL = NA;
      ResetCycle(0);
   }
   // M1-Kerze in die laufende Signal-Kerze einrechnen (t = lokale Zeit)
   void SigAdd(datetime t, double o, double h, double l, double c)
   {
      int sec = (sigTF < 1 ? 5 : sigTF) * 60;
      datetime bs = (datetime)(((long)t / sec) * sec);
      if(!aOpen || bs != aT) { aOpen = true; aT = bs; aEnd = bs + sec; aO = o; aH = h; aL = l; }
      else { aH = MathMax(aH, h); aL = MathMin(aL, l); }
      aC = c;
   }
   void ResetCycle(datetime st)
   {
      cycStart = st;
      cycMaxAll = NA; cycMinAll = NA; cycMaxPost = NA; cycMinPost = NA;
      cycMaxAllT = 0; cycMinAllT = 0; cycMaxPostT = 0; cycMinPostT = 0;
      asiaSwept = false; preSwept = false; sweepExt = NA; sweepExtT = 0; sweepLbl = "";
      obValid = false; obHi = NA; obLo = NA; obBodyHi = NA; obBodyLo = NA; obTime = 0; obBox = "";
      reclaimTime = 0; reclaimDepth = NA; recExt = NA; recFixed = false;
      fibArmed = false; fibLimit = NA; fibArmTime = 0; fibLine = ""; fibTk0 = 0; fibTk1 = 0; fibEligible = false;
      liqSwept = false; fvgTapped = false; obTapped = false; liqLvl = NA;
      sweepTrio = false;
   }
};

// Asia-OB-Setup (eine Instanz pro Richtung)
class CAsia
{
public:
   int      dir, state, invalidations;
   string   reason, sweepLbl, obBox;
   datetime sigTime, cycStart, extT, obTime;
   double   ext, obHi, obLo, obBodyHi, obBodyLo;
   bool     swept, obValid;

   void Init(int d, datetime cs)
   {
      dir = d; state = AS_WAIT_RANGE; invalidations = 0; reason = "Warte auf Asia Range"; sigTime = 0;
      ResetCycle(cs);
   }
   void ResetCycle(datetime st)
   {
      cycStart = st; ext = NA; extT = 0; swept = false; sweepLbl = "";
      obValid = false; obHi = NA; obLo = NA; obBodyHi = NA; obBodyLo = NA; obTime = 0; obBox = "";
   }
};

string StateName(int st)
{
   switch(st)
   {
      case ST_IDLE: return "IDLE";          case ST_BUILD_ASIA: return "BUILD ASIA";
      case ST_BUILD_PRE: return "BUILD PRE"; case ST_WAIT_SWEEP: return "WAIT SWEEP";
      case ST_WAIT_RECLAIM: return "WAIT RECLAIM"; case ST_WAIT_ENTRY: return "WAIT ENTRY";
      case ST_CUTOFF: return "CUTOFF";      case ST_MAX_TRADES: return "MAX TRADES";
      case ST_INVALID_LOC: return "INVALID LOC"; case ST_NO_DATA: return "NO DATA";
   }
   return "?";
}
string AsiaStateName(int st)
{
   switch(st)
   {
      case AS_WAIT_RANGE: return "WAIT RANGE"; case AS_WAIT_SWEEP: return "WAIT SWEEP";
      case AS_WAIT_RECLAIM: return "WAIT OB-RECLAIM"; case AS_CUTOFF: return "FENSTER ENDE";
      case AS_MAX_TRADES: return "MAX TRADES";
   }
   return "?";
}

//====================================================================================
// 5. ENGINE PRO SYMBOL
//====================================================================================
class CEngine
{
public:
   string   sym;
   bool     draw, live, m1Seen;
   datetime lastM5;
   int      dayKey, digits;
   SSess    ss;
   SRange   asiaR, preR, nyPreR, lunchR;
   string   asiaBox, preBox, nyBox, lunchBox;
   bool     asiaLbl, preLbl, nyLbl, lunchLbl;
   CSetup   ldn, nyS, nyL, luS, luL, asS2, asL2, ldS, ldL;   // asS2/asL2 = Asia range setup, ldS/ldL = London range setup
   CAsia    asS, asL;
   int      asiaCnt, nyCnt, lunchCnt, ldnCnt;
   SLvl     swHi[], swLo[];
   SZone    fvgs[], obz[];
   int      obBullIdx, obBearIdx;                 // aktive OB-Kandidaten
   datetime fvgSeen[4];                           // zuletzt verarbeitete HTF-Bar je Timeframe
   int      engACnt, engLCnt, engLuCnt, engNCnt;  // eigene Budgets Modell 3
   int      fivACnt, fivLCnt, fivLuCnt, fivNCnt;  // eigene Budgets Modell 4
   int      daySL, dayTP;          // Tagesbilanz für die Stopp-Regeln
   int      orphanN;               // Zähler für das Orphan-Sicherheitsnetz
   bool     lockAsia, lockLdn, lockLunch, lockNy;
   STrade   trades[];

   //--- Init -----------------------------------------------------------------------
   void Init(string s)
   {
      sym = s; draw = (s == _Symbol); live = false; m1Seen = false;
      lastM5 = 0; dayKey = 0;
      digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      daySL = 0; dayTP = 0;
      engACnt = 0; engLCnt = 0; engLuCnt = 0; engNCnt = 0;
      fivACnt = 0; fivLCnt = 0; fivLuCnt = 0; fivNCnt = 0;
      asiaR.Reset(); preR.Reset(); nyPreR.Reset(); lunchR.Reset();
      asiaBox = ""; preBox = ""; nyBox = ""; lunchBox = "";
      asiaLbl = false; preLbl = false; nyLbl = false; lunchLbl = false;
      ldn.Init(0, "PRE", false, "LDN");
      nyS.Init(-1, "NY", true, "NY");   nyL.Init(1, "NY", true, "NY");
      luS.Init(-1, "LUNCH", true, "LUNCH"); luL.Init(1, "LUNCH", true, "LUNCH");
      asS2.Init(-1, "ASIA", true, "ASIA");  asL2.Init(1, "ASIA", true, "ASIA");
      ldS.Init(-1, "LONDON", true, "LDN");  ldL.Init(1, "LONDON", true, "LDN");
      asS.Init(-1, 0); asL.Init(1, 0);
      asiaCnt = 0; nyCnt = 0; lunchCnt = 0; ldnCnt = 0;
      daySL = 0; dayTP = 0; orphanN = 0;
      ArrayResize(swHi, 0); ArrayResize(swLo, 0); ArrayResize(fvgs, 0); ArrayResize(obz, 0);
      obBullIdx = -1; obBearIdx = -1;
      for(int i = 0; i < 4; i++) fvgSeen[i] = 0;
      engACnt = 0; engLCnt = 0; engLuCnt = 0; engNCnt = 0;
      fivACnt = 0; fivLCnt = 0; fivLuCnt = 0; fivNCnt = 0;
      lockAsia = false; lockLdn = false; lockLunch = false; lockNy = false;
      ArrayResize(trades, 0);
   }

   string Px(double v)  { return IsNa(v) ? "–" : DoubleToString(v, digits); }
   string Pct(double v) { return IsNa(v) ? "–" : DoubleToString(v, 1) + "%"; }
   bool   CanDraw()     { return draw; }
   bool   UseOB(string tag)  { if(!InpUseOB)  return false;
                               if(tag == "ASIA")   return InpAsiaOB;
                               if(tag == "LONDON") return InpLdnOB;
                               if(tag == "LUNCH")  return InpLunOB;
                               if(tag == "NY")     return InpNyOB;
                               return true; }                                   // "PRE" = legacy London
   bool   UseFib(string tag) { if(!InpUseFib) return false;
                               if(tag == "ASIA")   return InpAsiaFib;
                               if(tag == "LONDON") return InpLdnFib;
                               if(tag == "LUNCH")  return InpLunFib;
                               if(tag == "NY")     return InpNyFib;
                               return true; }
   bool   CanTrade()    { return live && InpMode == MODE_AUTO; }

   double NP(double p)
   {
      double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(ts > 0) p = MathRound(p / ts) * ts;
      return NormalizeDouble(p, digits);
   }
   double NormLot(double v)
   {
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      if(step > 0) v = MathFloor(v / step + 1e-9) * step;
      if(v < mn) v = mn;                   // G5: Mindestlot eröffnen
      if(mx > 0 && v > mx) v = mx;
      return NormalizeDouble(v, 8);
   }
   double CalcLots(double entry, double sl)
   {
      double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double ts   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double dist = MathAbs(entry - sl);
      if(dist <= 0 || ts <= 0 || tv <= 0) return NormLot(0);
      double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
      return NormLot(riskMoney / (dist / ts * tv));
   }

   //--- Alerts ----------------------------------------------------------------------
   void Notify(string msg)
   {
      if(!live) return;
      if(MQLInfoInteger(MQL_TESTER)) { Print(msg); return; }
      if(InpAlertPopup) Alert(msg);
      if(InpAlertPush)  SendNotification(StringSubstr(msg, 0, 255));
   }

   //--- Sperren ---------------------------------------------------------------------
   int  CntGet(string grp) { return grp == "LDN" ? ldnCnt : grp == "LUNCH" ? lunchCnt : grp == "NY" ? nyCnt : asiaCnt; }
   datetime CloseTimeOf(string grp)
   {
      if(grp == "ASIA")  return ss.asiaCloseT;
      if(grp == "LDN")   return ss.ldnCloseT;
      if(grp == "LUNCH") return ss.lunchCloseT;
      if(grp == "NY")    return ss.nyCloseT;
      return 0;
   }
   // Tagesergebnis verbuchen: nach X Stops oder einem vollen Ziel ist der Tag zu Ende
   void DayResult(string res)
   {
      if(res == "SL") daySL++;
      if(res == "TP2 ✓" || res == "TP ✓") dayTP++;
      if((InpDayMaxSL > 0 && daySL >= InpDayMaxSL) || (InpDayStopTP && dayTP >= 1))
      { lockAsia = true; lockLdn = true; lockLunch = true; lockNy = true; }
   }
   void CntInc(string grp)
   {
      if(grp == "LDN") ldnCnt++; else if(grp == "LUNCH") lunchCnt++; else if(grp == "NY") nyCnt++; else asiaCnt++;
   }
   bool IsLocked(string grp)
   {
      if(grp == "ASIA")  return lockAsia  || (InpShareAsiaLdn && lockLdn);
      if(grp == "LDN")   return lockLdn   || (InpShareAsiaLdn && lockAsia);
      if(grp == "LUNCH") return lockLunch || (InpPrevLocksLunch && (lockAsia || lockLdn));
      if(grp == "NY")    return lockNy    || (InpLdnLocksNY && (lockAsia || lockLdn || lockLunch));
      return false;
   }
   void SetLockGrp(string grp)
   {
      if(grp == "ASIA") lockAsia = true; else if(grp == "LDN") lockLdn = true;
      else if(grp == "LUNCH") lockLunch = true; else if(grp == "NY") lockNy = true;
   }
   // No-Trade-Zone um die 50 %-Marke
   bool InNoTradeZone(SRange &r, double price)
   {
      double rng = r.hi - r.lo;
      if(!InpUseNoTrade || rng <= 0 || IsNa(price)) return false;
      double pos = (price - r.lo) / rng * 100.0;
      return MathAbs(pos - 50.0) <= InpNoTradeZone;
   }

   // --- Richtungsfilter: globaler Schalter + Symbol-Listen -----------------------------
   bool InSymList(string list)
   {
      if(StringLen(list) == 0) return false;
      string l = list; StringReplace(l, " ", "");
      string parts[];
      int n = StringSplit(l, ',', parts);
      for(int i = 0; i < n; i++) if(parts[i] == sym) return true;
      return false;
   }
   // +1 long erlaubt / -1 short erlaubt
   bool DirAllowed(int d)
   {
      if(InSymList(InpLongOnlySyms))  return d == 1;
      if(InSymList(InpShortOnlySyms)) return d == -1;
      if(InpDirFilter == DIRF_LONG)   return d == 1;
      if(InpDirFilter == DIRF_SHORT)  return d == -1;
      return true;
   }

   bool Allowed(int d, string grp)
   {
      if(!DirAllowed(d)) return false;
      if(IsLocked(grp)) return false;
      if(InpAllowCounter) return true;
      for(int i = 0; i < ArraySize(trades); i++)
         if(trades[i].dir == -d) return false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         if((d == 1 && type == POSITION_TYPE_SELL) || (d == -1 && type == POSITION_TYPE_BUY)) return false;
      }
      return true;
   }
   string BlockReason(string grp) { return IsLocked(grp) ? "TP erreicht – Session gesperrt" : "Gegenposition offen"; }
   string BlockReason(int d, string grp)
   {
      if(!DirAllowed(d)) return (d == 1 ? "Long" : "Short") + " per Richtungsfilter gesperrt";
      return BlockReason(grp);
   }
   double RiskMoneyOf(double entry, double sl, double lots)
   {
      double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(ts <= 0 || tv <= 0) return 0;
      return MathAbs(entry - sl) / ts * tv * lots;
   }

   //--- Orders ----------------------------------------------------------------------
   ulong SendMarket(int dir, double lots, double sl, double tp, string cmt)
   {
      g_trade.SetExpertMagicNumber(InpMagic);
      g_trade.SetDeviationInPoints(InpSlippage);
      g_trade.SetTypeFillingBySymbol(sym);
      bool ok = dir == 1 ? g_trade.Buy(lots, sym, 0, NP(sl), NP(tp), cmt) : g_trade.Sell(lots, sym, 0, NP(sl), NP(tp), cmt);
      if(!ok) { PrintFormat("[%s] Order fehlgeschlagen (%s): %d %s", sym, cmt, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()); return 0; }
      ulong deal = g_trade.ResultDeal();
      if(deal > 0 && HistoryDealSelect(deal)) return (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      return g_trade.ResultOrder();
   }
   ulong SendLimit(int dir, double lots, double price, double sl, double tp, string cmt)
   {
      g_trade.SetExpertMagicNumber(InpMagic);
      g_trade.SetDeviationInPoints(InpSlippage);
      g_trade.SetTypeFillingBySymbol(sym);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID), ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      // Limit bereits erreicht → sofort Market
      if((dir == -1 && bid >= price) || (dir == 1 && ask <= price)) return SendMarket(dir, lots, sl, tp, cmt);
      bool ok = dir == 1 ? g_trade.BuyLimit(lots, NP(price), sym, NP(sl), NP(tp), ORDER_TIME_GTC, 0, cmt)
                         : g_trade.SellLimit(lots, NP(price), sym, NP(sl), NP(tp), ORDER_TIME_GTC, 0, cmt);
      if(!ok) { PrintFormat("[%s] Limit fehlgeschlagen (%s): %d %s", sym, cmt, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()); return 0; }
      return g_trade.ResultOrder();
   }
   double SpreadAdj(int dir, double sl)
   {
      if(!InpSpreadSL) return sl;
      double spr = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
      return dir == -1 ? sl + spr : sl - spr;
   }
   void PlaceMarket(STrade &tr)
   {
      double price = tr.dir == 1 ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
      double sl    = SpreadAdj(tr.dir, tr.sl);
      double lots  = CalcLots(price, sl);
      if(tr.dual)
      {
         double q1 = NormLot(lots * InpTp1Split / 100.0);
         double q2 = NormLot(lots - q1);
         tr.tk0 = SendMarket(tr.dir, q1, sl, tr.tp1, tr.model + " TP1");
         tr.tk1 = SendMarket(tr.dir, q2, sl, tr.tp2, tr.model + " TP2");
      }
      else tr.tk0 = SendMarket(tr.dir, lots, sl, tr.tp1, tr.model);
   }
   void DeleteOrClose(ulong tk)
   {
      if(tk == 0) return;
      if(OrderSelect(tk)) g_trade.OrderDelete(tk);
      else if(PositionSelectByTicket(tk)) g_trade.PositionClose(tk);
   }
   void DeletePending(ulong tk) { if(tk > 0 && OrderSelect(tk)) g_trade.OrderDelete(tk); }
   // Gesamtvolumen eigener Positionen in diesem Symbol
   double OpenVolume()
   {
      double v = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         v += PositionGetDouble(POSITION_VOLUME);
      }
      return v;
   }
   void CloseAllOwn()
   {
      g_trade.SetExpertMagicNumber(InpMagic);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         g_trade.PositionClose(tk);
      }
      PrintFormat("[%s] Orphan-Flatten: nicht verfolgte Position geschlossen", sym);
   }
   void MoveToBE(ulong tk)
   {
      if(tk == 0 || !PositionSelectByTicket(tk)) return;
      g_trade.SetExpertMagicNumber(InpMagic);
      g_trade.PositionModify(tk, NP(PositionGetDouble(POSITION_PRICE_OPEN)), PositionGetDouble(POSITION_TP));
   }

   //--- Visuals Trade ---------------------------------------------------------------
   void DrawTrade(STrade &tr, string txt)
   {
      tr.riskBox = ""; tr.rewardBox = ""; tr.tp1Line = "";
      if(!CanDraw()) return;
      datetime t = L2S(tr.entryTime);
      if(InpShowTrades)
      {
         tr.riskBox   = DRect(t, tr.entry, t + 60, tr.sl, InpColRisk);
         tr.rewardBox = DRect(t, tr.entry, t + 60, tr.tp2, InpColReward);
         if(tr.dual) tr.tp1Line = DLine(t, tr.tp1, t + 60, tr.tp1, InpColFib, STYLE_DASH);
         DText(t, tr.tp2, tr.dual ? "TP2 · TARGET" : "TARGET", InpColBull, ANCHOR_RIGHT);
         if(tr.dual) DText(t, tr.tp1, "TP1", InpColFib, ANCHOR_RIGHT);
         DText(t, tr.entry, txt, tr.dir == 1 ? InpColBull : InpColBear, tr.dir == 1 ? ANCHOR_UPPER : ANCHOR_LOWER, 9);
      }
   }
   void CloseTradeVis(STrade &tr, datetime t, double px, string res)
   {
      DayResult(res);
      if(!CanDraw()) return;
      datetime s = L2S(t);
      MoveRight(tr.riskBox, s); MoveRight(tr.rewardBox, s); MoveRight(tr.tp1Line, s);
      if(InpShowTrades)
      {
         color c = res == "SL" ? InpColBear : res == "BE" ? clrGray : res == "TP1 ✓ / SL" ? InpColSweep : InpColBull;
         DText(s, px, res, c, ANCHOR_LEFT, 9);
      }
   }
   void RemoveTrade(int idx)
   {
      int n = ArraySize(trades);
      for(int i = idx; i < n - 1; i++) trades[i] = trades[i + 1];
      ArrayResize(trades, n - 1);
   }


   //--- Trade-Management (M1) -------------------------------------------------------
   void ManageTrades(datetime t, double h, double l)
   {
      for(int i = ArraySize(trades) - 1; i >= 0; i--)
      {
         if(t < trades[i].checkFrom) continue;
         // Zeit-Exit: offener Trade dieser Range wird zum Marktpreis geschlossen
         if(trades[i].closeT > 0 && t >= trades[i].closeT)
         {
            if(CanTrade()) { DeleteOrClose(trades[i].tk0); DeleteOrClose(trades[i].tk1); }
            CloseTradeVis(trades[i], t, trades[i].sl, "TIME EXIT");
            RemoveTrade(i);
            continue;
         }
         bool isShort  = trades[i].dir == -1;
         bool slHit    = isShort ? h >= trades[i].sl  : l <= trades[i].sl;
         bool tp1Touch = isShort ? l <= trades[i].tp1 : h >= trades[i].tp1;
         bool tp2Touch = isShort ? l <= trades[i].tp2 : h >= trades[i].tp2;
         if(slHit)    // SL und TP in derselben M1-Kerze → konservativ SL
         {
            CloseTradeVis(trades[i], t, trades[i].sl, !trades[i].tp1Hit ? "SL" : trades[i].beActive ? "BE" : "TP1 ✓ / SL");
            RemoveTrade(i);
         }
         else if(!trades[i].dual)
         {
            if(tp1Touch)
            {
               CloseTradeVis(trades[i], t, trades[i].tp1, "TP ✓");
               if(InpLockMode != LOCK_OFF) SetLockGrp(trades[i].grp);
               RemoveTrade(i);
            }
         }
         else
         {
            if(!trades[i].tp1Hit && tp1Touch)
            {
               trades[i].tp1Hit = true;
               if(InpLockMode == LOCK_FIRST) SetLockGrp(trades[i].grp);
               if(trades[i].beOnTp1)
               {
                  trades[i].sl = trades[i].entry;
                  trades[i].beActive = true;
                  if(CanTrade()) MoveToBE(trades[i].tk1);
               }
               if(CanDraw() && InpShowTrades) DText(L2S(t), trades[i].tp1, "TP1 ✓", InpColBull);
            }
            if(trades[i].tp1Hit && tp2Touch)
            {
               CloseTradeVis(trades[i], t, trades[i].tp2, "TP2 ✓");
               if(InpLockMode != LOCK_OFF) SetLockGrp(trades[i].grp);
               RemoveTrade(i);
            }
         }
      }
   }

   //--- Hilfsfunktionen Setup -------------------------------------------------------
   double Depth(int d, SRange &pre, double p)
   {
      double r = pre.hi - pre.lo;
      if(r <= 0 || IsNa(p)) return NA;
      return (d == -1 ? pre.hi - p : p - pre.lo) / r * 100.0;
   }
   void CancelFib(CSetup &s, datetime t)
   {
      if(s.fibArmed)
      {
         if(CanDraw()) MoveRight(s.fibLine, L2S(t));
         DeletePending(s.fibTk0); DeletePending(s.fibTk1);
      }
      s.fibTk0 = 0; s.fibTk1 = 0; s.fibArmed = false;
   }
   void ResetSetupCycle(CSetup &s, datetime st)
   {
      if(CanDraw()) MoveRight(s.obBox, L2S(st));
      s.ResetCycle(st);
   }
   void Invalidate(CSetup &s, SRange &pre, datetime t, string why)
   {
      CancelFib(s, t);
      ResetSetupCycle(s, t + 60);
      s.state = ST_WAIT_SWEEP;
      s.invalidations++;
      s.reason = why + " – warte auf neue Manipulation";
   }
   void ValidateLocation(int &dir, double &pos, double &gap)
   {
      double rA = asiaR.hi - asiaR.lo;
      dir = 0; pos = NA; gap = NA;
      if(rA <= 0) return;
      double mid  = (preR.hi + preR.lo) / 2.0;
      pos = (mid - asiaR.lo) / rA * 100.0;
      double gapS = MathMax(0.0, preR.lo - asiaR.hi) / rA * 100.0;
      double gapL = MathMax(0.0, asiaR.lo - preR.hi) / rA * 100.0;
      bool coversBoth = preR.hi >= asiaR.hi && preR.lo <= asiaR.lo;
      bool isShort = pos >= InpLocShortMin && pos <= InpLocShortMax && gapS <= InpLocMaxGap;
      bool isLong  = pos >= InpLocLongMin  && pos <= InpLocLongMax  && gapL <= InpLocMaxGap;
      dir = (coversBoth || (isShort && isLong)) ? 0 : isShort ? -1 : isLong ? 1 : 0;
      gap = pos >= 50 ? gapS : gapL;
   }
   //------------------------------------------------------------------------------------
   //  TP-MODELL (zentral fuer alle Entry-Modelle)
   //  d = +1 long / -1 short.  Rueckgabe: tp1, tp2, dual.
   //  TP_DUAL  : TP1 = InpTp1Level %, TP2 = InpTp2Level % der Range
   //  TP_FULL  : Single TP auf InpTp2Level %
   //  TP_HALF  : Single TP auf InpTp1Level %
   //  TP_CUSTR : TP1 = volle Range (Gegenseite), TP2 = InpTp2R * R ab Entry (Runner).
   //             Liegt der R-Ziel naeher als die Range, werden die beiden Level
   //             getauscht, damit TP1 immer das naehere Bein ist.
   //------------------------------------------------------------------------------------
   void TpLevels(int d, SRange &pre, double entry, double sl, double &tp1, double &tp2, bool &dual)
   {
      double rng  = pre.hi - pre.lo;
      double full = d == 1 ? pre.hi : pre.lo;                                   // volle Range
      double lvl1 = d == 1 ? pre.lo + InpTp1Level / 100.0 * rng : pre.hi - InpTp1Level / 100.0 * rng;
      double lvl2 = d == 1 ? pre.lo + InpTp2Level / 100.0 * rng : pre.hi - InpTp2Level / 100.0 * rng;

      if(InpTpMode == TP_CUSTR)
      {
         double slDist = MathAbs(entry - sl);
         double rTgt   = IsNa(sl) || slDist <= 0 ? full
                                                 : (d == 1 ? entry + InpTp2R * slDist
                                                           : entry - InpTp2R * slDist);
         // Ohne "NoCap" wird der Runner an der Range-Gegenseite gedeckelt
         if(!InpCustRNoCap) rTgt = d == 1 ? MathMin(rTgt, full) : MathMax(rTgt, full);
         double near = d == 1 ? MathMin(full, rTgt) : MathMax(full, rTgt);
         double far  = d == 1 ? MathMax(full, rTgt) : MathMin(full, rTgt);
         tp1  = near;
         tp2  = far;
         dual = MathAbs(far - near) > SymbolInfoDouble(sym, SYMBOL_POINT);       // sonst nur ein Bein
         if(!dual) tp2 = tp1;
         return;
      }
      dual = InpTpMode == TP_DUAL;
      tp1  = InpTpMode == TP_FULL ? lvl2 : lvl1;
      tp2  = dual ? lvl2 : tp1;
   }

   void PreLevels(CSetup &s, SRange &ref, SRange &pre, double entry, bool &ok, double &sl, double &tp1, double &tp2, bool &dual)
   {
      int d = s.dir;
      double buf = InpSlBuf / 100.0 * (ref.hi - ref.lo);
      sl = IsNa(s.sweepExt) ? NA : (d == -1 ? s.sweepExt + buf : s.sweepExt - buf);
      double rng  = pre.hi - pre.lo;
      TpLevels(d, pre, entry, sl, tp1, tp2, dual);
      bool lage    = !IsNa(sl) && (d == -1 ? (entry < sl && entry > tp1) : (entry > sl && entry < tp1));
      double slDist = MathAbs(entry - sl);
      double rr     = slDist > 0 ? MathAbs(tp1 - entry) / slDist : 0;
      bool rrOK    = InpMinRR    <= 0 || rr >= InpMinRR;
      bool slOK    = InpMaxSlPct <= 0 || (rng > 0 && slDist <= InpMaxSlPct / 100.0 * rng);
      ok = lage && rrOK && slOK;
   }

   //====================================================================================
   //  MODELL 3 (Drei-Kerzen-Engulfing) und MODELL 4 (FVG-Inversion)
   //====================================================================================
   // Ziel-Level nach dem globalen TP-Modell, gemessen von der gesweepten Range-Seite
   bool LevelsFor(int d, SRange &pre, double entry, double sl, double &tp1, double &tp2, bool &dual)
   {
      double rng  = pre.hi - pre.lo;
      TpLevels(d, pre, entry, sl, tp1, tp2, dual);
      bool lage     = d == 1 ? (entry > sl && entry < tp1) : (entry < sl && entry > tp1);
      double slDist = MathAbs(entry - sl);
      double rr     = slDist > 0 ? MathAbs(tp1 - entry) / slDist : 0;
      bool rrOK     = InpMinRR    <= 0 || rr >= InpMinRR;
      bool slOK     = InpMaxSlPct <= 0 || (rng > 0 && slDist <= InpMaxSlPct / 100.0 * rng);
      return lage && rrOK && slOK;
   }
   bool EngUse(string tag) { if(!InpUseEng) return false;
      if(tag == "ASIA") return InpEngAsia; if(tag == "LONDON") return InpEngLdn;
      if(tag == "LUNCH") return InpEngLun; if(tag == "NY") return InpEngNy; return false; }
   bool FivUse(string tag) { if(!InpUseFiv) return false;
      if(tag == "ASIA") return InpFivAsia; if(tag == "LONDON") return InpFivLdn;
      if(tag == "LUNCH") return InpFivLun; if(tag == "NY") return InpFivNy; return false; }
   int  EngCntGet(string grp) { if(InpEngOwnMax <= 0) return CntGet(grp);
      if(grp == "ASIA") return engACnt; if(grp == "LDN") return engLCnt;
      if(grp == "LUNCH") return engLuCnt; return engNCnt; }
   void EngCntInc(string grp) { if(InpEngOwnMax <= 0) { CntInc(grp); return; }
      if(grp == "ASIA") engACnt++; else if(grp == "LDN") engLCnt++;
      else if(grp == "LUNCH") engLuCnt++; else engNCnt++; }
   int  FivCntGet(string grp) { if(InpFivOwnMax <= 0) return CntGet(grp);
      if(grp == "ASIA") return fivACnt; if(grp == "LDN") return fivLCnt;
      if(grp == "LUNCH") return fivLuCnt; return fivNCnt; }
   void FivCntInc(string grp) { if(InpFivOwnMax <= 0) { CntInc(grp); return; }
      if(grp == "ASIA") fivACnt++; else if(grp == "LDN") fivLCnt++;
      else if(grp == "LUNCH") fivLuCnt++; else fivNCnt++; }

   void CancelEng(CSetup &s) { DeletePending(s.engTk0); DeletePending(s.engTk1);
      s.engTk0 = 0; s.engTk1 = 0; s.engArmed = false; s.engLimit = NA; }
   void CancelFiv(CSetup &s) { DeletePending(s.fivTk0); DeletePending(s.fivTk1);
      s.fivTk0 = 0; s.fivTk1 = 0; s.fivArmed = false; s.fivLimit = NA; }

   // Limit platzieren (ein oder zwei Beine) und Tickets zurückgeben
   void ArmLimit(int d, double lim, double sl, double tp1, double tp2, bool dual, string cmt, ulong &tk0, ulong &tk1)
   {
      tk0 = 0; tk1 = 0;
      if(!CanTrade()) return;
      double rsl  = SpreadAdj(d, sl);
      double lots = CalcLots(lim, rsl);
      if(dual)
      {
         double q1 = NormLot(lots * InpTp1Split / 100.0);
         double q2 = NormLot(lots - q1);
         tk0 = SendLimit(d, q1, lim, rsl, tp1, cmt + " TP1");
         tk1 = SendLimit(d, q2, lim, rsl, tp2, cmt + " TP2");
      }
      else tk0 = SendLimit(d, lots, lim, rsl, tp1, cmt);
   }
   // Trade-Datensatz für ein gefülltes Limit anlegen
   void RegisterLimitTrade(CSetup &s, string model, double entry, double sl, double tp1, double tp2,
                           bool dual, ulong tk0, ulong tk1, datetime t)
   {
      STrade tr;
      tr.dir = s.dir; tr.model = model; tr.entry = entry; tr.sl = sl; tr.tp1 = tp1; tr.tp2 = tp2; tr.dual = dual;
      tr.tp1Hit = false; tr.beActive = false; tr.beOnTp1 = InpBE; tr.grp = s.grp;
      tr.entryTime = t; tr.checkFrom = t; tr.closeT = CloseTimeOf(s.grp); tr.tk0 = tk0; tr.tk1 = tk1;
      DrawTrade(tr, (s.dir == 1 ? "A+ LONG ↑ " : "A+ SHORT ↓ ") + model);
      Notify((s.dir == 1 ? "A+ LONG " : "A+ SHORT ") + sym + " | " + model + " | Entry " + Px(entry) + " | SL " + Px(sl));
      int n = ArraySize(trades); ArrayResize(trades, n + 1); trades[n] = tr;
      s.trades++;
      s.sigTime = t;
   }

   // Richtung einer Kerze mit Stärkefilter: +1 / -1 / 0 (Doji oder Inside)
   int CdirAt(MqlRates &r[], int i)
   {
      if(i <= 0 || i >= ArraySize(r)) return 0;
      double rng = r[i].high - r[i].low, body = MathAbs(r[i].close - r[i].open);
      bool big = rng > 0 && body >= InpEngBodyPct / 100.0 * rng;
      bool ins = r[i].high <= r[i - 1].high && r[i].low >= r[i - 1].low;
      if(!big || ins) return 0;
      return r[i].close > r[i].open ? 1 : (r[i].close < r[i].open ? -1 : 0);
   }

   // ---- Modell 3: Bar-Close-Logik ---------------------------------------------------
   void EngStep(CSetup &s, SRange &pre, bool trio, double tExt, double tFar, double tBodyExt,
                double tLastBody, bool sameDir, double c, double l, double h,
                datetime tOpen, datetime tClose, bool inWin)
   {
      bool detWin = tClose > s.entryStartT && tOpen < MathMax(s.fibEndT, s.entryEndT);
      if(!EngUse(s.tag) || !pre.complete || IsNa(pre.hi) || !detWin) return;
      int    d   = s.dir;
      double rng = pre.hi - pre.lo;
      if(trio)
      {
         bool   outside = d == 1 ? c < pre.lo : c > pre.hi;
         double gap     = d == 1 ? pre.lo - tExt : tExt - pre.hi;
         if(outside && gap > 0 && gap <= InpEngDistPct / 100.0 * rng)
         {
            CancelEng(s);
            s.trioValid = true; s.sweepTrio = true; s.trioSwept = false; s.trioAge = 0;
            s.trioLo = tExt; s.trioTrig = tBodyExt;
            s.trioLimit = InpEngLastBody ? tLastBody : tBodyExt;
            s.trioExt = tExt; s.trioT = tOpen;
            s.reason = s.tag + ": 3 candles registered";
            if(CanDraw() && InpShowOB)
               DRect(L2S(tOpen) - 900, MathMax(s.trioTrig, s.trioLo), L2S(tClose), MathMin(s.trioTrig, s.trioLo), InpColSweep);
         }
         return;
      }
      if(!s.trioValid) return;
      s.trioAge++;
      if(s.trioAge == 1 && sameDir && !InpEngRolling)
      { CancelEng(s); s.trioValid = false; s.reason = s.tag + ": 4th candle - setup discarded"; return; }
      if(d == 1) { s.trioExt = MathMin(s.trioExt, l); if(l < s.trioLo) s.trioSwept = true; }
      else       { s.trioExt = MathMax(s.trioExt, h); if(h > s.trioLo) s.trioSwept = true; }
      if(d == 1 ? c < s.trioLo : c > s.trioLo)
      { CancelEng(s); s.trioValid = false; s.reason = s.tag + ": 3-candle setup invalidated"; return; }
      if(s.engArmed) return;
      bool trig = (!InpEngNeedSweep || s.trioSwept) && (d == 1 ? c > s.trioTrig : c < s.trioTrig);
      if(!trig) return;
      if(!inWin) { s.reason = s.tag + " 3C engulf ignored: outside the entry window"; return; }
      double lim = s.trioLimit;
      double sl  = d == 1 ? s.trioExt - InpSlBuf / 100.0 * rng : s.trioExt + InpSlBuf / 100.0 * rng;
      double tp1, tp2; bool dual;
      bool lvOk = LevelsFor(d, pre, lim, sl, tp1, tp2, dual);
      string gwhy = "";
      bool guards = GuardsOK(RiskMoneyOf(lim, sl, CalcLots(lim, sl)), gwhy);
      if(!Allowed(d, s.grp))                    { s.reason = s.tag + " 3C blocked: " + BlockReason(d, s.grp); return; }
      if(InNoTradeZone(pre, lim))               { s.reason = s.tag + " 3C blocked: no-trade zone"; return; }
      if(EngCntGet(s.grp) >= (InpEngOwnMax > 0 ? InpEngOwnMax : s.maxTrades))
                                                { s.reason = s.tag + " 3C blocked: max. trades"; return; }
      if(!guards)                               { s.reason = s.tag + " 3C blocked: " + gwhy; return; }
      if(!lvOk)                                 { s.reason = s.tag + " 3C rejected: level / RR"; return; }
      s.engArmed = true; s.engLimit = lim; s.engSL = sl; s.engTP = tp1; s.engTP2 = tp2; s.engDual = dual;
      s.engRej = InpEngRejCancel ? RejLevel(d, lim, tp1) : NA;
      ArmLimit(d, lim, sl, tp1, tp2, dual, s.tag + " ENG", s.engTk0, s.engTk1);
      s.reason = s.tag + " 3C engulf limit @ " + Px(lim);
      if(CanDraw() && InpShowFib) DLine(L2S(tClose), lim, L2S(MathMax(s.fibEndT, s.entryEndT)), lim, InpColSweep, STYLE_SOLID, 2);
   }
   // Nächste Range-Kante zwischen Limit und Ziel
   double RejLevel(int d, double lim, double tp)
   {
      double best = NA;
      for(int k = 0; k < 8; k++)
      {
         double e = NA; bool cpl = false;
         if(k < 2)      { cpl = asiaR.complete;  e = (k % 2 == 0) ? asiaR.lo  : asiaR.hi; }
         else if(k < 4) { cpl = preR.complete;   e = (k % 2 == 0) ? preR.lo   : preR.hi; }
         else if(k < 6) { cpl = lunchR.complete; e = (k % 2 == 0) ? lunchR.lo : lunchR.hi; }
         else           { cpl = nyPreR.complete; e = (k % 2 == 0) ? nyPreR.lo : nyPreR.hi; }
         if(!cpl || IsNa(e)) continue;
         if(d == 1  && e > lim && e < tp && (IsNa(best) || e < best)) best = e;
         if(d == -1 && e < lim && e > tp && (IsNa(best) || e > best)) best = e;
      }
      return best;
   }

   // ---- Modell 4: Bar-Close-Logik ---------------------------------------------------
   void FivStep(CSetup &s, SRange &pre, double c, datetime tOpen, datetime tClose, bool inWin)
   {
      if(!FivUse(s.tag) || !pre.complete || IsNa(pre.hi)) return;
      int    d   = s.dir;
      double rng = pre.hi - pre.lo;
      // Ausbruchs-Fenster pflegen
      bool beyond = d == 1 ? c < pre.lo : c > pre.hi;
      if(!s.brkOpen)
      { if(beyond) { s.brkOpen = true; s.brkFrom = tOpen; s.brkTo = tClose; s.brkBars = 1; } }
      else
      {
         if(!beyond || s.brkBars >= InpFivBrkBars) s.brkOpen = false;
         else { s.brkBars++; s.brkTo = tClose; }
      }
      bool detWin = tClose > s.entryStartT && tOpen < MathMax(s.fibEndT, s.entryEndT);
      if(!detWin || s.fivArmed || !inWin) return;
      double mid = (pre.hi + pre.lo) / 2.0;
      double lvl = NA, opp = NA;
      int    zi  = -1;
      for(int i = 0; i < ArraySize(fvgs); i++)
      {
         if(!fvgs[i].inv || fvgs[i].used || fvgs[i].dir != -d || !TfOn(fvgs[i].tf, true)) continue;
         if(s.brkFrom == 0 || fvgs[i].seen < s.brkFrom || fvgs[i].seen > s.brkTo) continue;
         if(d == 1 && fvgs[i].top <= mid && pre.lo - fvgs[i].top <= InpFivDistPct / 100.0 * rng)
            if(IsNa(lvl) || fvgs[i].top > lvl) { lvl = fvgs[i].top; opp = fvgs[i].bot; zi = i; }
         if(d == -1 && fvgs[i].bot >= mid && fvgs[i].bot - pre.hi <= InpFivDistPct / 100.0 * rng)
            if(IsNa(lvl) || fvgs[i].bot < lvl) { lvl = fvgs[i].bot; opp = fvgs[i].top; zi = i; }
      }
      if(IsNa(lvl)) return;
      double sl = d == 1 ? opp - InpSlBuf / 100.0 * rng : opp + InpSlBuf / 100.0 * rng;
      double tp1, tp2; bool dual;
      bool lvOk = LevelsFor(d, pre, lvl, sl, tp1, tp2, dual);
      string gwhy = "";
      bool guards = GuardsOK(RiskMoneyOf(lvl, sl, CalcLots(lvl, sl)), gwhy);
      if(!Allowed(d, s.grp))        { s.reason = s.tag + " FVGI blocked: " + BlockReason(d, s.grp); return; }
      if(InNoTradeZone(pre, lvl))   { s.reason = s.tag + " FVGI blocked: no-trade zone"; return; }
      if(FivCntGet(s.grp) >= (InpFivOwnMax > 0 ? InpFivOwnMax : s.maxTrades))
                                    { s.reason = s.tag + " FVGI blocked: max. trades"; return; }
      if(!guards)                   { s.reason = s.tag + " FVGI blocked: " + gwhy; return; }
      if(!lvOk)                     { s.reason = s.tag + " FVGI rejected: level / RR"; return; }
      fvgs[zi].used = true;                      // jede invertierte FVG nur einmal
      s.fivArmed = true; s.fivLimit = lvl; s.fivSL = sl; s.fivTP = tp1; s.fivTP2 = tp2; s.fivDual = dual;
      s.fivZone = zi;
      ArmLimit(d, lvl, sl, tp1, tp2, dual, s.tag + " FVGI", s.fivTk0, s.fivTk1);
      s.reason = s.tag + " FVG inversion limit @ " + Px(lvl);
      if(CanDraw() && InpShowFib)
      {
         DLine(L2S(tClose), lvl, L2S(MathMax(s.fibEndT, s.entryEndT)), lvl, InpColReclaim, STYLE_SOLID, 2);
         DRect(L2S(fvgs[zi].invT), MathMax(lvl, opp), L2S(tClose), MathMin(lvl, opp), InpColReclaim);
      }
   }

   //--- Entry Pre-Setup (London / NY) -----------------------------------------------
   bool OpenTrade(CSetup &s, SRange &ref, SRange &pre, string model, double entry, datetime entryT, datetime checkFrom)
   {
      int d = s.dir;
      bool lvOk, dual; double sl, tp1, tp2;
      PreLevels(s, ref, pre, entry, lvOk, sl, tp1, tp2, dual);
      bool isFib   = model == s.tag + " FIB";
      bool allowed = Allowed(d, s.grp);
      bool ntz     = InNoTradeZone(pre, entry);
      string gwhy  = "";
      bool guards  = GuardsOK(RiskMoneyOf(entry, sl, CalcLots(entry, sl)), gwhy);
      bool ok      = lvOk && allowed && !ntz && guards && (!isFib || s.fibArmed);
      if(!ok)
      {
         s.reason = ntz     ? "Entry blockiert (" + model + "): No-Trade-Zone 50 %"
                  : !allowed ? "Entry blockiert (" + model + "): " + BlockReason(d, s.grp)
                  : !guards  ? "Entry blockiert (" + model + "): " + gwhy
                  : "Entry verworfen (" + model + "): Lage / RR-Filter / SL zu weit";
         return false;
      }
      if(s.grp == "NY")
      {
         if(d == -1 && nyL.fibArmed) CancelFib(nyL, entryT);
         if(d == 1  && nyS.fibArmed) CancelFib(nyS, entryT);
      }
      if(s.grp == "LUNCH")
      {
         if(d == -1 && luL.fibArmed) CancelFib(luL, entryT);
         if(d == 1  && luS.fibArmed) CancelFib(luS, entryT);
      }
      STrade tr;
      tr.dir = d; tr.model = model; tr.entry = entry; tr.sl = sl; tr.tp1 = tp1; tr.tp2 = tp2; tr.dual = dual;
      tr.tp1Hit = false; tr.beActive = false; tr.beOnTp1 = InpBE; tr.grp = s.grp;
      tr.entryTime = entryT; tr.checkFrom = checkFrom; tr.closeT = CloseTimeOf(s.grp); tr.tk0 = 0; tr.tk1 = 0;
      if(isFib)            { tr.tk0 = s.fibTk0; tr.tk1 = s.fibTk1; }
      else if(CanTrade())  PlaceMarket(tr);
      DrawTrade(tr, (d == 1 ? "A+ LONG ↑ " : "A+ SHORT ↓ ") + model);
      Notify((d == 1 ? "A+ LONG " : "A+ SHORT ") + sym + " | " + s.tag + "-Range | " + model +
             " | Entry " + Px(entry) + " | SL " + Px(sl) + (dual ? " | TP1 " + Px(tp1) + " | TP2 " + Px(tp2) : " | TP " + Px(tp1)));
      int n = ArraySize(trades); ArrayResize(trades, n + 1); trades[n] = tr;
      s.trades++;
      CntInc(s.grp);
      s.sigTime = entryT;
      s.fibTk0 = 0; s.fibTk1 = 0;               // gefüllte Fib-Orders nicht löschen
      CancelFib(s, entryT);
      ResetSetupCycle(s, checkFrom);            // Re-Entry nur nach neuem Sweep
      s.state  = CntGet(s.grp) >= s.maxTrades ? ST_MAX_TRADES : ST_WAIT_SWEEP;
      s.reason = "Trade " + IntegerToString(s.trades) + " eröffnet (" + model + ")";
      return true;
   }

   //--- London: pro M1 --------------------------------------------------------------
   void StepIntrabar(datetime t, double h, double l)
   {
      // Ranges and trade management run centrally in ProcessBar so that they also work
      // when this legacy setup is switched off.
      if(ldn.state == ST_BUILD_ASIA && t >= ss.asiaEnd)
      {
         if(asiaR.bars > 0) { asiaR.complete = true; ldn.state = ST_BUILD_PRE; ldn.reason = "Asia fertig – baue Pre-Range"; }
         else { ldn.state = ST_NO_DATA; ldn.reason = "Keine Daten im Asia-Fenster"; }
      }
      if(ldn.state == ST_BUILD_PRE && t >= ss.preEnd)
      {
         if(preR.bars > 0)
         {
            preR.complete = true;
            int d; double pos, gap;
            ValidateLocation(d, pos, gap);
            ldn.locPos = pos; ldn.locGap = gap;
            if(d != 0) { ldn.dir = d; ldn.state = ST_WAIT_SWEEP; ldn.reason = "Location " + (d == 1 ? "LONG" : "SHORT") + " – warte auf Sweep"; }
            else       { ldn.state = ST_INVALID_LOC; ldn.reason = "Pre-Range nicht an Asia-Kante"; }
         }
         else { ldn.state = ST_NO_DATA; ldn.reason = "Keine Daten im Pre-Range-Fenster"; }
      }

      if(ldn.state >= ST_BUILD_PRE && ldn.state <= ST_WAIT_ENTRY && t >= ss.asiaEnd && t >= ldn.cycStart)
      {
         if(IsNa(ldn.cycMaxAll) || h > ldn.cycMaxAll) { ldn.cycMaxAll = h; ldn.cycMaxAllT = t; }
         if(IsNa(ldn.cycMinAll) || l < ldn.cycMinAll) { ldn.cycMinAll = l; ldn.cycMinAllT = t; }
         if(t >= ss.preEnd)
         {
            if(IsNa(ldn.cycMaxPost) || h > ldn.cycMaxPost) { ldn.cycMaxPost = h; ldn.cycMaxPostT = t; }
            if(IsNa(ldn.cycMinPost) || l < ldn.cycMinPost) { ldn.cycMinPost = l; ldn.cycMinPostT = t; }
         }
      }

      if(ldn.state >= ST_WAIT_SWEEP && ldn.state <= ST_WAIT_ENTRY)
      {
         double dist  = InpLegSwDist / 100.0 * (asiaR.hi - asiaR.lo);
         bool   dsReq = InpDoubleSweep == DS_REQ;
         if(ldn.dir == -1)
         {
            ldn.asiaSwept = !IsNa(ldn.cycMaxAll)  && ldn.cycMaxAll  > asiaR.hi + dist;
            ldn.preSwept  = !IsNa(ldn.cycMaxPost) && ldn.cycMaxPost > preR.hi  + ldn.swDistPct / 100.0 * (preR.hi - preR.lo);
            ldn.sweepExt  = dsReq ? ldn.cycMaxPost  : ldn.cycMaxAll;
            ldn.sweepExtT = dsReq ? ldn.cycMaxPostT : ldn.cycMaxAllT;
         }
         else
         {
            ldn.asiaSwept = !IsNa(ldn.cycMinAll)  && ldn.cycMinAll  < asiaR.lo - dist;
            ldn.preSwept  = !IsNa(ldn.cycMinPost) && ldn.cycMinPost < preR.lo  - ldn.swDistPct / 100.0 * (preR.hi - preR.lo);
            ldn.sweepExt  = dsReq ? ldn.cycMinPost  : ldn.cycMinAll;
            ldn.sweepExtT = dsReq ? ldn.cycMinPostT : ldn.cycMinAllT;
         }

         bool fibWaiting = UseFib(ldn.tag) && ldn.state == ST_WAIT_ENTRY && ldn.fibEligible;
         if(t >= ldn.fibEndT || (t >= ss.cutoff && !fibWaiting))
         {
            CancelFib(ldn, t);
            ldn.state = ST_CUTOFF;
            ldn.reason = t >= ldn.fibEndT ? "Fib-Endzeit erreicht" : "Cutoff – keine neuen Trades";
         }
         else if(t >= ss.preEnd && (ldn.dir == -1 ? l <= preR.lo : h >= preR.hi))
            Invalidate(ldn, preR, t, "Gegenseite vor Entry");
         else if(ldn.state == ST_WAIT_ENTRY && ldn.fibArmed && t >= ldn.fibArmTime)
            FibFill(ldn, asiaR, preR, t, h, l);
      }
   }

   void FibFill(CSetup &s, SRange &ref, SRange &pre, datetime t, double h, double l)
   {
      if(!(s.dir == -1 ? h >= s.fibLimit : l <= s.fibLimit)) return;
      ulong k0 = s.fibTk0, k1 = s.fibTk1;
      if(!OpenTrade(s, ref, pre, s.tag + " FIB", s.fibLimit, t, t + 60))
      {
         CancelFib(s, t);
         if(CanTrade()) { DeleteOrClose(k0); DeleteOrClose(k1); }
      }
   }

   //--- NY: pro M1 ------------------------------------------------------------------
   void RangeStepIntrabar(CSetup &s, SRange &pre, datetime t, double h, double l)
   {
      // Modell 3: Limit-Fill / Rejection / Sperre
      if(s.engArmed && !IsNa(s.engLimit))
      {
         if(InpEngRejCancel && !IsNa(s.engRej) && (s.dir == 1 ? h >= s.engRej : l <= s.engRej))
         { CancelEng(s); s.reason = s.tag + " 3C limit cancelled: range edge reached first"; }
         else if(!Allowed(s.dir, s.grp) || EngCntGet(s.grp) >= (InpEngOwnMax > 0 ? InpEngOwnMax : s.maxTrades))
         { CancelEng(s); s.reason = s.tag + " 3C limit cancelled: " + BlockReason(s.dir, s.grp); }
         else if(s.dir == 1 ? l <= s.engLimit : h >= s.engLimit)
         {
            RegisterLimitTrade(s, s.tag + " ENG", s.engLimit, s.engSL, s.engTP, s.engTP2, s.engDual, s.engTk0, s.engTk1, t);
            EngCntInc(s.grp);
            s.engArmed = false; s.engTk0 = 0; s.engTk1 = 0; s.trioValid = false;
            s.reason = s.tag + " 3C engulf filled";
         }
      }
      // Modell 4: Limit-Fill / Sperre
      if(s.fivArmed && !IsNa(s.fivLimit))
      {
         if(!Allowed(s.dir, s.grp) || FivCntGet(s.grp) >= (InpFivOwnMax > 0 ? InpFivOwnMax : s.maxTrades))
         { CancelFiv(s); s.reason = s.tag + " FVGI limit cancelled: " + BlockReason(s.dir, s.grp); }
         else if(s.dir == 1 ? l <= s.fivLimit : h >= s.fivLimit)
         {
            RegisterLimitTrade(s, s.tag + " FVGI", s.fivLimit, s.fivSL, s.fivTP, s.fivTP2, s.fivDual, s.fivTk0, s.fivTk1, t);
            FivCntInc(s.grp);
            s.fivArmed = false; s.fivTk0 = 0; s.fivTk1 = 0;
            s.reason = s.tag + " FVG inversion filled";
         }
      }
      if(s.state == ST_BUILD_PRE && t >= s.preEndT)
      {
         if(pre.bars > 0) { pre.complete = true; s.state = ST_WAIT_SWEEP; s.reason = s.tag + "-Range fertig – warte auf Sweep"; }
         else { s.state = ST_NO_DATA; s.reason = "Keine Daten im " + s.tag + "-Fenster"; }
      }
      if(s.state < ST_WAIT_SWEEP || s.state > ST_WAIT_ENTRY) return;

      if(t >= s.preEndT && t >= s.cycStart)
      {
         if(IsNa(s.cycMaxPost) || h > s.cycMaxPost) { s.cycMaxPost = h; s.cycMaxPostT = t; }
         if(IsNa(s.cycMinPost) || l < s.cycMinPost) { s.cycMinPost = l; s.cycMinPostT = t; }
      }
      // Liquiditäts-Filter: Flags im laufenden Zyklus setzen
      if(t >= s.preEndT && t >= s.cycStart && pre.complete)
      {
         if(InpUseSwingF)
         {
            if(IsNa(s.liqLvl)) s.liqLvl = NearestLvl(s.dir, pre);
            if(!IsNa(s.liqLvl) && (s.dir == -1 ? h > s.liqLvl : l < s.liqLvl)) s.liqSwept = true;
         }
         if(InpUseFvgF && !s.fvgTapped) s.fvgTapped = ZoneTap(fvgs, s.dir, pre, h, l, 0.0);
         if(InpUseObF  && !s.obTapped)  s.obTapped  = ZoneTap(obz,  s.dir, pre, h, l, InpObDispPct / 100.0 * (pre.hi - pre.lo));
      }
      double dist = s.swDistPct / 100.0 * (pre.hi - pre.lo);
      if(s.dir == -1) { s.preSwept = !IsNa(s.cycMaxPost) && s.cycMaxPost > pre.hi + dist; s.sweepExt = s.cycMaxPost; s.sweepExtT = s.cycMaxPostT; }
      else            { s.preSwept = !IsNa(s.cycMinPost) && s.cycMinPost < pre.lo - dist; s.sweepExt = s.cycMinPost; s.sweepExtT = s.cycMinPostT; }

      bool fibWaiting = UseFib(s.tag) && s.state == ST_WAIT_ENTRY && s.fibEligible;
      if(t >= s.fibEndT || (t >= s.entryEndT && !fibWaiting))
      {
         CancelFib(s, t);
         if(t >= s.fibEndT) { CancelEng(s); CancelFiv(s); }
         s.state = ST_CUTOFF;
         s.reason = t >= s.fibEndT ? s.tag + " Fib-Endzeit erreicht" : s.tag + "-Fenster vorbei";
      }
      else if(CntGet(s.grp) >= s.maxTrades)
      {
         CancelFib(s, t); s.state = ST_MAX_TRADES; s.reason = "Max. " + s.tag + "-Trades erreicht";
      }
      else if(t >= s.preEndT && (s.dir == -1 ? l <= pre.lo : h >= pre.hi))
         Invalidate(s, pre, t, s.tag + ": Gegenseite vor Entry");
      else if(s.state == ST_WAIT_ENTRY && s.fibArmed && t >= s.fibArmTime)
         FibFill(s, pre, pre, t, h, l);
   }

   //--- London + NY: pro M5-Close ---------------------------------------------------
   void StepBarClose(CSetup &s, SRange &ref, SRange &pre, double h, double l, double c, double o, datetime tO, datetime tC)
   {
      if(!(s.state >= ST_WAIT_SWEEP && s.state <= ST_WAIT_ENTRY && tC > s.preEndT)) return;
      int  d       = s.dir;
      bool inside  = c < pre.hi && c > pre.lo;
      bool outside = d == -1 ? c > pre.hi : c < pre.lo;
      bool sweepOK = s.isNY ? s.preSwept : (s.asiaSwept && (s.preSwept || InpDoubleSweep == DS_OPT));
      bool inWin   = tO < s.entryEndT && tC > s.entryStartT;
      bool inFibWin = tO < s.fibEndT && tC > s.entryStartT;

      // Orderblock
      if(!s.obValid && outside && tC > s.cycStart)
      {
         s.obValid = true; s.obHi = h; s.obLo = l;
         s.obBodyHi = MathMax(o, c); s.obBodyLo = MathMin(o, c); s.obTime = tO;
         if(CanDraw() && InpShowOB)
         {
            s.obBox = DRect(L2S(tO), s.obBodyHi, L2S(s.entryEndT), s.obBodyLo, InpColOB);
            DText(L2S(tO), s.obBodyHi, s.tag + " OB", clrWhite, ANCHOR_LEFT_LOWER, 7);
         }
      }
      // Sweep bestätigt
      if(s.state == ST_WAIT_SWEEP && sweepOK)
      {
         s.state = ST_WAIT_RECLAIM; s.reason = "Sweep – warte auf Reclaim";
         if(CanDraw() && InpShowSweep)
            s.sweepLbl = DText(L2S(s.sweepExtT), s.sweepExt, s.isNY ? "SWEEP " + s.tag : (s.preSwept ? "SWEEP ASIA+PRE" : "SWEEP ASIA"), InpColSweep, d == -1 ? ANCHOR_LOWER : ANCHOR_UPPER, 8);
      }
      if(s.sweepLbl != "" && CanDraw()) ObjectMove(0, s.sweepLbl, 0, L2S(s.sweepExtT), s.sweepExt);

      // OB-Reclaim
      double trig  = InpObTrig == OB_WICK ? (d == -1 ? s.obLo : s.obHi) : (d == -1 ? s.obBodyLo : s.obBodyHi);
      bool   obRec = s.obValid && s.obTime < tO && !IsNa(trig) && (d == -1 ? c < trig : c > trig);
      bool   just  = false;
      if(s.state == ST_WAIT_RECLAIM && sweepOK && inside && obRec)
      {
         s.state = ST_WAIT_ENTRY; s.reclaimTime = tO; s.reclaimDepth = Depth(d, pre, c);
         s.recExt = d == -1 ? l : h; s.recFixed = false; just = true;
         s.fibEligible = Depth(d, pre, c) >= s.fibDepthPct;      // reclaim candle close decides
         s.reason = "Reclaim (Tiefe " + Pct(s.reclaimDepth) + ") – warte auf Entry";
         if(CanDraw() && InpShowSweep) DText(L2S(tO), c, s.isNY ? s.tag + " RECLAIM" : "RECLAIM", InpColReclaim, d == -1 ? ANCHOR_UPPER : ANCHOR_LOWER, 7);
      }
      // Close wieder außerhalb
      if(s.state == ST_WAIT_ENTRY && !just && outside)
      {
         CancelFib(s, tC);
         s.state = ST_WAIT_RECLAIM; s.reclaimTime = 0; s.reclaimDepth = NA; s.recExt = NA; s.recFixed = false;
         s.fibEligible = false;
         s.reason = "Close wieder außerhalb – warte auf Reclaim";
      }
      if(s.state != ST_WAIT_ENTRY) return;

      // Modell 1: Liquiditäts-Filter und Drei-Kerzen-Sperre
      bool liqOK     = LiqOK(s);
      bool trioBlock = InpEngBlocksOB && InpUseEng && s.sweepTrio;
      if(inWin && inside && obRec && !liqOK)
         s.reason = "Entry blocked (" + s.tag + "): " + LiqReason(s);
      if(inWin && inside && obRec && trioBlock)
         s.reason = "Entry blocked (" + s.tag + "): break consisted of 3 candles - engulf required";
      // Modell 1: OB-Entry
      bool entered = false;
      if(UseOB(s.tag) && inside && obRec && inWin && liqOK && !trioBlock)
      {
         double dep = Depth(d, pre, c);
         if(!IsNa(dep) && dep <= s.obDepthPct) entered = OpenTrade(s, ref, pre, s.tag + " OB", c, tC, tC);
      }
      // Modell 2: Fib
      if(entered || s.state != ST_WAIT_ENTRY || !UseFib(s.tag)) return;
      bool newExt = d == -1 ? l < s.recExt : h > s.recExt;
      if(newExt)
      {
         s.recExt = d == -1 ? l : h;
         if(s.fibArmed) { CancelFib(s, tC); s.reason = "Neues Reclaim-Extrem – Limit wandert mit"; }   // bleibt fixiert → wird unten neu gesetzt
         else s.recFixed = false;
      }
      else if(!s.recFixed && tO > s.reclaimTime && s.hasPrev && (d == -1 ? c > s.prevH : c < s.prevL))
         s.recFixed = true;

      if(s.fibArmed && !Allowed(d, s.grp)) { CancelFib(s, tC); s.reason = "Fib-Limit gelöscht: " + BlockReason(d, s.grp); }

      if(s.recFixed && !s.fibArmed && inFibWin && s.fibEligible)
      {
         double lim = d == -1 ? s.recExt + InpFibLevel * (s.sweepExt - s.recExt) : s.recExt - InpFibLevel * (s.recExt - s.sweepExt);
         bool lvOk, ldual; double lsl, ltp1, ltp2;
         PreLevels(s, ref, pre, lim, lvOk, lsl, ltp1, ltp2, ldual);
         if(InNoTradeZone(pre, lim))  s.reason = "Fib-Limit blockiert: No-Trade-Zone 50 %";
         else if(!Allowed(d, s.grp))  s.reason = "Fib-Limit blockiert: " + BlockReason(d, s.grp);
         else if(!lvOk)               s.reason = "Fib-Limit verworfen: Lage / RR-Filter / SL zu weit";
         else
         {
            s.fibLimit = lim; s.fibArmed = true; s.fibArmTime = tC;
            if(CanTrade())
            {
               double rsl  = SpreadAdj(d, lsl);
               double lots = CalcLots(lim, rsl);
               if(ldual)
               {
                  double q1 = NormLot(lots * InpTp1Split / 100.0);
                  double q2 = NormLot(lots - q1);
                  s.fibTk0 = SendLimit(d, q1, lim, rsl, ltp1, s.tag + " FIB TP1");
                  s.fibTk1 = SendLimit(d, q2, lim, rsl, ltp2, s.tag + " FIB TP2");
               }
               else s.fibTk0 = SendLimit(d, lots, lim, rsl, ltp1, s.tag + " FIB");
            }
            s.reason = "Fib-Limit gesetzt @ " + Px(lim);
            if(CanDraw() && InpShowFib)
            {
               s.fibLine = DLine(L2S(tC), lim, L2S(s.fibEndT), lim, InpColFib, STYLE_SOLID, 2);
               DText(L2S(tC), lim, (d == -1 ? "SELL" : "BUY") + " LIMIT " + DoubleToString(InpFibLevel, 3), InpColFib, ANCHOR_RIGHT, 7);
            }
            Notify((d == 1 ? "A+ LONG " : "A+ SHORT ") + sym + " | " + s.tag + " FIB LIMIT gesetzt @ " + Px(lim) + " | SL " + Px(lsl));
         }
      }
   }

   //--- Asia OB ---------------------------------------------------------------------
   void AsiaReset(CAsia &a, datetime st)
   {
      if(CanDraw()) MoveRight(a.obBox, L2S(st));
      a.ResetCycle(st);
   }
   bool AsiaOpen(CAsia &a, double entry, datetime entryT)
   {
      int d = a.dir;
      double buf  = InpAsiaSlBuf / 100.0 * (asiaR.hi - asiaR.lo);
      double sl   = d == -1 ? a.ext + buf : a.ext - buf;
      double risk = MathAbs(entry - sl);
      bool   dual = InpAsiaTpMode == ATP_DUAL;
      double tpA  = d == -1 ? entry - InpAsiaRR1 * risk : entry + InpAsiaRR1 * risk;
      double tpB  = d == -1 ? entry - InpAsiaRR2 * risk : entry + InpAsiaRR2 * risk;
      bool lvOk    = !IsNa(a.ext) && risk > 0 && (d == -1 ? entry < sl : entry > sl);
      bool allowed = Allowed(d, "ASIA");
      bool ntzA    = InpNtzAsia && InNoTradeZone(asiaR, entry);
      string gwhy  = "";
      bool guards  = GuardsOK(RiskMoneyOf(entry, sl, CalcLots(entry, sl)), gwhy);
      if(!lvOk || !allowed || ntzA || !guards)
      {
         a.reason = ntzA ? "Entry blockiert: No-Trade-Zone 50 %" : !allowed ? "Entry blockiert: " + BlockReason(d, "ASIA")
                  : !guards ? "Entry blockiert: " + gwhy : "Entry verworfen: SL ungültig";
         return false;
      }

      if(d == -1 && ldn.fibArmed && ldn.dir == 1)  CancelFib(ldn, entryT);
      if(d == 1  && ldn.fibArmed && ldn.dir == -1) CancelFib(ldn, entryT);

      STrade tr;
      tr.dir = d; tr.model = "ASIA OB"; tr.entry = entry; tr.sl = sl; tr.tp1 = dual ? tpA : tpB; tr.tp2 = tpB; tr.dual = dual;
      tr.tp1Hit = false; tr.beActive = false; tr.beOnTp1 = InpAsiaBE; tr.grp = "ASIA";
      tr.entryTime = entryT; tr.checkFrom = entryT; tr.tk0 = 0; tr.tk1 = 0;
      if(CanTrade()) PlaceMarket(tr);
      DrawTrade(tr, (d == 1 ? "A+ LONG ↑ " : "A+ SHORT ↓ ") + "ASIA OB");
      Notify((d == 1 ? "A+ LONG " : "A+ SHORT ") + sym + " | Asia OB | Entry " + Px(entry) + " | SL " + Px(sl) +
             (dual ? " | TP1 " + Px(tr.tp1) + " | TP2 " + Px(tpB) : " | TP " + Px(tpB)));
      int n = ArraySize(trades); ArrayResize(trades, n + 1); trades[n] = tr;
      asiaCnt++;
      a.sigTime = entryT;
      AsiaReset(a, entryT);
      a.state  = asiaCnt >= InpAsiaMax ? AS_MAX_TRADES : AS_WAIT_SWEEP;
      a.reason = "Asia-Trade " + IntegerToString(asiaCnt) + " eröffnet";
      return true;
   }
   void AsiaStepIntrabar(CAsia &a, datetime t, double h, double l)
   {
      if(a.state == AS_WAIT_RANGE && asiaR.complete && t >= ss.asiaEnd) { a.state = AS_WAIT_SWEEP; a.reason = "Warte auf Sweep"; }
      if(a.state != AS_WAIT_SWEEP && a.state != AS_WAIT_RECLAIM) return;
      if(asiaCnt >= InpAsiaMax) { a.state = AS_MAX_TRADES; a.reason = "Max. Asia-Trades"; return; }
      if(t >= ss.asiaWinEnd)    { a.state = AS_CUTOFF; a.reason = "Fenster-Ende"; return; }
      if(t < ss.asiaWinStart || t < ss.asiaEnd || t < a.cycStart) return;
      if(IsNa(a.ext) || (a.dir == -1 ? h > a.ext : l < a.ext)) { a.ext = a.dir == -1 ? h : l; a.extT = t; }
      double dist = InpLegAsiaSw / 100.0 * (asiaR.hi - asiaR.lo);
      a.swept = a.dir == -1 ? a.ext > asiaR.hi + dist : a.ext < asiaR.lo - dist;
      if(a.dir == -1 ? l <= asiaR.lo : h >= asiaR.hi)
      {
         AsiaReset(a, t + 60); a.state = AS_WAIT_SWEEP; a.invalidations++;
         a.reason = "Gegenseite vor Entry – warte auf neue Manipulation";
      }
   }
   void AsiaStepBarClose(CAsia &a, double h, double l, double c, double o, datetime tO, datetime tC)
   {
      if((a.state != AS_WAIT_SWEEP && a.state != AS_WAIT_RECLAIM) || tC <= ss.asiaWinStart) return;
      int  d       = a.dir;
      bool inside  = c < asiaR.hi && c > asiaR.lo;
      bool outside = d == -1 ? c > asiaR.hi : c < asiaR.lo;
      if(!a.obValid && outside && tO >= a.cycStart)
      {
         a.obValid = true; a.obHi = h; a.obLo = l; a.obBodyHi = MathMax(o, c); a.obBodyLo = MathMin(o, c); a.obTime = tO;
         if(CanDraw() && InpShowOB)
         {
            a.obBox = DRect(L2S(tO), a.obBodyHi, L2S(ss.asiaWinEnd), a.obBodyLo, InpColAsiaOB);
            DText(L2S(tO), a.obBodyHi, "ASIA OB", clrWhite, ANCHOR_LEFT_LOWER, 7);
         }
      }
      if(a.state == AS_WAIT_SWEEP && a.swept)
      {
         a.state = AS_WAIT_RECLAIM; a.reason = "Asia-Sweep – warte auf OB-Reclaim";
         if(CanDraw() && InpShowSweep)
            a.sweepLbl = DText(L2S(a.extT), a.ext, "SWEEP ASIA " + (d == -1 ? "HIGH" : "LOW"), InpColSweep, d == -1 ? ANCHOR_LOWER : ANCHOR_UPPER, 8);
      }
      if(a.sweepLbl != "" && CanDraw()) ObjectMove(0, a.sweepLbl, 0, L2S(a.extT), a.ext);
      if(a.state == AS_WAIT_RECLAIM && tO < ss.asiaWinEnd)
      {
         double trig  = InpObTrig == OB_WICK ? (d == -1 ? a.obLo : a.obHi) : (d == -1 ? a.obBodyLo : a.obBodyHi);
         bool   obRec = a.obValid && a.obTime < tO && !IsNa(trig) && (d == -1 ? c < trig : c > trig);
         double rA    = asiaR.hi - asiaR.lo;
         double dep   = rA > 0 ? (d == -1 ? asiaR.hi - c : c - asiaR.lo) / rA * 100.0 : NA;
         if(a.swept && inside && obRec && !IsNa(dep) && dep <= InpLegAsiaDep)
         {
            if(CanDraw() && InpShowSweep) DText(L2S(tO), c, "ASIA RECLAIM", InpColReclaim, d == -1 ? ANCHOR_UPPER : ANCHOR_LOWER, 7);
            AsiaOpen(a, c, tC);
         }
      }
   }

   //--- Tagesreset ------------------------------------------------------------------
   void NewDay(datetime loc)
   {
      MqlDateTime s; TimeToStruct(loc, s);
      datetime ds = MkTime(s.year, s.mon, s.day);
      int a1, a2, a3, a4, p1, p2, p3, p4, w1, w2, w3, w4, n1, n2, n3, n4, x1, x2, x3, x4, u1, u2, u3, u4, v1, v2, v3, v4;
      int e1, e2, e3, e4, f1, f2, f3, f4;
      ParseSess(InpAsiaSess, a1, a2, a3, a4);    ParseSess(InpPreSess, p1, p2, p3, p4);
      ParseSess(InpLegAsiaWin, w1, w2, w3, w4);     ParseSess(InpNyPreSess, n1, n2, n3, n4);
      ParseSess(InpNyEntrySess, x1, x2, x3, x4);
      ParseSess(InpLunchSess, u1, u2, u3, u4); ParseSess(InpLunchEntry, v1, v2, v3, v4);
      ParseSess(InpAsiaWin, e1, e2, e3, e4);   ParseSess(InpLdnEntry, f1, f2, f3, f4);
      ss.asiaStart    = ds + a1 * 3600 + a2 * 60;  ss.asiaEnd    = ds + a3 * 3600 + a4 * 60;
      ss.preStart     = ds + p1 * 3600 + p2 * 60;  ss.preEnd     = ds + p3 * 3600 + p4 * 60;
      ss.cutoff       = ds + InpCutoffH * 3600 + InpCutoffM * 60;
      ss.asiaWinStart = ds + w1 * 3600 + w2 * 60;  ss.asiaWinEnd = ds + w3 * 3600 + w4 * 60;
      ss.nyPreStart   = ds + n1 * 3600 + n2 * 60;  ss.nyPreEnd   = ds + n3 * 3600 + n4 * 60;
      ss.nyEntryStart = ds + x1 * 3600 + x2 * 60;  ss.nyEntryEnd = ds + x3 * 3600 + x4 * 60;
      ss.lunchPreStart   = ds + u1 * 3600 + u2 * 60;  ss.lunchPreEnd   = ds + u3 * 3600 + u4 * 60;
      ss.lunchEntryStart = ds + v1 * 3600 + v2 * 60;  ss.lunchEntryEnd = ds + v3 * 3600 + v4 * 60;
      ss.legLdnFibEnd = MathMax(ds + InpLdnFibEndH * 3600 + InpLdnFibEndM * 60, ss.cutoff);
      ss.nyFibEnd    = MathMax(ds + InpNyFibEndH  * 3600 + InpNyFibEndM  * 60, ss.nyEntryEnd);
      ss.lunchFibEnd = MathMax(ds + InpLunFibEndH * 3600 + InpLunFibEndM * 60, ss.lunchEntryEnd);
      ss.asiaEntryStart = ds + e1 * 3600 + e2 * 60;  ss.asiaEntryEnd = ds + e3 * 3600 + e4 * 60;
      ss.ldnEntryStart  = ds + f1 * 3600 + f2 * 60;  ss.ldnEntryEnd  = ds + f3 * 3600 + f4 * 60;
      ss.asiaFibEnd  = MathMax(ds + InpAsiaFibEndH * 3600 + InpAsiaFibEndM * 60, ss.asiaEntryEnd);
      ss.ldnFibEnd   = MathMax(ds + InpLdnFibEndH  * 3600 + InpLdnFibEndM  * 60, ss.ldnEntryEnd);
      ss.asiaCloseT  = InpAsiaCloseH > 0 ? ds + InpAsiaCloseH * 3600 + InpAsiaCloseM * 60 : 0;
      ss.ldnCloseT   = InpLdnCloseH  > 0 ? ds + InpLdnCloseH  * 3600 + InpLdnCloseM  * 60 : 0;
      ss.lunchCloseT = InpLunCloseH  > 0 ? ds + InpLunCloseH  * 3600 + InpLunCloseM  * 60 : 0;
      ss.nyCloseT    = InpNyCloseH   > 0 ? ds + InpNyCloseH   * 3600 + InpNyCloseM   * 60 : 0;

      asiaR.Reset(); preR.Reset(); nyPreR.Reset(); lunchR.Reset();
      asiaBox = ""; preBox = ""; nyBox = ""; lunchBox = "";
      asiaLbl = false; preLbl = false; nyLbl = false; lunchLbl = false;

      ldn.Init(0, "PRE", false, "LDN");
      ldn.state = ST_BUILD_ASIA; ldn.cycStart = ss.asiaEnd; ldn.reason = "Baue Asia Range";
      ldn.preEndT = ss.preEnd; ldn.entryStartT = ss.preEnd; ldn.entryEndT = ss.cutoff; ldn.fibEndT = ss.legLdnFibEnd; ldn.maxTrades = InpLegLdnMax;
      ldn.swDistPct = InpLdnSwDist; ldn.obDepthPct = InpLegObDepth; ldn.fibDepthPct = InpLegFibDep; ldn.sigTF = (int)InpLdnSigTF;

      nyS.Init(-1, "NY", true, "NY"); nyL.Init(1, "NY", true, "NY");
      nyS.state = ST_BUILD_PRE; nyS.cycStart = ss.nyPreEnd; nyS.reason = "Baue NY Pre-Range";
      nyS.preEndT = ss.nyPreEnd; nyS.entryStartT = ss.nyEntryStart; nyS.entryEndT = ss.nyEntryEnd; nyS.fibEndT = ss.nyFibEnd; nyS.maxTrades = InpNyMax;
      nyS.swDistPct = InpNySwDist; nyS.obDepthPct = InpNyObDepth; nyS.fibDepthPct = InpNyFibDep; nyS.sigTF = (int)InpNySigTF;
      nyL.state = ST_BUILD_PRE; nyL.cycStart = ss.nyPreEnd; nyL.reason = "Baue NY Pre-Range";
      nyL.preEndT = ss.nyPreEnd; nyL.entryStartT = ss.nyEntryStart; nyL.entryEndT = ss.nyEntryEnd; nyL.fibEndT = ss.nyFibEnd; nyL.maxTrades = InpNyMax;
      nyL.swDistPct = InpNySwDist; nyL.obDepthPct = InpNyObDepth; nyL.fibDepthPct = InpNyFibDep; nyL.sigTF = (int)InpNySigTF;

      luS.Init(-1, "LUNCH", true, "LUNCH"); luL.Init(1, "LUNCH", true, "LUNCH");
      asS2.Init(-1, "ASIA", true, "ASIA");  asL2.Init(1, "ASIA", true, "ASIA");
      ldS.Init(-1, "LONDON", true, "LDN");  ldL.Init(1, "LONDON", true, "LDN");
      luS.state = ST_BUILD_PRE; luS.cycStart = ss.lunchPreEnd; luS.reason = "Baue Lunch-Range";
      luS.preEndT = ss.lunchPreEnd; luS.entryStartT = ss.lunchEntryStart; luS.entryEndT = ss.lunchEntryEnd; luS.fibEndT = ss.lunchFibEnd; luS.maxTrades = InpLunchMax;
      luS.swDistPct = InpLunSwDist; luS.obDepthPct = InpLunObDepth; luS.fibDepthPct = InpLunFibDep; luS.sigTF = (int)InpLunSigTF;
      luL.state = ST_BUILD_PRE; luL.cycStart = ss.lunchPreEnd; luL.reason = "Baue Lunch-Range";
      luL.preEndT = ss.lunchPreEnd; luL.entryStartT = ss.lunchEntryStart; luL.entryEndT = ss.lunchEntryEnd; luL.fibEndT = ss.lunchFibEnd; luL.maxTrades = InpLunchMax;
      luL.swDistPct = InpLunSwDist; luL.obDepthPct = InpLunObDepth; luL.fibDepthPct = InpLunFibDep; luL.sigTF = (int)InpLunSigTF;

      // --- Asia und London laufen ab V1.6 nach denselben Regeln wie Lunch und NY ---
      asS2.state = ST_BUILD_PRE; asS2.cycStart = ss.asiaEnd; asS2.reason = "Building Asia range";
      asS2.preEndT = ss.asiaEnd; asS2.entryStartT = ss.asiaEntryStart; asS2.entryEndT = ss.asiaEntryEnd; asS2.fibEndT = ss.asiaFibEnd; asS2.maxTrades = InpAsiaMax;
      asS2.swDistPct = InpAsiaSwDist; asS2.obDepthPct = InpAsiaObDepth; asS2.fibDepthPct = InpAsiaFibDep; asS2.sigTF = (int)InpAsiaSigTF;
      asL2.state = ST_BUILD_PRE; asL2.cycStart = ss.asiaEnd; asL2.reason = "Building Asia range";
      asL2.preEndT = ss.asiaEnd; asL2.entryStartT = ss.asiaEntryStart; asL2.entryEndT = ss.asiaEntryEnd; asL2.fibEndT = ss.asiaFibEnd; asL2.maxTrades = InpAsiaMax;
      asL2.swDistPct = InpAsiaSwDist; asL2.obDepthPct = InpAsiaObDepth; asL2.fibDepthPct = InpAsiaFibDep; asL2.sigTF = (int)InpAsiaSigTF;

      ldS.state = ST_BUILD_PRE; ldS.cycStart = ss.preEnd; ldS.reason = "Building London range";
      ldS.preEndT = ss.preEnd; ldS.entryStartT = ss.ldnEntryStart; ldS.entryEndT = ss.ldnEntryEnd; ldS.fibEndT = ss.ldnFibEnd; ldS.maxTrades = InpLdnMax;
      ldS.swDistPct = InpLdnSwDist; ldS.obDepthPct = InpLdnObDepth; ldS.fibDepthPct = InpLdnFibDep; ldS.sigTF = (int)InpLdnSigTF;
      ldL.state = ST_BUILD_PRE; ldL.cycStart = ss.preEnd; ldL.reason = "Building London range";
      ldL.preEndT = ss.preEnd; ldL.entryStartT = ss.ldnEntryStart; ldL.entryEndT = ss.ldnEntryEnd; ldL.fibEndT = ss.ldnFibEnd; ldL.maxTrades = InpLdnMax;
      ldL.swDistPct = InpLdnSwDist; ldL.obDepthPct = InpLdnObDepth; ldL.fibDepthPct = InpLdnFibDep; ldL.sigTF = (int)InpLdnSigTF;

      asS.Init(-1, ss.asiaWinStart); asL.Init(1, ss.asiaWinStart);
      asiaCnt = 0; nyCnt = 0; lunchCnt = 0; ldnCnt = 0;
      lockAsia = false; lockLdn = false; lockLunch = false; lockNy = false;
   }

   //--- Range zeichnen --------------------------------------------------------------
   void DrawRange(SRange &r, string &bx, bool &lbl, datetime left, datetime right, datetime lineEnd, color col, string name, bool lines)
   {
      if(!CanDraw() || !InpShowRanges || r.bars == 0) return;
      if(bx == "") bx = DRect(L2S(left), r.hi, L2S(right), r.lo, col);
      else { ObjectMove(0, bx, 0, L2S(left), r.hi); ObjectMove(0, bx, 1, L2S(right), r.lo); }
      if(r.complete && !lbl)
      {
         lbl = true;
         datetime xe = L2S(lines ? lineEnd : right);
         if(lines)
         {
            double mid = (r.hi + r.lo) / 2.0;
            DLine(L2S(left), r.hi, xe, r.hi, InpColLines);
            DLine(L2S(left), mid,  xe, mid,  InpColLines, STYLE_DOT);
            DLine(L2S(left), r.lo, xe, r.lo, InpColLines);
            DText(xe, mid, "0.5", InpColLines, ANCHOR_LEFT, 7);
         }
         DText(xe, r.hi, name + " HIGH", InpColLines, ANCHOR_LEFT, 7);
         DText(xe, r.lo, name + " LOW",  InpColLines, ANCHOR_LEFT, 7);
      }
   }

   //--- fertige Signal-Kerze eines Setups auswerten ---------------------------------
   // Wird aufgerufen, sobald der Block dieses Setups (sigTF) abgeschlossen ist.
   void SigFlush(CSetup &s, SRange &ref, SRange &pre, datetime upto)
   {
      if(!s.aOpen || s.aEnd > upto) return;
      StepBarClose(s, ref, pre, s.aH, s.aL, s.aC, s.aO, s.aT, s.aEnd);
      s.prevH = s.aH; s.prevL = s.aL; s.hasPrev = true;
      s.aOpen = false;
   }
   // alle aktiven Setups: faellige Signal-Kerzen schliessen
   void SigFlushAll(datetime upto)
   {
      if(InpUseAsia)  { SigFlush(asS2, asiaR, asiaR, upto);  SigFlush(asL2, asiaR, asiaR, upto); }
      if(InpUseLdn)   { SigFlush(ldS, preR, preR, upto);     SigFlush(ldL, preR, preR, upto); }
      if(InpUseLunch) { SigFlush(luS, lunchR, lunchR, upto); SigFlush(luL, lunchR, lunchR, upto); }
      if(InpUseNY)    { SigFlush(nyS, nyPreR, nyPreR, upto); SigFlush(nyL, nyPreR, nyPreR, upto); }
      if(InpUseLegLdn) SigFlush(ldn, asiaR, preR, upto);
   }
   // alle aktiven Setups: M1-Kerze einrechnen
   void SigAddAll(datetime t, double o, double h, double l, double c)
   {
      if(InpUseAsia)  { asS2.SigAdd(t, o, h, l, c); asL2.SigAdd(t, o, h, l, c); }
      if(InpUseLdn)   { ldS.SigAdd(t, o, h, l, c);  ldL.SigAdd(t, o, h, l, c); }
      if(InpUseLunch) { luS.SigAdd(t, o, h, l, c);  luL.SigAdd(t, o, h, l, c); }
      if(InpUseNY)    { nyS.SigAdd(t, o, h, l, c);  nyL.SigAdd(t, o, h, l, c); }
      if(InpUseLegLdn) ldn.SigAdd(t, o, h, l, c);
   }

   //====================================================================================
   //  LIQUIDITAETS-DETEKTOREN (Swings, FVGs, Orderblocks)
   //====================================================================================
   void PushZone(SZone &z)
   {
      int n = ArraySize(fvgs); ArrayResize(fvgs, n + 1); fvgs[n] = z;
      if(ArraySize(fvgs) > 150)
      { for(int i = 0; i < ArraySize(fvgs) - 1; i++) fvgs[i] = fvgs[i + 1]; ArrayResize(fvgs, ArraySize(fvgs) - 1); }
   }
   bool TfOn(string tf, bool forFiv)
   {
      if(tf == "M5")  return forFiv ? InpFivM5  : InpFvgM5;
      if(tf == "M15") return forFiv ? InpFivM15 : InpFvgM15;
      if(tf == "H1")  return forFiv ? InpFivH1  : InpFvgH1;
      return forFiv ? InpFivH4 : InpFvgH4;
   }
   // FVGs eines Timeframes einsammeln. slot = Index in fvgSeen, tfName = Label.
   void CollectFvg(ENUM_TIMEFRAMES tf, int slot, string tfName, datetime now)
   {
      if(!TfOn(tfName, true) && !TfOn(tfName, false)) return;
      MqlRates r[];
      if(CopyRates(sym, tf, 1, 3, r) < 3) return;      // r[0] = älteste der drei
      if(r[2].time <= fvgSeen[slot]) return;
      fvgSeen[slot] = r[2].time;
      SZone z; z.move = 1e12; z.anchor = 0; z.dead = false; z.inv = false; z.used = false;
      z.t = r[2].time; z.seen = now; z.invT = 0; z.tf = tfName;
      if(r[2].low > r[0].high)  { z.bot = r[0].high; z.top = r[2].low;  z.dir = 1;  PushZone(z); }
      if(r[2].high < r[0].low)  { z.bot = r[2].high; z.top = r[0].low;  z.dir = -1; PushZone(z); }
   }
   // Verfall und Inversion aller FVGs mit der aktuellen M5-Kerze
   void UpdateFvg(const MqlRates &bar)
   {
      for(int i = 0; i < ArraySize(fvgs); i++)
      {
         if(!fvgs[i].dead && (fvgs[i].dir == 1 ? bar.low < fvgs[i].bot : bar.high > fvgs[i].top))
            fvgs[i].dead = true;
         if(!fvgs[i].inv && (fvgs[i].dir == 1 ? bar.close < fvgs[i].bot : bar.close > fvgs[i].top))
         { fvgs[i].inv = true; fvgs[i].invT = bar.time; }
      }
   }
   // Swing-Fraktale auf M5
   void CollectSwings(datetime now)
   {
      if(!InpUseSwingF) return;
      int n = InpSwingLen;
      MqlRates r[];
      if(CopyRates(sym, PERIOD_M5, 1, 2 * n + 1, r) < 2 * n + 1) return;
      int m = n;                                        // Mitte des Fensters
      bool isHi = true, isLo = true;
      for(int i = 0; i < 2 * n + 1; i++)
      {
         if(i == m) continue;
         if(r[i].high >= r[m].high) isHi = false;
         if(r[i].low  <= r[m].low)  isLo = false;
      }
      if(isHi)
      {
         int k = ArraySize(swHi); ArrayResize(swHi, k + 1);
         swHi[k].px = r[m].high; swHi[k].t = r[m].time; swHi[k].active = true;
         if(ArraySize(swHi) > 60) { for(int i = 0; i < ArraySize(swHi) - 1; i++) swHi[i] = swHi[i + 1]; ArrayResize(swHi, ArraySize(swHi) - 1); }
      }
      if(isLo)
      {
         int k = ArraySize(swLo); ArrayResize(swLo, k + 1);
         swLo[k].px = r[m].low; swLo[k].t = r[m].time; swLo[k].active = true;
         if(ArraySize(swLo) > 60) { for(int i = 0; i < ArraySize(swLo) - 1; i++) swLo[i] = swLo[i + 1]; ArrayResize(swLo, ArraySize(swLo) - 1); }
      }
   }
   // Orderblocks: letzte Down-Kerze vor Upmove bzw. letzte Up-Kerze vor Downmove
   void CollectOb(const MqlRates &bar)
   {
      if(!InpUseObF) return;
      if(obBullIdx >= 0 && obBullIdx < ArraySize(obz))
         obz[obBullIdx].move = MathMax(obz[obBullIdx].move, bar.high - obz[obBullIdx].anchor);
      if(obBearIdx >= 0 && obBearIdx < ArraySize(obz))
         obz[obBearIdx].move = MathMax(obz[obBearIdx].move, obz[obBearIdx].anchor - bar.low);
      SZone z; z.dead = false; z.inv = false; z.used = false; z.t = bar.time; z.seen = bar.time; z.invT = 0; z.tf = "";
      z.bot = bar.low; z.top = bar.high; z.move = 0;
      if(bar.close < bar.open)
      { z.dir = 1;  z.anchor = bar.low;  int n = ArraySize(obz); ArrayResize(obz, n + 1); obz[n] = z; obBullIdx = n; }
      if(bar.close > bar.open)
      { z.dir = -1; z.anchor = bar.high; int n = ArraySize(obz); ArrayResize(obz, n + 1); obz[n] = z; obBearIdx = n; }
      while(ArraySize(obz) > 40)
      {
         for(int i = 0; i < ArraySize(obz) - 1; i++) obz[i] = obz[i + 1];
         ArrayResize(obz, ArraySize(obz) - 1);
         obBullIdx--; obBearIdx--;
      }
   }
   //--- Filter-Auswertung pro Setup (Intrabar) ---------------------------------------
   double NearestLvl(int d, SRange &pre)
   {
      double best = NA;
      if(d == 1)
      {
         for(int i = 0; i < ArraySize(swLo); i++)
            if(swLo[i].active && swLo[i].px < pre.lo && (IsNa(best) || swLo[i].px > best)) best = swLo[i].px;
      }
      else
      {
         for(int i = 0; i < ArraySize(swHi); i++)
            if(swHi[i].active && swHi[i].px > pre.hi && (IsNa(best) || swHi[i].px < best)) best = swHi[i].px;
      }
      return best;
   }
   bool ZoneTap(SZone &zs[], int d, SRange &pre, double h, double l, double minMove)
   {
      for(int i = 0; i < ArraySize(zs); i++)
      {
         if(zs[i].dead || zs[i].dir != d || zs[i].move < minMove) continue;
         bool onSide = d == 1 ? zs[i].top <= pre.lo : zs[i].bot >= pre.hi;
         if(onSide && l <= zs[i].top && h >= zs[i].bot) return true;
      }
      return false;
   }
   bool LiqOK(CSetup &s)
   {
      return (!InpUseSwingF || s.liqSwept) && (!InpUseFvgF || s.fvgTapped) && (!InpUseObF || s.obTapped);
   }
   string LiqReason(CSetup &s)
   {
      if(InpUseSwingF && !s.liqSwept) return "swing level not swept";
      if(InpUseFvgF && !s.fvgTapped)  return "no FVG dip";
      return "no orderblock tap";
   }

   //--- eine abgeschlossene M5-Kerze verarbeiten ------------------------------------
   bool ProcessBar(MqlRates &bar)
   {
      live = bar.time + 300 >= g_start;
      MqlRates m1[];
      int m = CopyRates(sym, PERIOD_M1, bar.time, bar.time + 299, m1);
      if(m < 0 && live) return false;              // M1 noch nicht synchron → später erneut

      datetime tO = S2L(bar.time), tC = tO + 300;
      int dk = DayKey(tO);
      if(dk != dayKey) { NewDay(tO); dayKey = dk; }

      if(m > 0 && !m1Seen)
      {
         m1Seen = true;
         if(S2L(m1[0].time) > ss.asiaStart + 60 && ldn.state == ST_BUILD_ASIA) { ldn.state = ST_NO_DATA; ldn.reason = "Historie beginnt mitten im Tag"; }
      }
      for(int j = 0; j < m; j++)
      {
         datetime t = S2L(m1[j].time);
         double   h = m1[j].high, l = m1[j].low;

         // 0) Signal-Kerzen, die vor dieser M1-Kerze abgeschlossen sind, auswerten
         SigFlushAll(t);

         // 1) open trades first
         ManageTrades(t, h, l);

         // 2) build all four ranges, regardless of which setup is active
         if(t >= ss.asiaStart && t < ss.asiaEnd) asiaR.Update(h, l);
         else if(t >= ss.asiaEnd && asiaR.bars > 0) asiaR.complete = true;
         if(t >= ss.preStart && t < ss.preEnd) preR.Update(h, l);
         else if(t >= ss.preEnd && preR.bars > 0) preR.complete = true;
         if(t >= ss.lunchPreStart && t < ss.lunchPreEnd) lunchR.Update(h, l);
         if(t >= ss.nyPreStart && t < ss.nyPreEnd) nyPreR.Update(h, l);

         // 3) the four standalone range setups
         if(InpUseAsia)  { RangeStepIntrabar(asS2, asiaR, t, h, l);  RangeStepIntrabar(asL2, asiaR, t, h, l); }
         if(InpUseLdn)   { RangeStepIntrabar(ldS, preR, t, h, l);    RangeStepIntrabar(ldL, preR, t, h, l); }
         if(InpUseLunch) { RangeStepIntrabar(luS, lunchR, t, h, l);  RangeStepIntrabar(luL, lunchR, t, h, l); }
         if(InpUseNY)    { RangeStepIntrabar(nyS, nyPreR, t, h, l);  RangeStepIntrabar(nyL, nyPreR, t, h, l); }

         // 4) legacy setups
         if(InpUseLegLdn) StepIntrabar(t, h, l);
         if(InpUseAsiaOB) { AsiaStepIntrabar(asS, t, h, l); AsiaStepIntrabar(asL, t, h, l); }

         // 5) M1-Kerze in die Signal-Kerzen aller Setups einrechnen
         SigAddAll(t, m1[j].open, h, l, m1[j].close);
      }
      // Fallback: keine M1-Historie vorhanden → M5-Kerze als Signal-Kerze verwenden
      if(m <= 0) SigAddAll(tO, bar.open, bar.high, bar.low, bar.close);

      // --- Liquiditäts-Detektoren auf der abgeschlossenen M5-Kerze
      UpdateFvg(bar);
      if(InpUseFiv || InpUseFvgF)
      {
         CollectFvg(PERIOD_M5,  0, "M5",  bar.time);
         CollectFvg(PERIOD_M15, 1, "M15", bar.time);
         CollectFvg(PERIOD_H1,  2, "H1",  bar.time);
         CollectFvg(PERIOD_H4,  3, "H4",  bar.time);
      }
      CollectSwings(bar.time);
      CollectOb(bar);

      // --- Modell 3: Drei-Kerzen-Engulfing (auf M5)
      if(InpUseEng)
      {
         MqlRates r[];
         if(CopyRates(sym, PERIOD_M5, 1, 18, r) >= 6)
         {
            int last = ArraySize(r) - 1;
            int c0 = CdirAt(r, last), c1 = CdirAt(r, last - 1), c2 = CdirAt(r, last - 2);
            bool trioRaw = c0 != 0 && c0 == c1 && c1 == c2;
            int prevDir = 0;
            if(trioRaw)
               for(int i = last - 3; i >= 1 && prevDir == 0; i--) prevDir = CdirAt(r, i);
            bool bear3 = trioRaw && c0 == -1 && (InpEngRolling || prevDir != -1);
            bool bull3 = trioRaw && c0 ==  1 && (InpEngRolling || prevDir !=  1);
            double t3Lo = MathMin(r[last].low,  MathMin(r[last-1].low,  r[last-2].low));
            double t3Hi = MathMax(r[last].high, MathMax(r[last-1].high, r[last-2].high));
            double bHi  = MathMax(MathMax(r[last].open, r[last].close),
                          MathMax(MathMax(r[last-1].open, r[last-1].close), MathMax(r[last-2].open, r[last-2].close)));
            double bLo  = MathMin(MathMin(r[last].open, r[last].close),
                          MathMin(MathMin(r[last-1].open, r[last-1].close), MathMin(r[last-2].open, r[last-2].close)));
            double lHi  = MathMax(r[last].open, r[last].close);
            double lLo  = MathMin(r[last].open, r[last].close);
            bool aW = tC > ss.asiaEntryStart && tO < ss.asiaEntryEnd;
            bool lW = tC > ss.ldnEntryStart  && tO < ss.ldnEntryEnd;
            bool uW = tC > ss.lunchEntryStart && tO < ss.lunchEntryEnd;
            bool nW = tC > ss.nyEntryStart   && tO < ss.nyEntryEnd;
            if(InpUseAsia)
            {
               EngStep(asL2, asiaR, bear3, t3Lo, t3Hi, bHi, lHi, c0 == -1, bar.close, bar.low, bar.high, tO, tC, aW);
               EngStep(asS2, asiaR, bull3, t3Hi, t3Lo, bLo, lLo, c0 ==  1, bar.close, bar.low, bar.high, tO, tC, aW);
            }
            if(InpUseLdn)
            {
               EngStep(ldL, preR, bear3, t3Lo, t3Hi, bHi, lHi, c0 == -1, bar.close, bar.low, bar.high, tO, tC, lW);
               EngStep(ldS, preR, bull3, t3Hi, t3Lo, bLo, lLo, c0 ==  1, bar.close, bar.low, bar.high, tO, tC, lW);
            }
            if(InpUseLunch)
            {
               EngStep(luL, lunchR, bear3, t3Lo, t3Hi, bHi, lHi, c0 == -1, bar.close, bar.low, bar.high, tO, tC, uW);
               EngStep(luS, lunchR, bull3, t3Hi, t3Lo, bLo, lLo, c0 ==  1, bar.close, bar.low, bar.high, tO, tC, uW);
            }
            if(InpUseNY)
            {
               EngStep(nyL, nyPreR, bear3, t3Lo, t3Hi, bHi, lHi, c0 == -1, bar.close, bar.low, bar.high, tO, tC, nW);
               EngStep(nyS, nyPreR, bull3, t3Hi, t3Lo, bLo, lLo, c0 ==  1, bar.close, bar.low, bar.high, tO, tC, nW);
            }
         }
      }
      // --- Modell 4: FVG-Inversion
      if(InpUseFiv)
      {
         bool aW = tC > ss.asiaEntryStart && tO < ss.asiaEntryEnd;
         bool lW = tC > ss.ldnEntryStart  && tO < ss.ldnEntryEnd;
         bool uW = tC > ss.lunchEntryStart && tO < ss.lunchEntryEnd;
         bool nW = tC > ss.nyEntryStart   && tO < ss.nyEntryEnd;
         if(InpUseAsia)  { FivStep(asL2, asiaR, bar.close, tO, tC, aW);  FivStep(asS2, asiaR, bar.close, tO, tC, aW); }
         if(InpUseLdn)   { FivStep(ldL, preR, bar.close, tO, tC, lW);    FivStep(ldS, preR, bar.close, tO, tC, lW); }
         if(InpUseLunch) { FivStep(luL, lunchR, bar.close, tO, tC, uW);  FivStep(luS, lunchR, bar.close, tO, tC, uW); }
         if(InpUseNY)    { FivStep(nyL, nyPreR, bar.close, tO, tC, nW);  FivStep(nyS, nyPreR, bar.close, tO, tC, nW); }
      }

      DrawRange(asiaR, asiaBox, asiaLbl, ss.asiaStart, ss.asiaEnd, InpUseAsia ? ss.asiaEntryEnd : ss.asiaEnd, InpColAsia, "ASIA", InpUseAsia);
      DrawRange(preR, preBox, preLbl, ss.preStart, ss.preEnd, InpUseLdn ? ss.ldnEntryEnd : ss.cutoff, InpColPre, "LONDON", true);
      if(InpUseLunch) DrawRange(lunchR, lunchBox, lunchLbl, ss.lunchPreStart, ss.lunchPreEnd, ss.lunchEntryEnd, InpColLunch, "LUNCH", true);
      if(InpUseNY) DrawRange(nyPreR, nyBox, nyLbl, ss.nyPreStart, ss.nyPreEnd, ss.nyEntryEnd, InpColNy, "NY", true);

      // Alle Signal-Kerzen auswerten, die innerhalb dieser M5-Kerze abgeschlossen wurden.
      // Setups mit sigTF <= 5 sind damit am Ende der M5-Kerze exakt auf Stand,
      // ein M15-Setup wird erst am Ende seines eigenen Blocks ausgewertet.
      SigFlushAll(tC);
      // legacy setups
      if(InpUseAsiaOB) { AsiaStepBarClose(asS, bar.high, bar.low, bar.close, bar.open, tO, tC); AsiaStepBarClose(asL, bar.high, bar.low, bar.close, bar.open, tO, tC); }

      if(CanDraw())
         for(int i = 0; i < ArraySize(trades); i++)
         { MoveRight(trades[i].riskBox, bar.time + 300); MoveRight(trades[i].rewardBox, bar.time + 300); MoveRight(trades[i].tp1Line, bar.time + 300); }

      // Sicherheitsnetz: Position ohne internen Trade-Datensatz (z. B. Rundungsrest)
      if(InpFlattenOrph && CanTrade())
      {
         if(ArraySize(trades) == 0 && OpenVolume() > 0)
         {
            orphanN++;
            if(orphanN >= 2) { CloseAllOwn(); orphanN = 0; }
         }
         else orphanN = 0;
      }
      return true;
   }

   //--- neue M5-Kerzen abarbeiten ---------------------------------------------------
   void Update()
   {
      datetime lastClosed = iTime(sym, PERIOD_M5, 1);
      if(lastClosed <= 0) return;
      if(lastM5 == 0) lastM5 = lastClosed - InpWarmupDays * 86400;
      if(lastClosed <= lastM5) return;
      MqlRates bars[];
      int n = CopyRates(sym, PERIOD_M5, lastM5 + 1, lastClosed, bars);
      if(n <= 0) return;
      for(int i = 0; i < n; i++)
      {
         if(bars[i].time <= lastM5) continue;
         if(!ProcessBar(bars[i])) return;
         lastM5 = bars[i].time;
      }
   }

   //--- Debug -----------------------------------------------------------------------
   string SInfo(CSetup &st)
   {
      return StateName(st.state) + " sweep" + (st.preSwept ? "+" : "-") + " OB" + (st.obValid ? "+" : "-") +
             (st.fibArmed ? " fib " + Px(st.fibLimit) : "");
   }
   string Debug()
   {
      string s = "# " + sym + "\n";
      s += "  ASIA   " + (InpUseAsia ? "M" + IntegerToString((int)InpAsiaSigTF) + " " + "S:" + SInfo(asS2) + " | L:" + SInfo(asL2) +
           " | " + IntegerToString(asiaCnt) + "/" + IntegerToString(InpAsiaMax) + " | " + asS2.reason : "off") + "\n";
      s += "  LONDON " + (InpUseLdn ? "M" + IntegerToString((int)InpLdnSigTF) + " " + "S:" + SInfo(ldS) + " | L:" + SInfo(ldL) +
           " | " + IntegerToString(ldnCnt) + "/" + IntegerToString(InpLdnMax) + " | " + ldS.reason : "off") + "\n";
      s += "  LUNCH  " + (InpUseLunch ? "M" + IntegerToString((int)InpLunSigTF) + " " + "S:" + SInfo(luS) + " | L:" + SInfo(luL) +
           " | " + IntegerToString(lunchCnt) + "/" + IntegerToString(InpLunchMax) + " | " + luS.reason : "off") + "\n";
      s += "  NY     " + (InpUseNY ? "M" + IntegerToString((int)InpNySigTF) + " " + "S:" + SInfo(nyS) + " | L:" + SInfo(nyL) +
           " | " + IntegerToString(nyCnt) + "/" + IntegerToString(InpNyMax) + " | " + nyS.reason : "off") + "\n";
      if(InpUseAsiaOB || InpUseLegLdn)
         s += "  LEGACY " + (InpUseAsiaOB ? "AsiaOB S:" + AsiaStateName(asS.state) + " L:" + AsiaStateName(asL.state) + "  " : "") +
              (InpUseLegLdn ? "London " + StateName(ldn.state) + " loc " + Pct(ldn.locPos) : "") + "\n";
      if(InpUseEng || InpUseFiv)
         s += "  3C/FVGI " + (InpUseEng ? "eng " + (asL2.engArmed || asS2.engArmed || ldL.engArmed || ldS.engArmed ||
                                                     luL.engArmed || luS.engArmed || nyL.engArmed || nyS.engArmed ? "LIMIT" : "-") + "  " : "") +
              (InpUseFiv ? "fvgi " + (asL2.fivArmed || asS2.fivArmed || ldL.fivArmed || ldS.fivArmed ||
                                      luL.fivArmed || luS.fivArmed || nyL.fivArmed || nyS.fivArmed ? "LIMIT" : "-") : "") +
              "  · fvg " + IntegerToString(ArraySize(fvgs)) + " · day " + IntegerToString(daySL) + "SL/" + IntegerToString(dayTP) + "TP\n";
      s += "  locks: A" + (lockAsia ? "*" : "-") + " L" + (lockLdn ? "*" : "-") + " Lu" + (lockLunch ? "*" : "-") + " NY" + (lockNy ? "*" : "-") +
           " | internal open trades " + IntegerToString(ArraySize(trades)) + "\n";
      return s;
   }
};

//====================================================================================
// 6. EA-EVENTS
//====================================================================================
CEngine *g_eng[];

int OnInit()
{
   g_start = TimeCurrent();
   string list = InpSymbols;
   StringReplace(list, " ", "");
   string parts[];
   int cnt = StringLen(list) > 0 ? StringSplit(list, ',', parts) : 0;
   if(cnt <= 0) { ArrayResize(parts, 1); parts[0] = _Symbol; cnt = 1; }

   for(int i = 0; i < cnt; i++)
   {
      if(parts[i] == "") continue;
      if(!SymbolSelect(parts[i], true)) { PrintFormat("Symbol nicht gefunden: %s", parts[i]); continue; }
      int n = ArraySize(g_eng);
      ArrayResize(g_eng, n + 1);
      g_eng[n] = new CEngine();
      g_eng[n].Init(parts[i]);
   }
   if(ArraySize(g_eng) == 0) return INIT_PARAMETERS_INCORRECT;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNUNG: Konto ist kein Hedging-Konto – Dual-TP / mehrere Positionen funktionieren nicht korrekt.");
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_eng); i++) delete g_eng[i];
   ArrayResize(g_eng, 0);
   ObjectsDeleteAll(0, "APX_");
   Comment("");
}

void RunAll()
{
   for(int i = 0; i < ArraySize(g_eng); i++) g_eng[i].Update();
   if(InpShowDebug)
   {
      string tpTxt = InpTpMode == TP_CUSTR ? StringFormat("Custom R (TP1 full range / TP2 %.1fR)", InpTp2R)
                   : InpTpMode == TP_DUAL   ? StringFormat("Dual (%.0f%% / %.0f%%)", InpTp1Level, InpTp2Level)
                   : InpTpMode == TP_FULL   ? StringFormat("Single %.0f%%", InpTp2Level)
                                            : StringFormat("Single %.0f%%", InpTp1Level);
      string dirTxt = InpDirFilter == DIRF_LONG ? "LONG only" : InpDirFilter == DIRF_SHORT ? "SHORT only" : "both";
      if(StringLen(InpLongOnlySyms)  > 0) dirTxt += " | long-only: "  + InpLongOnlySyms;
      if(StringLen(InpShortOnlySyms) > 0) dirTxt += " | short-only: " + InpShortOnlySyms;
      string s = "Lou-A+ EA V1.9.2 | mode: " + (InpMode == MODE_AUTO ? "AUTO TRADING" : "NUR ZEICHNEN") +
                 " | Wien " + TimeToString(S2L(TimeCurrent()), TIME_DATE | TIME_MINUTES) + "\n" +
                 "TP: " + tpTxt + " | Richtung: " + dirTxt + "\n";
      for(int i = 0; i < ArraySize(g_eng); i++) s += g_eng[i].Debug();
      Comment(s);
   }
}

void OnTick()  { RunAll(); }
void OnTimer() { RunAll(); }

//+------------------------------------------------------------------------------------+
//| HINWEISE                                                                           |
//| 0. Guards (Daily/Weekly Ziele & Verluste, max. offenes Risiko) gelten kontoweit über  |
//|    alle Symbole, Standard 0 = aus. Grundlage: realisierte Deals dieser Magic + offene |
//|    Positionen dieser Magic.                                                          |
//| 1. Broker-Offset: Standard = NY-Close-Server (GMT+2 Winter / GMT+3 US-Sommer), z.B. |
//|    Fusion Markets. Andere Broker: Winter-Offset anpassen oder "Manuell" wählen.     |
//| 2. Entries: OB = Market-Order nach M5-Close (Open der nächsten Kerze), Fib = echte  |
//|    Limit. Dual-TP = 2 Positionen je 50 %, BE nach TP1 per Modify.                   |
//| 3. Interne M1-Simulation steuert State, Sperren und Zeichnungen (wie TradingView). |
//|    Echte Fills können durch Spread/Slippage minimal abweichen.                     |
//| 4. Warm-up-Kerzen (vor EA-Start) erzeugen nur Zeichnungen, keine Orders/Alerts.    |
//| 5. Mindestlot: liegt die berechnete Größe darunter, wird Mindestlot eröffnet.      |
//+------------------------------------------------------------------------------------+

//+------------------------------------------------------------------------------------+
//| OPTIMIERUNGS-EXPORT                                                                |
//| Jeder Durchlauf schreibt seine Parameter und Kennzahlen in eine CSV im gemeinsamen |
//| Ordner (Terminal > Datei > Datenordner öffnen ... \Common\Files).                  |
//| Datei: Lou_APlus_opt.csv, Trennzeichen ';'                                         |
//+------------------------------------------------------------------------------------+
int    g_optCsv    = INVALID_HANDLE;
bool   g_optHeader = false;

// Bewertung eines Durchlaufs: Ertrag im Verhältnis zum Drawdown, gedämpft bei wenigen Trades.
double PassScore(double profit, double ddPct, double pf, double trades)
{
   if(trades < 1) return 0;
   double dd    = MathMax(ddPct, 0.5);
   double base  = profit / dd;
   double conf  = MathMin(1.0, MathSqrt(trades / 40.0));   // unter 40 Trades wird abgewertet
   double pfAdj = pf <= 0 ? 0 : MathMin(pf / 1.5, 2.0);
   return base * conf * pfAdj;
}

double OnTester()
{
   double d[10];
   d[0] = TesterStatistics(STAT_PROFIT);
   d[1] = TesterStatistics(STAT_PROFIT_FACTOR);
   d[2] = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   d[3] = TesterStatistics(STAT_TRADES);
   d[4] = TesterStatistics(STAT_PROFIT_TRADES);
   d[5] = TesterStatistics(STAT_EXPECTED_PAYOFF);
   d[6] = TesterStatistics(STAT_SHARPE_RATIO);
   d[7] = TesterStatistics(STAT_RECOVERY_FACTOR);
   d[8] = TesterStatistics(STAT_MAX_CONLOSS_TRADES);   // längste Verlustserie in Trades
   d[9] = PassScore(d[0], d[2], d[1], d[3]);
   FrameAdd("lou", 1, d[9], d);
   return d[9];
}

void OnTesterInit()
{
   g_optCsv = FileOpen("Lou_APlus_opt.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
   g_optHeader = false;
   if(g_optCsv == INVALID_HANDLE) Print("Optimierungs-CSV konnte nicht geöffnet werden: ", GetLastError());
}

void OnTesterPass()
{
   if(g_optCsv == INVALID_HANDLE) return;
   ulong  pass; string fname; long fid; double fval; double d[];
   while(FrameNext(pass, fname, fid, fval, d))
   {
      string names[]; string values[];
      uint cnt = 0;
      FrameInputs(pass, names, cnt);
      ArrayResize(values, cnt);
      for(uint i = 0; i < cnt; i++)
      {
         string kv = names[i];              // Format "Name=Wert"
         int eq = StringFind(kv, "=");
         values[i] = eq >= 0 ? StringSubstr(kv, eq + 1) : "";
         names[i]  = eq >= 0 ? StringSubstr(kv, 0, eq)  : kv;
      }
      if(!g_optHeader)
      {
         string head = "pass;profit;profit_factor;dd_percent;trades;win_trades;expected_payoff;sharpe;recovery;max_cons_loss;score";
         for(uint i = 0; i < cnt; i++) head += ";" + names[i];
         FileWrite(g_optCsv, head);
         g_optHeader = true;
      }
      string row = StringFormat("%I64u;%.2f;%.4f;%.2f;%.0f;%.0f;%.4f;%.4f;%.4f;%.0f;%.6f",
                                pass, d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9]);
      for(uint i = 0; i < cnt; i++) row += ";" + values[i];
      FileWrite(g_optCsv, row);
      FileFlush(g_optCsv);
   }
}

void OnTesterDeinit()
{
   if(g_optCsv != INVALID_HANDLE) { FileClose(g_optCsv); g_optCsv = INVALID_HANDLE; }
   Print("Optimierungs-CSV geschrieben: Common\\Files\\Lou_APlus_opt.csv");
}
