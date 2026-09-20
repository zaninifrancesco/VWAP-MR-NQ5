# Regole Strategia: VWAP Mean Reversion (NAS100 CFD - M5)

Documento di riferimento pulito e sintetico con tutte le regole operative della strategia.

---

## 1. Asset & Setup Tecnico
- **Strumento:** NASDAQ 100 CFD (`US100`, `NAS100`, `USTEC`).
- **Timeframe:** M5 (5 Minuti).
- **Piattaforma:** MetaTrader 5 (MQL5).
- **Indicatori:** VWAP con bande di deviazione standard ($\pm 1.5\sigma$).

---

## 2. Parametri VWAP (TradingView Parity)
- **Source (Prezzo):** `Open` (NON `hlc3`).
- **Anchor (Reset):** Giornaliero (`Session` / reset alle `00:00` orario server MT5).
- **Offset:** `0`.
- **Bande:**
  - Solo Banda #1 attiva con moltiplicatore = **$1.5$** ($\text{VWAP} \pm 1.5 \times \text{StdDev}$).
  - Banda #2 e #3: disattivate.
- **Regola di calcolo:**
  - I valori di VWAP e Bande vengono calcolati rigorosamente su candele chiuse (`Bar[1]` e `Bar[2]`). Nessun ricalcolo intrabar per i segnali (Zero Repainting).

---

## 3. Finestra Operativa & Sessione
- **Orario Operativo (Ora Italiana CET/CEST):**
  - **Inizio (Open Window):** `15:30` (Apertura Cash Market USA).
  - **Fine Trigger (Close Window):** `22:00` (Nessun nuovo ordine consentito dopo quest'orario).
- **Filtro Trades Giornalieri:**
  - Massimo **1 trade al giorno**. Una volta eseguito un trade, il latch blocca ulteriori ingressi fino al giorno successivo.
- **EOD Hard Close (Uscita Forzata Fine Sessione):**
  - Alle ore `22:00` orario italiano, se c'è ancora una posizione aperta a mercato, viene **chiusa immediatamente a mercato**. Nessuna posizione può essere portata overnight.

---

## 4. Logica delle Entry (Regole di Ingresso)

Tutte le valutazioni di ingresso avvengono sul **primo tick di apertura di una nuova barra M5 (`Bar 0`)**, valutando le candele chiuse precedenti (`Bar 1` e `Bar 2`).

### Chiarimento Fondamentale su Breakout Pre-Sessione:
- **NON è richiesto che il breakout avvenga all'interno della sessione.**
- Se alle `15:30` (apertura sessione) il prezzo si trova **già al di fuori delle bande** (perché uscito durante la notte o in pre-market), il setup è **immediatamente valido**:
  - NON serve attendere che il prezzo rientri per poi uscire di nuovo.
  - Basta che il prezzo si trovi fuori e la candela chiuda di nuovo dentro la banda all'interno della sessione operativa per attivare il trade.

---

### A. Setup LONG (Mean Reversion dalla Banda Inferiore)
1. **Condizione Fuori Banda:**
   - La candela precedente `Bar 2` ha chiuso al di sotto della banda inferiore:
     $$\text{Close}[2] < \text{LowerBand}[2]$$
     *(oppure il prezzo stazionava già al di sotto della banda).*
2. **Condizione Rientro:**
   - La candela appena chiusa `Bar 1` chiude tornando all'interno della banda (sopra la banda inferiore):
     $$\text{Close}[1] > \text{LowerBand}[1]$$
3. **Trigger:**
   - Apertura immediata a mercato (BUY a prezzo `Ask`) sul primo tick di `Bar 0`.
4. **Stop Loss (SL):**
   - Minimo strutturale tra `Low[1]` e `Low[2]`:
     $$\text{SL} = \min(\text{Low}[1], \text{Low}[2])$$
5. **Take Profit (TP):**
   - Rapporto Rischio/Rendimento fisso **1:2**:
     $$\text{TP} = \text{EntryPrice} + 2.0 \times (\text{EntryPrice} - \text{SL})$$

---

### B. Setup SHORT (Mean Reversion dalla Banda Superiore)
1. **Condizione Fuori Banda:**
   - La candela precedente `Bar 2` ha chiuso al di sopra della banda superiore:
     $$\text{Close}[2] > \text{UpperBand}[2]$$
     *(oppure il prezzo stazionava già al di sopra della banda).*
2. **Condizione Rientro:**
   - La candela appena chiusa `Bar 1` chiude tornando all'interno della banda (sotto la banda superiore):
     $$\text{Close}[1] < \text{UpperBand}[1]$$
3. **Trigger:**
   - Apertura immediata a mercato (SELL a prezzo `Bid`) sul primo tick di `Bar 0`.
4. **Stop Loss (SL):**
   - Massimo strutturale tra `High[1]` e `High[2]`:
     $$\text{SL} = \max(\text{High}[1], \text{High}[2])$$
5. **Take Profit (TP):**
   - Rapporto Rischio/Rendimento fisso **1:2**:
     $$\text{TP} = \text{EntryPrice} - 2.0 \times (\text{SL} - \text{EntryPrice})$$

---

## 5. Gestione della Posizione (In-Trade Management)

### Break-Even (BE) a 1:1 R:R
- Valutato ad **ogni singolo tick** durante tutta la durata del trade.
- Quando il prezzo a favore raggiunge il livello $1:1$ di Rischio/Rendimento:
  - **Per Long:** $\text{Bid} \ge \text{EntryPrice} + (\text{EntryPrice} - \text{InitialSL})$
  - **Per Short:** $\text{Ask} \le \text{EntryPrice} - (\text{InitialSL} - \text{EntryPrice})$
- **Azione:** Lo Stop Loss viene modificato e spostato al prezzo di ingresso originale ($\text{EntryPrice}$).
- **Idempotenza:** La modifica avviene una sola volta per trade.

---

## 6. Money Management (Sizing Rischio Fisso)
- Calcolo dinamico dei lotti basato sulla percentuale di capitale rischiata (`InpRiskPercent`, default $1.0\%$):
  $$\text{Capitale a Rischio} = \text{Balance} \times \frac{\text{RiskPercent}}{100}$$
  $$\text{Lotti} = \frac{\text{Capitale a Rischio}}{\left(\frac{|\text{Entry} - \text{SL}|}{\text{TickSize}}\right) \times \text{TickValue}}$$
- Arrotondamento per difetto allo step consentito dal broker (`SYMBOL_VOLUME_STEP`).
- Controllo stringente su minimo e massimo volume consentito (`SYMBOL_VOLUME_MIN`, `SYMBOL_VOLUME_MAX`).
