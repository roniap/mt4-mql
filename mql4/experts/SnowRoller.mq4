/**
 * SnowRoller Anti-Martingale EA
 *
 * @see 7bit strategy:  http://www.forexfactory.com/showthread.php?t=226059
 *      7bit journal:   http://www.forexfactory.com/showthread.php?t=239717
 *      7bit code base: http://sites.google.com/site/prof7bit/snowball
 */
#include <stdlib.mqh>
#include <win32api.mqh>


#define STATUS_WAITING        0           // m�gliche Sequenzstatus-Werte
#define STATUS_PROGRESSING    1
#define STATUS_FINISHED       2
#define STATUS_DISABLED       3


int Strategy.Id = 103;                    // eindeutige ID der Strategie (Bereich 101-1023)


//////////////////////////////////////////////////////////////// Externe Parameter ////////////////////////////////////////////////////////////////

extern int    GridSize                       = 20;
extern double LotSize                        = 0.1;
extern string StartCondition                 = "";          // {LimitValue}
extern int    TakeProfitLevels               = 5;
extern string ______________________________ = "==== Sequence to Manage =============";
extern string Sequence.ID                    = "";

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


int      intern.GridSize;                                   // Input-Parameter sind nicht statisch. Werden sie aus einer Preset-Datei geladen,
double   intern.LotSize;                                    // werden sie bei REASON_CHARTCHANGE mit den obigen Default-Werten �berschrieben.
string   intern.StartCondition;                             // Um dies zu verhindern, werden sie in deinit() in intern.* zwischengespeichert
int      intern.TakeProfitLevels;                           // und in init() wieder daraus restauriert.
string   intern.Sequence.ID;

int      status = STATUS_WAITING;
int      sequenceId;

double   Entry.limit;
double   Entry.lastBid;


double   grid.base;
int      grid.level;                                        // aktueller Grid-Level
int      grid.maxLevelLong;                                 // h�chster erreichter Long-Level
int      grid.maxLevelShort;                                // h�chster erreichter Short-Level
int      grid.stops;                                        // Anzahl der bisher getriggerten Stops
double   grid.realizedPL;                                   // P/L aller bisher getriggerten Stops (negativ)
double   grid.floatingPL;                                   // P/L der im Moment offenen Positionen
double   grid.profitLoss;                                   // Gesamt-P/L (realized + floating)
double   grid.breakevenLong;
double   grid.breakevenShort;

int      orders.ticket    [];
int      orders.level     [];                               // Grid-Level der Order
int      orders.type      [];
datetime orders.openTime  [];
double   orders.openPrice [];
datetime orders.closeTime [];
double   orders.closePrice[];
double   orders.swap      [];
double   orders.commission[];
double   orders.profit    [];

bool     firstTick = true;


/**
 * Initialisierung
 *
 * @return int - Fehlerstatus
 */
int init() {
   if (IsError(onInit(T_EXPERT)))
      return(ShowStatus(true));

   /*
   Zuerst wird die aktuelle Sequenz-ID bestimmt, dann deren Konfiguration geladen und validiert. Zum Schlu� werden die Daten der ggf. laufenden Sequenz restauriert.
   Es gibt 4 unterschiedliche init()-Szenarien:

   (1.1) Recompilation:                    keine internen Daten vorhanden, evt. externe Referenz vorhanden (im Chart)
   (1.2) Neustart des EA, evt. im Tester:  keine internen Daten vorhanden, evt. externe Referenz vorhanden (im Chart)
   (1.3) Parameter�nderung:                alle internen Daten vorhanden, externe Referenz unn�tig
   (1.4) Timeframe-Wechsel:                alle internen Daten vorhanden, externe Referenz unn�tig
   */

   // (1) Sind keine internen Daten vorhanden, befinden wir uns in Szenario 1.1 oder 1.2.
   if (sequenceId == 0) {

      // (1.1) Recompilation ----------------------------------------------------------------------------------------------------------------------------------
      if (UninitializeReason() == REASON_RECOMPILE) {
         if (RestoreChartSequenceId()) {                             // falls externe Referenz vorhanden: restaurieren und validieren
            if (RestoreConfiguration())                              // ohne externe Referenz weiter in (1.2)
               if (ValidateConfiguration())
                  ReadSequence();
         }
      }

      // (1.2) Neustart ---------------------------------------------------------------------------------------------------------------------------------------
      if (sequenceId == 0) {
         if (IsInputSequenceId()) {                                  // Zuerst eine ausdr�cklich angegebene Sequenz-ID restaurieren...
            if (RestoreInputSequenceId())
               if (RestoreConfiguration())
                  if (ValidateConfiguration())
                     ReadSequence();
         }
         else if (RestoreChartSequenceId()) {                        // ...dann ggf. eine im Chart gespeicherte Sequenz-ID restaurieren...
            if (RestoreConfiguration())
               if (ValidateConfiguration())
                  ReadSequence();
         }
         else if (RestoreRunningSequenceId()) {                      // ...dann ID aus laufender Sequenz restaurieren.
            if (RestoreConfiguration())
               if (ValidateConfiguration())
                  ReadSequence();
         }
         else if (ValidateConfiguration()) {                         // Zum Schlu� neue Sequenz anlegen.
            sequenceId = CreateSequenceId();
            if (StartCondition != "")                                // Ohne StartCondition erfolgt sofortiger Einstieg, in diesem Fall wird die
               SaveConfiguration();                                  // Konfiguration erst nach Sicherheitsabfrage in StartSequence() gespeichert.
         }
      }
      ClearChartSequenceId();
   }

   // (1.3) Parameter�nderung ---------------------------------------------------------------------------------------------------------------------------------
   else if (UninitializeReason() == REASON_PARAMETERS) {             // alle internen Daten sind vorhanden
      // TODO: die manuelle Sequence.ID kann ge�ndert worden sein
      if (ValidateConfiguration())
         SaveConfiguration();
   }

   // (1.4) Timeframewechsel ----------------------------------------------------------------------------------------------------------------------------------
   else if (UninitializeReason() == REASON_CHARTCHANGE) {
      GridSize         = intern.GridSize;                            // Alle internen Daten sind vorhanden, es werden nur die nicht-statischen
      LotSize          = intern.LotSize;                             // Inputvariablen restauriert.
      StartCondition   = intern.StartCondition;
      TakeProfitLevels = intern.TakeProfitLevels;
      Sequence.ID      = intern.Sequence.ID;
   }

   // ---------------------------------------------------------------------------------------------------------------------------------------------------------
   else catch("init(1)   unknown init() scenario", ERR_RUNTIME_ERROR);


   // (2) Status anzeigen
   ShowStatus(true);
   if (IsLastError())
      return(last_error);


   // (3) ggf. EA's aktivieren
   int reasons1[] = { REASON_REMOVE, REASON_CHARTCLOSE, REASON_APPEXIT };
   if (IntInArray(UninitializeReason(), reasons1)) /*&&*/ if (!IsExpertEnabled())
      SwitchExperts(true);                                        // TODO: Bug, wenn mehrere EA's den EA-Modus gleichzeitig einschalten


   // (4) nicht auf den n�chsten Tick warten (au�er bei REASON_CHARTCHANGE oder REASON_ACCOUNT)
   int reasons2[] = { REASON_REMOVE, REASON_CHARTCLOSE, REASON_APPEXIT, REASON_PARAMETERS, REASON_RECOMPILE };
   if (IntInArray(UninitializeReason(), reasons2)) /*&&*/ if (!IsTesting())
      SendTick(false);

   return(catch("init(2)"));
}


/**
 * Deinitialisierung
 *
 * @return int - Fehlerstatus
 */
int deinit() {
   if (UninitializeReason() == REASON_CHARTCHANGE) {
      // Input-Parameter sind nicht statisch: f�r's n�chste init() in intern.* zwischenspeichern
      intern.GridSize         = GridSize;
      intern.LotSize          = LotSize;
      intern.StartCondition   = StartCondition;
      intern.TakeProfitLevels = TakeProfitLevels;
      intern.Sequence.ID      = Sequence.ID;
   }
   else if (UninitializeReason()==REASON_CHARTCLOSE || UninitializeReason()==REASON_RECOMPILE) {
      string configFile = TerminalPath() +"\\experts\\presets\\SR."+ sequenceId +".set";
      if (IsFile(configFile))                                        // Ohne Config-Datei wurde Sequenz abgebrochen und braucht/kann
         StoreChartSequenceId();                                     // beim n�chsten init() nicht restauriert werden.
   }
   return(catch("deinit()"));
}


/**
 * Main-Funktion
 *
 * @return int - Fehlerstatus
 */
int onTick() {
   if (status==STATUS_FINISHED || status==STATUS_DISABLED)
      return(last_error);

   static int last.grid.level;


   // (1) Sequenz wartet entweder auf Startsignal...
   if (status == STATUS_WAITING) {
      if (IsStartSignal())                    StartSequence();
   }

   // (2) ...oder l�uft: Status pr�fen und Orders aktualisieren
   else if (UpdateStatus()) {
      if      (IsProfitTargetReached())       FinishSequence();
      else if (last.grid.level != grid.level) UpdatePendingOrders();
   }

   last.grid.level = grid.level;
   firstTick       = false;


   // (3) Status anzeigen
   ShowStatus();

   if (IsLastError())
      return(last_error);
   return(catch("onTick()"));
}


/**
 * Pr�ft und synchronisiert die im EA gespeicherten offenen und pending Orders mit den aktuellen Laufzeitdaten.
 *
 * @return bool - Erfolgsstatus
 */
bool UpdateStatus() {
   grid.floatingPL = 0;

   bool wasPending, isClosed, grid.changed;
   int  orders = ArraySize(orders.ticket);

   for (int i=0; i < orders; i++) {
      if (orders.closeTime[i] == 0) {                                // Ticket pr�fen, wenn es beim letzten Aufruf noch offen war
         if (!OrderSelectByTicket(orders.ticket[i], "UpdateStatus(1)"))
            return(false);

         wasPending = orders.type[i] > OP_SELL;                      // ob die Order beim letzten Aufruf "pending" war

         if (wasPending) {
            // vormals "pending" Order, die inzwischen ausgef�hrt wurde
            if (OrderType() != orders.type[i]) {
               orders.type      [i] = OrderType();
               orders.openTime  [i] = OrderOpenTime();
               orders.openPrice [i] = OrderOpenPrice();
               orders.swap      [i] = OrderSwap();
               orders.commission[i] = OrderCommission();
               orders.profit    [i] = OrderProfit();

               grid.level += MathSign(orders.level[i]);
               if (grid.level > 0) grid.maxLevelLong  = MathMax( grid.level, grid.maxLevelLong ) +0.1;   // (int) double
               else                grid.maxLevelShort = MathMax(-grid.level, grid.maxLevelShort) +0.1;   // (int) double
               grid.changed = true;
            }
         }
         else {
            // Order war beim letzten Aufruf offen
            orders.swap      [i] = OrderSwap();
            orders.commission[i] = OrderCommission();
            orders.profit    [i] = OrderProfit();
         }

         isClosed = OrderCloseTime() != 0;                           // ob die Order jetzt geschlossen ist

         if (!isClosed) {
            // weiterhin offene oder "pending" Order
            grid.floatingPL += OrderSwap() + OrderCommission() + OrderProfit();
         }
         else {
            // vormals "pending" Order, die inzwischen gel�scht oder offene Position, die geschlossen wurde
            orders.closeTime [i] = OrderCloseTime();                 // Bei Spikes kann eine PendingOrder ausgef�hrt *und* bereits geschlossen sein.
            orders.closePrice[i] = OrderClosePrice();

            if (OrderType() <= OP_SELL) {                            // vormals offene Position, die geschlossen wurde
               grid.level      -= MathSign(orders.level[i]);
               grid.stops++;
               grid.realizedPL += OrderSwap() + OrderCommission() + OrderProfit();
               grid.changed     = true;
            }
         }
      }
   }
   grid.profitLoss = grid.realizedPL + grid.floatingPL;

   if (grid.changed) {
      //ForceAlert("UpdateStatus()   grid status changed");
      //SaveStatus();
   }
   return(IsNoError(catch("UpdateStatus(2)")));
}


/**
 * Signalgeber f�r StartSequence(). Wurde kein Limit angegeben (StartCondition = 0 oder ""), gibt die Funktion ebenfalls TRUE zur�ck.
 *
 * @return bool - ob die konfigurierte StartCondition erf�llt ist
 */
bool IsStartSignal() {
   // Das Limit ist erreicht, wenn der Bid-Preis es seit dem letzten Tick ber�hrt oder gekreuzt hat.
   if (EQ(Entry.limit, 0))                                           // kein Limit definiert => immer TRUE
      return(true);

   if (EQ(Bid, Entry.limit) || EQ(Entry.lastBid, Entry.limit)) {     // Bid liegt oder lag beim letzten Tick exakt auf dem Limit
      Entry.lastBid = Entry.limit;                                   // Tritt w�hrend der weiteren Verarbeitung des Ticks ein behandelbarer Fehler auf, wird durch
      return(true);                                                  // Entry.lastBid = Entry.limit das Limit, einmal getriggert, nachfolgend immer wieder getriggert.
   }

   static bool lastBid.init = false;

   if (EQ(Entry.lastBid, 0)) {                                       // Entry.lastBid mu� initialisiert sein => ersten Aufruf �berspringen und Status merken,
      lastBid.init = true;                                           // um firstTick bei erstem tats�chlichen Test gegen Entry.lastBid auf TRUE zur�ckzusetzen
   }
   else {
      if (LT(Entry.lastBid, Entry.limit)) {
         if (GT(Bid, Entry.limit)) {                                 // Bid hat Limit von unten nach oben gekreuzt
            Entry.lastBid = Entry.limit;
            return(true);
         }
      }
      else if (LT(Bid, Entry.limit)) {                               // Bid hat Limit von oben nach unten gekreuzt
         Entry.lastBid = Entry.limit;
         return(true);
      }
      if (lastBid.init) {
         lastBid.init = false;
         firstTick    = true;                                        // firstTick nach erstem tats�chlichen Test gegen Entry.lastBid auf TRUE zur�ckzusetzen
      }
   }

   Entry.lastBid = Bid;
   return(false);
}


/**
 * Beginnt eine neue Trade-Sequenz.
 *
 * @return bool - Erfolgsstatus
 */
bool StartSequence() {
   if (firstTick) {                                                  // Sicherheitsabfrage, wenn der erste Tick sofort einen Trade triggert
      ForceSound("notify.wav");
      int button = ForceMessageBox(ifString(!IsDemo(), "- Live Account -\n\n", "") +"Do you really want to start a new trade sequence now?", __SCRIPT__ +" - StartSequence()", MB_ICONQUESTION|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         return(_false(catch("StartSequence(1)")));
      }
      SaveConfiguration();                                           // StartSequence() beim ersten Tick: jetzt Konfiguration speichern, @see init()
   }

   // (1) GridBase festlegen
   grid.base = ifDouble(EQ(Entry.limit, 0), Bid, Entry.limit);

   double stopPrice, stopLoss;


   // (2) Stop Buy in den Markt legen
   stopPrice  = grid.base + GridSize*Pips;
   stopLoss   = grid.base;
   int ticket = PendingStopOrder(OP_BUYSTOP, stopPrice, stopLoss, 1);
   if (ticket == -1)           return(false);
   if (!Grid.AddOrder(ticket)) return(false);


   // (3) Stop Sell in den Markt legen
   stopPrice = grid.base - GridSize*Pips;
   ticket    = PendingStopOrder(OP_SELLSTOP, stopPrice, stopLoss, -1);
   if (ticket == -1)           return(false);
   if (!Grid.AddOrder(ticket)) return(false);


   // (4) Status �ndern und Sequenz extern speichern
   status = STATUS_PROGRESSING;

   //ForceAlert("StartSequence()   new grid.level = "+ grid.level);
   //debug("StartSequence()   new orders.level = "+ IntArrayToStr(orders.level, NULL));
   return(IsNoError(catch("StartSequence(2)")));
}


/**
 * Setzt dem Grid-Level entsprechend neue bzw. fehlende PendingOrders.
 *
 * @return bool - Erfolgsstatus
 */
bool UpdatePendingOrders() {
   double stopPrice, stopLoss;
   int    nextLevel, ticket;
   bool   isPending, isClosed, nextLevelExists, nextUpperExists, nextLowerExists;

   if (grid.level > 0) {
      // (1) Existenz der n�chsth�heren Stop-Order pr�fen und �brige offene Stop-Orders l�schen
      nextLevel = grid.level + 1;

      for (int i=ArraySize(orders.ticket)-1; i >= 0; i--) {
         isPending = orders.type[i] > OP_SELL;
         isClosed  = orders.closeTime[i] != 0;

         if (isPending && !isClosed) {
            if (orders.level[i] == nextLevel) {
               nextLevelExists = true;
               continue;
            }
            if (!OrderDeleteEx(orders.ticket[i], CLR_NONE)) return(_false(SetLastError(stdlib_PeekLastError())));
            if (!Grid.RemoveOrder(i))                       return(false);
         }
      }

      // (2) ggf. n�chsth�heren Stop Buy in den Markt legen
      if (!nextLevelExists) {
         stopPrice = grid.base +  nextLevel * GridSize*Pips;
         stopLoss  = grid.base + grid.level * GridSize*Pips;
         ticket    = PendingStopOrder(OP_BUYSTOP, stopPrice, stopLoss, nextLevel);
         if (ticket == -1)           return(false);
         if (!Grid.AddOrder(ticket)) return(false);
      }
   }
   else if (grid.level < 0) {
      // (1) Existenz der n�chstniedrigeren Stop-Order pr�fen und �brige offene Stop-Orders l�schen
      nextLevel = grid.level - 1;

      for (i=ArraySize(orders.ticket)-1; i >= 0; i--) {
         isPending = orders.type[i] > OP_SELL;
         isClosed  = orders.closeTime[i] != 0;

         if (isPending && !isClosed) {
            if (orders.level[i] == nextLevel) {
               nextLevelExists = true;
               continue;
            }
            if (!OrderDeleteEx(orders.ticket[i], CLR_NONE)) return(_false(SetLastError(stdlib_PeekLastError())));
            if (!Grid.RemoveOrder(i))                       return(false);
         }
      }

      // (2) ggf. n�chstniedrigere Stop Sell in den Markt legen
      if (!nextLevelExists) {
         stopPrice = grid.base +  nextLevel * GridSize*Pips;
         stopLoss  = grid.base + grid.level * GridSize*Pips;
         ticket    = PendingStopOrder(OP_SELLSTOP, stopPrice, stopLoss, nextLevel);
         if (ticket == -1)           return(false);
         if (!Grid.AddOrder(ticket)) return(false);
      }
   }
   else /*(grid.level == 0)*/ {
      // (1) Existenz der n�chsth�heren und n�chstniedrigeren Stop-Order pr�fen und �brige offene Stop-Orders l�schen
      nextLevel = grid.level - 1;

      // (1) Existenz der n�chsth�heren Stop-Order sicherstellen
      // (2) Existenz der n�chstniedrigeren Stop-Order sicherstellen
      // (3) alle �brigen Stop-Orders l�schen
   }

   //ForceAlert("UpdatePendingOrders()   new grid.level = "+ grid.level);
   //debug("UpdatePendingOrders()   new orders.level = "+ IntArrayToStr(orders.level, NULL));
   return(IsNoError(catch("UpdatePendingOrders()")));
}


/**
 * F�gt den Datenarrays des Grids die angegebene Order hinzu.
 *
 * @param  int ticket - Orderticket
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.AddOrder(int ticket) {
   if (!OrderSelectByTicket(ticket, "Grid.AddOrder(1)"))
      return(false);

   if (!IsMyOrder(sequenceId))
      return(_false(catch("Grid.AddOrder(2)   not my order: #"+ ticket, ERR_RUNTIME_ERROR)));

   int size = ArraySize(orders.ticket) + 1;

   // Arrays vergr��ern
   ArrayResize(orders.ticket,     size);
   ArrayResize(orders.level,      size);
   ArrayResize(orders.type,       size);
   ArrayResize(orders.openTime,   size);
   ArrayResize(orders.openPrice,  size);
   ArrayResize(orders.closeTime,  size);
   ArrayResize(orders.closePrice, size);
   ArrayResize(orders.swap,       size);
   ArrayResize(orders.commission, size);
   ArrayResize(orders.profit,     size);

   int last = size - 1;

   // Daten speichern
   orders.ticket    [last] = OrderTicket();
   orders.type      [last] = OrderType();
   orders.level     [last] = OrderMagicNumber() & 0xFF;              //  8 Bits (Bits 1-8)  => grid.level
   if (OrderType()==OP_SELL || OrderType()==OP_SELLSTOP)
      orders.level[last] = -orders.level[last];
   orders.openTime  [last] = OrderOpenTime();
   orders.openPrice [last] = OrderOpenPrice();
   orders.closeTime [last] = OrderCloseTime();
   orders.closePrice[last] = OrderClosePrice();
   orders.swap      [last] = OrderSwap();
   orders.commission[last] = OrderCommission();
   orders.profit    [last] = OrderProfit();

   return(IsNoError(catch("Grid.AddOrder(3)")));
}


/**
 * Entfernt die Order an der angegebenen Position aus den Datenarrays des Grids.
 *
 * @param  int index - Orderposition
 *
 * @return bool - Erfolgsstatus
 */
bool Grid.RemoveOrder(int index) {
   int size = ArraySize(orders.ticket);
   if (size < index+1)
      return(_false(catch("Grid.RemoveOrder(1)   illegal index "+ index +" for array size of "+ size, ERR_RUNTIME_ERROR)));

   // wenn das zu entfernende Element nicht das Letzte ist
   if (index < size-1) {
      ArrayCopy(orders.ticket,     orders.ticket,     index, index+1);
      ArrayCopy(orders.level,      orders.level,      index, index+1);
      ArrayCopy(orders.type,       orders.type,       index, index+1);
      ArrayCopy(orders.openTime,   orders.openTime,   index, index+1);
      ArrayCopy(orders.openPrice,  orders.openPrice,  index, index+1);
      ArrayCopy(orders.closeTime,  orders.closeTime,  index, index+1);
      ArrayCopy(orders.closePrice, orders.closePrice, index, index+1);
      ArrayCopy(orders.swap,       orders.swap,       index, index+1);
      ArrayCopy(orders.commission, orders.commission, index, index+1);
      ArrayCopy(orders.profit,     orders.profit,     index, index+1);
   }

   int newSize = size-1;

   // Arrays verkleinern
   ArrayResize(orders.ticket,     newSize);
   ArrayResize(orders.level,      newSize);
   ArrayResize(orders.type,       newSize);
   ArrayResize(orders.openTime,   newSize);
   ArrayResize(orders.openPrice,  newSize);
   ArrayResize(orders.closeTime,  newSize);
   ArrayResize(orders.closePrice, newSize);
   ArrayResize(orders.swap,       newSize);
   ArrayResize(orders.commission, newSize);
   ArrayResize(orders.profit,     newSize);

   return(IsNoError(catch("Grid.RemoveOrder(2)")));
}


/**
 * Ob der konfigurierte TakeProfit-Level erreicht oder �berschritten wurde.
 *
 * @return bool
 */
bool IsProfitTargetReached() {
   catch("IsProfitTargetReached()");
   return(false);
}


/**
 * Schlie�t alle offenen Positionen der Sequenz und l�scht verbleibende PendingOrders.
 *
 * @return bool - Erfolgsstatus
 */
bool FinishSequence() {
   if (firstTick) {                                                  // Sicherheitsabfrage, wenn der erste Tick sofort einen Trade triggert
      ForceSound("notify.wav");
      int button = ForceMessageBox(ifString(!IsDemo(), "- Live Account -\n\n", "") +"Do you really want to finish the sequence now?", __SCRIPT__ +" - FinishSequence()", MB_ICONQUESTION|MB_OKCANCEL);
      if (button != IDOK) {
         SetLastError(ERR_CANCELLED_BY_USER);
         return(_false(catch("FinishSequence(1)")));
      }
   }
   return(IsNoError(catch("FinishSequence(2)")));
}


/**
 * Legt eine Stop-Order in den Markt.
 *
 * @param  int    type     - Ordertyp: OP_BUYSTOP | OP_SELLSTOP
 * @param  double price    - Aktivierungspreis
 * @param  double stoploss - Stoploss
 * @param  int    level    - Gridlevel der Order
 *
 * @return int - Ticket der Order oder -1, falls ein Fehler auftrat
 */
int PendingStopOrder(int type, double price, double stoploss, int level) {
   if (type == OP_BUYSTOP) {
      if (LE(price, Ask))         return(_int(-1, catch("PendingStopOrder(1)   illegal "+ OperationTypeDescription(type) +" price: "+ NumberToStr(price, PriceFormat), ERR_INVALID_FUNCTION_PARAMVALUE)));
      if (GE(stoploss, price))    return(_int(-1, catch("PendingStopOrder(2)   illegal stoploss "+ NumberToStr(stoploss, PriceFormat) +" for "+ OperationTypeDescription(type) +" at "+ NumberToStr(price, PriceFormat), ERR_INVALID_FUNCTION_PARAMVALUE)));
      if (level <= 0)             return(_int(-1, catch("PendingStopOrder(3)   illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_FUNCTION_PARAMVALUE)));
   }
   else if (type == OP_SELLSTOP) {
      if (GE(price, Bid))         return(_int(-1, catch("PendingStopOrder(4)   illegal "+ OperationTypeDescription(type) +" price: "+ NumberToStr(price, PriceFormat), ERR_INVALID_FUNCTION_PARAMVALUE)));
      if (NE(stoploss, 0))
         if (LE(stoploss, price)) return(_int(-1, catch("PendingStopOrder(5)   illegal stoploss "+ NumberToStr(stoploss, PriceFormat) +" for "+ OperationTypeDescription(type) +" at "+ NumberToStr(price, PriceFormat), ERR_INVALID_FUNCTION_PARAMVALUE)));
      if (level >= 0)             return(_int(-1, catch("PendingStopOrder(6)   illegal parameter level = "+ level +" for "+ OperationTypeDescription(type), ERR_INVALID_FUNCTION_PARAMVALUE)));
   }
   else                           return(_int(-1, catch("PendingStopOrder(7)   illegal parameter type = "+ type, ERR_INVALID_FUNCTION_PARAMVALUE)));

   int    magicNumber = CreateMagicNumber(level);
   string comment     = StringConcatenate("SR.", sequenceId, ".", NumberToStr(level, "+."));

   int ticket = OrderSendEx(Symbol(), type, LotSize, price, NULL, stoploss, NULL, comment, magicNumber, NULL, CLR_NONE);
   if (ticket == -1)
      SetLastError(stdlib_PeekLastError());

   if (IsError(catch("PendingStopOrder(8)")))
      return(-1);
   return(ticket);
}


/**
 * Generiert einen Wert f�r OrderMagicNumber() f�r den angegebenen Gridlevel.
 *
 * @param  int level - Gridlevel
 *
 * @return int - MagicNumber oder -1, falls ein Fehler auftrat
 */
int CreateMagicNumber(int level) {
   if (sequenceId < 1000) return(_int(-1, catch("CreateMagicNumber(1)   illegal sequenceId = "+ sequenceId, ERR_RUNTIME_ERROR)));
   if (level == 0)        return(_int(-1, catch("CreateMagicNumber(2)   illegal parameter level = "+ level, ERR_INVALID_FUNCTION_PARAMVALUE)));

   int ea       = Strategy.Id &  0x3FF << 22;                        // 10 bit (Bits gr��er 10 l�schen und auf 32 Bit erweitern) | in MagicNumber: Bits 23-32
   int sequence = sequenceId  & 0x3FFF <<  8;                        // 14 bit (Bits gr��er 14 l�schen und auf 22 Bit erweitern  | in MagicNumber: Bits  9-22
   level        = MathAbs(level) +0.1;                               // (int) double: Wert in MagicNumber ist immer positiv
   level       &= 0xFF;                                              //  8 bit (Bits gr��er 8 l�schen)                           | in MagicNumber: Bits  1-8

   return(ea + sequence + level);
}


/**
 * Zeigt den aktuellen Status der Sequenz an.
 *
 * @param  bool init - ob der Aufruf innerhalb der init()-Funktion erfolgt (default: FALSE)
 *
 * @return int - Fehlerstatus
 */
int ShowStatus(bool init=false) {
   if (IsTesting()) /*&&*/ if (!IsVisualMode())
      return(last_error);

   int error = last_error;                                           // bei Funktionseintritt bereits existierenden Fehler zwischenspeichern
   if (IsLastError())
      status = STATUS_DISABLED;

   string msg = "";

   switch (status) {
      case STATUS_WAITING:     msg = StringConcatenate(":  sequence ", sequenceId, " waiting");
                               if (StringLen(StartCondition) > 0)
                                  msg = StringConcatenate(msg, " for crossing of ", NumberToStr(Entry.limit, PriceFormat));                                                                                                 break;
      case STATUS_PROGRESSING: msg = StringConcatenate(":  sequence ", sequenceId, " progressing at level ", grid.level, "  (", ifString(grid.maxLevelLong==0, "", "+"), grid.maxLevelLong, "/", -grid.maxLevelShort, ")"); break;
      case STATUS_FINISHED:    msg = StringConcatenate(":  sequence ", sequenceId, " finished");                                                                                                                            break;
      case STATUS_DISABLED:    msg = StringConcatenate(":  sequence ", sequenceId, " disabled");
                               if (IsLastError())
                                  msg = StringConcatenate(msg, "  [", ErrorDescription(last_error), "]");                                                                                                                   break;
      default:
         return(catch("ShowStatus(1)   illegal sequence status = "+ status, ERR_RUNTIME_ERROR));
   }

   msg = StringConcatenate(__SCRIPT__, msg,                                                                                                     NL,
                                                                                                                                                NL,
                           "GridSize:       ", GridSize, " pip",                                                                                NL,
                           "LotSize:         ", NumberToStr(LotSize, ".+"), " lot = ", DoubleToStr(GridSize * PipValue(LotSize), 2), " / stop", NL,
                           "Realized:       ", grid.stops, " stop"+ ifString(grid.stops==1, "", "s") +" = ", DoubleToStr(grid.realizedPL, 2),   NL,
                         //"TakeProfit:    ", TakeProfitLevels, " levels  (1.6016'5 = 875.00)",                                                 NL,
                           "Breakeven:   ", NumberToStr(grid.breakevenLong, PriceFormat), " / ", NumberToStr(grid.breakevenShort, PriceFormat), NL,
                           "Profit/Loss:    ", DoubleToStr(grid.profitLoss, 2),                                                                 NL);

   // einige Zeilen Abstand nach oben f�r Instrumentanzeige und ggf. vorhandene Legende
   Comment(StringConcatenate(NL, NL, msg));
   if (init)
      WindowRedraw();

   if (!IsError(catch("ShowStatus(2)")))
      last_error = error;                                            // bei Funktionseintritt bereits existierenden Fehler restaurieren
   return(last_error);
}


/**
 * Ob in den Input-Parametern ausdr�cklich eine zu benutzende Sequenz-ID angegeben wurde. Hier wird nur gepr�ft,
 * ob ein Wert angegeben wurde. Die G�ltigkeit dieser ID wird erst in RestoreInputSequenceId() �berpr�ft.
 *
 * @return bool
 */
bool IsInputSequenceId() {
   return(StringLen(StringTrim(Sequence.ID)) > 0);
}


/**
 * Validiert und setzt die in der Konfiguration angegebene Sequenz-ID.
 *
 * @return bool - ob eine g�ltige Sequenz-ID gefunden und restauriert wurde
 */
bool RestoreInputSequenceId() {
   if (IsInputSequenceId()) {
      string strValue = StringTrim(Sequence.ID);

      if (StringIsInteger(strValue)) {
         int iValue = StrToInteger(strValue);
         if (1000 <= iValue) /*&&*/ if (iValue <= 16383) {
            sequenceId  = iValue;
            Sequence.ID = strValue;
            return(true);
         }
      }
      catch("RestoreInputSequenceId()  Invalid input parameter Sequence.ID = \""+ Sequence.ID +"\"", ERR_INVALID_INPUT_PARAMVALUE);
   }
   return(false);
}


/**
 * Speichert die aktuelle Sequenz-ID im Chart, soda� die Sequenz sp�ter daraus restauriert werden kann.
 *
 * @return int - Fehlerstatus
 */
int StoreChartSequenceId() {
   string label = __SCRIPT__ +".sequenceId";

   if (ObjectFind(label) != -1)
      ObjectDelete(label);
   ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
   ObjectSet(label, OBJPROP_XDISTANCE, -sequenceId);                 // negativer Wert (im nicht sichtbaren Bereich)

   return(catch("StoreChartSequenceId()"));
}


/**
 * Restauriert eine im Chart ggf. gespeicherte Sequenz-ID.
 *
 * @return bool - ob eine Sequenz-ID gefunden und restauriert wurde
 */
bool RestoreChartSequenceId() {
   string label = __SCRIPT__ +".sequenceId";

   if (ObjectFind(label)!=-1) /*&&*/ if (ObjectType(label)==OBJ_LABEL) {
      sequenceId = MathAbs(ObjectGet(label, OBJPROP_XDISTANCE)) +0.1;   // (int) double
      return(_true(catch("RestoreChartSequenceId(1)")));
   }
   return(_false(catch("RestoreChartSequenceId(2)")));
}


/**
 * L�scht im Chart gespeicherte Sequenzdaten.
 *
 * @return int - Fehlerstatus
 */
int ClearChartSequenceId() {
   string label = __SCRIPT__ +".sequenceId";

   if (ObjectFind(label) != -1)
      ObjectDelete(label);

   return(catch("ClearChartSequenceId()"));
}


/**
 * Restauriert die Sequenz-ID einer laufenden Sequenz.
 *
 * @return bool - ob eine laufende Sequenz gefunden und die ID restauriert wurde
 */
bool RestoreRunningSequenceId() {
   // offene Positionen einlesen
   for (int i=OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))               // FALSE: w�hrend des Auslesens wird in einem anderen Thread eine offene Order entfernt
         continue;

      if (IsMyOrder()) {
         sequenceId = OrderMagicNumber() >> 8 & 0x3FFF;              // 14 Bits (Bits 9-22) => sequenceId
         return(_true(catch("RestoreRunningSequenceId(1)")));
      }
   }
   return(_false(catch("RestoreRunningSequenceId(2)")));
}


/**
 * Ob die aktuell selektierte Order zu dieser Strategie geh�rt. Wird eine Sequenz-ID angegeben, wird zus�tzlich �berpr�ft,
 * ob die Order zur angegebenen Sequenz geh�rt.
 *
 * @param  int sequenceId - ID einer Sequenz (default: NULL)
 *
 * @return bool
 */
bool IsMyOrder(int sequenceId = NULL) {
   if (OrderSymbol() == Symbol()) {
      if (OrderMagicNumber() >> 22 == Strategy.Id) {
         if (sequenceId == NULL)
            return(true);
         return(sequenceId == OrderMagicNumber() >> 8 & 0x3FFF);     // 14 Bits (Bits 9-22) => sequenceId
      }
   }
   return(false);
}


/**
 * Generiert eine neue Sequenz-ID.
 *
 * @return int - Sequenz-ID im Bereich 1000-16383 (14 bit)
 */
int CreateSequenceId() {
   MathSrand(GetTickCount());
   int id;
   while (id < 2000) {                                               // Das abschlie�ende Shiften halbiert den Wert und wir wollen mindestens eine 4-stellige ID haben.
      id = MathRand();
   }
   return(id >> 1);
}


/**
 * Validiert die aktuelle Konfiguration.
 *
 * @return bool - ob die Konfiguration g�ltig ist
 */
bool ValidateConfiguration() {
   // GridSize
   if (GridSize < 1)   return(_false(catch("ValidateConfiguration(1)  Invalid input parameter GridSize = "+ GridSize, ERR_INVALID_INPUT_PARAMVALUE)));

   // LotSize
   if (LE(LotSize, 0)) return(_false(catch("ValidateConfiguration(2)  Invalid input parameter LotSize = "+ NumberToStr(LotSize, ".+"), ERR_INVALID_INPUT_PARAMVALUE)));

   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   int error = GetLastError();
   if (IsError(error))                      return(_false(catch("ValidateConfiguration(3)   symbol=\""+ Symbol() +"\"", error)));
   if (LT(LotSize, minLot))                 return(_false(catch("ValidateConfiguration(4)   Invalid input parameter LotSize = "+ NumberToStr(LotSize, ".+") +" (MinLot="+  NumberToStr(minLot, ".+" ) +")", ERR_INVALID_INPUT_PARAMVALUE)));
   if (GT(LotSize, maxLot))                 return(_false(catch("ValidateConfiguration(5)   Invalid input parameter LotSize = "+ NumberToStr(LotSize, ".+") +" (MaxLot="+  NumberToStr(maxLot, ".+" ) +")", ERR_INVALID_INPUT_PARAMVALUE)));
   if (NE(MathModFix(LotSize, lotStep), 0)) return(_false(catch("ValidateConfiguration(6)   Invalid input parameter LotSize = "+ NumberToStr(LotSize, ".+") +" (LotStep="+ NumberToStr(lotStep, ".+") +")", ERR_INVALID_INPUT_PARAMVALUE)));

   // StartCondition
   StartCondition = StringReplace(StartCondition, " ", "");
   if (StringLen(StartCondition) == 0) {
      Entry.limit = 0;
   }
   else if (StringIsNumeric(StartCondition)) {
      Entry.limit = StrToDouble(StartCondition);
      if (LT(Entry.limit, 0)) return(_false(catch("ValidateConfiguration(7)  Invalid input parameter StartCondition = \""+ StartCondition +"\"", ERR_INVALID_INPUT_PARAMVALUE)));
      if (EQ(Entry.limit, 0))
         StartCondition = "";
   }
   else                       return(_false(catch("ValidateConfiguration(8)  Invalid input parameter StartCondition = \""+ StartCondition +"\"", ERR_INVALID_INPUT_PARAMVALUE)));

   // TakeProfitLevels
   if (TakeProfitLevels < 1)  return(_false(catch("ValidateConfiguration(9)  Invalid input parameter TakeProfitLevels = "+ TakeProfitLevels, ERR_INVALID_INPUT_PARAMVALUE)));

   // Sequence.ID: falls gesetzt, wurde sie schon in RestoreInputSequenceId() validiert

   // TODO: Nach Parameter�nderung die neue Konfiguration mit einer evt. bereits laufenden Sequenz abgleichen
   //       oder Parameter werden ge�ndert, ohne vorher im Input-Dialog die Konfigurationsdatei der Sequenz zu laden.

   return(IsNoError(catch("ValidateConfiguration(10)")));
}


/**
 * Speichert aktuelle Konfiguration und Laufzeitdaten der Instanz, um die nahtlose Wiederauf- und �bernahme durch eine
 * andere Instanz im selben oder einem anderen Terminal zu erm�glichen.
 *
 * @return int - Fehlerstatus
 */
int SaveConfiguration() {
   if (sequenceId == 0)
      return(catch("SaveConfiguration(1)   illegal value of sequenceId = "+ sequenceId, ERR_RUNTIME_ERROR));

   // (1) Daten zusammenstellen
   string lines[];  ArrayResize(lines, 0);
   ArrayPushString(lines, /*string*/ "Sequence.ID="     +             sequenceId      );
   ArrayPushString(lines, /*int   */ "GridSize="        +             GridSize        );
   ArrayPushString(lines, /*double*/ "LotSize="         + NumberToStr(LotSize, ".+")  );
   ArrayPushString(lines, /*string*/ "StartCondition="  +             StartCondition  );
   ArrayPushString(lines, /*int   */ "TakeProfitLevels="+             TakeProfitLevels);


   // (2) Daten in lokale Datei schreiben
   string filename = "presets\\SR."+ sequenceId +".set";             // "experts\files\presets" ist ein Softlink auf "experts\presets", dadurch ist
                                                                     // das Presets-Verzeichnis f�r die MQL-Dateifunktionen erreichbar.
   int hFile = FileOpen(filename, FILE_CSV|FILE_WRITE);
   if (hFile < 0)
      return(catch("SaveConfiguration(2)  FileOpen(file=\""+ filename +"\")"));

   for (int i=0; i < ArraySize(lines); i++) {
      if (FileWrite(hFile, lines[i]) < 0) {
         int error = GetLastError();
         FileClose(hFile);
         return(catch("SaveConfiguration(3)  FileWrite(line #"+ (i+1) +")", error));
      }
   }
   FileClose(hFile);


   // (3) Datei auf Server laden
   if (!IsTesting()) {
      error = UploadConfiguration(ShortAccountCompany(), AccountNumber(), StdSymbol(), filename);
      if (IsError(error))
         return(error);
   }
   return(catch("SaveConfiguration(4)"));
}


/**
 * L�dt die angegebene Konfigurationsdatei auf den Server.
 *
 * @param  string company     - Account-Company
 * @param  int    account     - Account-Number
 * @param  string symbol      - Symbol der Konfiguration
 * @param  string presetsFile - Dateiname, relativ zu "{terminal-directory}\experts"
 *
 * @return int - Fehlerstatus
 */
int UploadConfiguration(string company, int account, string symbol, string presetsFile) {
   if (IsTesting())
      return(_NO_ERROR(debug("UploadConfiguration()   skipping in tester")));

   // TODO: Existenz von wget.exe pr�fen

   string parts[]; int size = Explode(presetsFile, "\\", parts, NULL);
   string file = parts[size-1];                                         // einfacher Dateiname ohne Verzeichnisse

   // Befehlszeile f�r Shellaufruf zusammensetzen
   string presetsPath  = TerminalPath() +"\\experts\\" + presetsFile;   // Dateinamen mit vollst�ndigen Pfaden
   string responsePath = presetsPath +".response";
   string logPath      = presetsPath +".log";
   string url          = "http://sub.domain.tld/uploadSRConfiguration.php?company="+ UrlEncode(company) +"&account="+ account +"&symbol="+ UrlEncode(symbol) +"&name="+ UrlEncode(file);
   string cmdLine      = "wget.exe -b \""+ url +"\" --post-file=\""+ presetsPath +"\" --header=\"Content-Type: text/plain\" -O \""+ responsePath +"\" -a \""+ logPath +"\"";

   // Existenz der Datei pr�fen
   if (!IsFile(presetsPath))
      return(catch("UploadConfiguration(1)   file not found: \""+ presetsPath +"\"", ERR_FILE_NOT_FOUND));

   // Datei hochladen, WinExec() kehrt ohne zu warten zur�ck, wget -b beschleunigt zus�tzlich
   int error = WinExec(cmdLine, SW_HIDE);                               // SW_SHOWNORMAL|SW_HIDE
   if (error < 32)
      return(catch("UploadConfiguration(2) ->kernel32::WinExec(cmdLine=\""+ cmdLine +"\"), error="+ error +" ("+ ShellExecuteErrorToStr(error) +")", ERR_WIN32_ERROR));

   return(catch("UploadConfiguration(3)"));
}


/**
 * Liest die Konfiguration einer Sequenz ein und setzt die internen Variablen entsprechend. Ohne lokale Konfiguration
 * wird die Konfiguration vom Server geladen und lokal gespeichert.
 *
 * @return bool - ob die Konfiguration erfolgreich restauriert wurde
 */
bool RestoreConfiguration() {
   if (sequenceId == 0)
      return(_false(catch("RestoreConfiguration(1)   illegal value of sequenceId = "+ sequenceId, ERR_RUNTIME_ERROR)));

   // TODO: Existenz von wget.exe pr�fen

   // (1) bei nicht existierender lokaler Konfiguration die Datei vom Server laden
   string filesDir = TerminalPath() +"\\experts\\files\\";           // "experts\files\presets" ist ein Softlink auf "experts\presets", dadurch
   string fileName = "presets\\SR."+ sequenceId +".set";             // ist das Presets-Verzeichnis f�r die MQL-Dateifunktionen erreichbar.

   if (!IsFile(filesDir + fileName)) {
      // Befehlszeile f�r Shellaufruf zusammensetzen
      string url        = "http://sub.domain.tld/downloadSRConfiguration.php?company="+ UrlEncode(ShortAccountCompany()) +"&account="+ AccountNumber() +"&symbol="+ UrlEncode(StdSymbol()) +"&sequence="+ sequenceId;
      string targetFile = filesDir +"\\"+ fileName;
      string logFile    = filesDir +"\\"+ fileName +".log";
      string cmdLine    = "wget.exe \""+ url +"\" -O \""+ targetFile +"\" -o \""+ logFile +"\"";

      debug("RestoreConfiguration()   downloading configuration for sequence "+ sequenceId);

      int error = WinExecAndWait(cmdLine, SW_HIDE);                  // SW_SHOWNORMAL|SW_HIDE
      if (IsError(error))
         return(_false(SetLastError(error)));

      debug("RestoreConfiguration()   configuration for sequence "+ sequenceId +" successfully downloaded");
      FileDelete(fileName +".log");
   }

   // (2) Datei einlesen
   string config[];
   int lines = FileReadLines(fileName, config, true);
   if (lines < 0)
      return(_false(SetLastError(stdlib_PeekLastError())));
   if (lines == 0) {
      FileDelete(fileName);
      return(_false(catch("RestoreConfiguration(2)   no configuration found for sequence "+ sequenceId, ERR_RUNTIME_ERROR)));
   }

   // (3) Zeilen in Schl�ssel-Wert-Paare aufbrechen, Datentypen validieren und Daten �bernehmen
   int keys[4]; ArrayInitialize(keys, 0);
   #define I_GRIDSIZE          0
   #define I_LOTSIZE           1
   #define I_START_CONDITION   2
   #define I_TAKEPROFIT_LEVELS 3

   string parts[];
   for (int i=0; i < lines; i++) {
      if (Explode(config[i], "=", parts, 2) != 2) return(_false(catch("RestoreConfiguration(3)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)));
      string key=parts[0], value=parts[1];

      if (key == "GridSize") {
         if (!StringIsDigit(value))               return(_false(catch("RestoreConfiguration(4)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)));
         GridSize = StrToInteger(value);
         keys[I_GRIDSIZE] = 1;
      }
      else if (key == "LotSize") {
         if (!StringIsNumeric(value))             return(_false(catch("RestoreConfiguration(5)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)));
         LotSize = StrToDouble(value);
         keys[I_LOTSIZE] = 1;
      }
      else if (key == "StartCondition") {
         StartCondition = value;
         keys[I_START_CONDITION] = 1;
      }
      else if (key == "TakeProfitLevels") {
         if (!StringIsDigit(value))               return(_false(catch("RestoreConfiguration(6)   invalid configuration file \""+ fileName +"\" (line \""+ config[i] +"\")", ERR_RUNTIME_ERROR)));
         TakeProfitLevels = StrToInteger(value);
         keys[I_TAKEPROFIT_LEVELS] = 1;
      }
   }
   if (IntInArray(0, keys))                       return(_false(catch("RestoreConfiguration(7)   one or more configuration values missing in file \""+ fileName +"\"", ERR_RUNTIME_ERROR)));
   Sequence.ID = sequenceId;

   return(IsNoError(catch("RestoreConfiguration(8)")));
}


/**
 * Liest die aktuelle Sequenz neu ein. Die Variable sequenceId und die Konfiguration der Sequenz sind beim Aufruf immer g�ltig.
 *
 * @return bool - Erfolgsstatus
 */
bool ReadSequence() {
   return(IsNoError(catch("ReadSequence()")));
}
