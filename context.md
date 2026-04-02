# CSC Leasing Data Context
# This file is returned by the get_context tool to give Claude domain knowledge.

## DATABASE RULES (ALWAYS FOLLOW)
- All Salesforce tables are in the `sf` schema (e.g., sf.Opportunity, sf.Lease, sf.Asset)
- **Table names do NOT use `__c` suffix** — it's `sf.Lease` not `sf.Lease__c`. Only *fields* on those tables use `__c` (e.g., `Stage__c`, `Account__c`). This applies to ALL tables — standard SF objects (Account, Opportunity, Contact) AND custom objects (Lease, Asset, Workout, Credit_Facility, etc.).
- **Complete sf table list (canonical):** Account, Asset, Campaign, Client_Invoice, Company_Information, Contact, Credit_Event, Credit_Facility, Credit_Facility_History, Credit_Request, Credit_Request_History, CSC_Scorecard, Default_Ticket, Deposit, Deposit_History, Drawdown, EOL_Document, Equipment_Asset_History, Equipment_Sale, Factor, Forecast_Instance, Forecast_Instance_Goal, Investment, InvoiceLineItem, Lead, Lease, Lease_History, Loan_Package, Loan_Package_ChangeEvent, Loan_Package_History, Location, Opportunity, OpportunityFieldHistory, Orders, Payment_Schedule, Payment_Schedule_Line_Item, Record_History, RMA_Document, SalesForceUser, Task, Vendor, Vendor_Invoice, Workout, Workout_History. (Date-suffixed tables like `asset_20260302` are monthly snapshots — ignore unless asked for historical comparisons.)
- The billing view is in `dbo` schema: dbo.vw_Lease_Matching_Master
- ALWAYS filter `WHERE IsDeleted = 0` on every sf table
- Exclude Placeholder records: `WHERE Stage__c != 'Placeholder'` or `WHERE StageName != 'Placeholder'`
- Use T-SQL syntax (this is Azure SQL Server)
- GP text fields have trailing spaces — use RTRIM() when comparing or displaying

## ENTITY RELATIONSHIPS

```
Account (Customer Company)
  ↓ Account.Id = Lease.Account__c  ← DIRECT (preferred, 100% populated)
  ↓ Account.Id = Opportunity.AccountId
Lease (Contract)
  ↓ Id = Asset.Lease__c
Asset (Individual Equipment)
  ↓ Location__c = Location.Id
Location (Physical Site)

Lease ← Opportunity (optional): Lease.Opportunity__c = Opportunity.Id  (only 59% of leases have this)

Lease.Id = dbo.vw_Lease_Matching_Master.id  (billing bridge)

Lease → Payment_Schedule → Payment_Schedule_Line_Item  (scheduled rent stream)
```

### Key Joins

**CRITICAL: Lease has a DIRECT FK to Account via `Lease.Account__c`.** Always use this for Lease → Account joins. Do NOT route through Opportunity — 41% of leases (5,939) have no Opportunity__c and will be silently dropped.

- **Lease → Account (PREFERRED): `sf.Lease.Account__c = sf.Account.Id`** — 100% populated
- Lease → Opportunity (optional): `sf.Lease.Opportunity__c = sf.Opportunity.Id` — only 59% populated
- Lease → Asset: `sf.Asset.Lease__c = sf.Lease.Id`
- Opportunity → Account: `sf.Opportunity.AccountId = sf.Account.Id`
- Lease → Billing: `dbo.vw_Lease_Matching_Master.id = sf.Lease.Id`
- Billing → Account (shortcut): `dbo.vw_Lease_Matching_Master.account__c = sf.Account.Id`
- Asset → Equipment_Sale: `sf.Equipment_Sale.Asset__c = sf.Asset.Id`
- Account → Workout: `sf.Workout.Account__c = sf.Account.Id` (Workout is at ACCOUNT level, not lease level)
- Lease → Payment_Schedule: `sf.Payment_Schedule.Lease__c = sf.Lease.Id`
- Extension → Original Lease: `sf.Lease.Previous_Lease_Extension__c = sf.Lease.Id` (on the extension record)
- Addendum → Original Lease: `sf.Lease.Previous_Lease_Addendum__c = sf.Lease.Id` (on the addendum record)
- Payment_Schedule → Line Items: `sf.Payment_Schedule_Line_Item.Payment_Schedule__c = sf.Payment_Schedule.Id`
- Line Item → Lease (shortcut): `sf.Payment_Schedule_Line_Item.Lease__c = sf.Lease.Id`

### Cardinality
- One Account → many Leases (via Lease.Account__c — DIRECT, preferred)
- One Account → many Opportunities
- One Opportunity → one or many Leases (splits/amendments) — but 41% of leases have no Opportunity
- One Lease → one or many Assets (equipment pieces)
- One Lease → many billing rows in vw_Lease_Matching_Master
- One Lease → one or more Payment_Schedules → many Payment_Schedule_Line_Items (one per month)
- One Account → many child Accounts (via ParentId) — sparse, only 138 of 22,436 accounts

### Parent/Child Account Hierarchy

**Structure:** `Account.ParentId` → parent `Account.Id`. `Parent_Account_Name__c` is a text/formula field with the parent's name. Almost entirely flat: 135 single-level (child → parent), only 3 two-level (child → parent → grandparent). No deeper nesting.

**Coverage:** Only 138 accounts (0.6%) have a parent. 78 distinct parent accounts. Family groups hold ~$59M of the $1.16B total portfolio (5%). The other 95% is standalone accounts.

**CRITICAL: Rollup fields do NOT aggregate across the hierarchy.** `Total_Active_Cost__c`, `Total_Active_Hardware__c`, `Unbilled_Remaining_Rent__c`, etc. on the parent account only reflect leases directly on that account — they do NOT sum children. Parent holding companies typically show $0 in rollup fields while children carry the actual exposure.

**"What's our total exposure to [company]?" — use this pattern:**
```sql
-- Family exposure rollup (parent + all children)
WITH family AS (
    SELECT Id FROM sf.Account WHERE Id = @parent_id AND IsDeleted = 0
    UNION ALL
    SELECT Id FROM sf.Account WHERE ParentId = @parent_id AND IsDeleted = 0
)
SELECT SUM(a.Total_Active_Cost__c) as family_active_cost,
       SUM(a.Unbilled_Remaining_Rent__c) as family_unbilled_rent,
       COUNT(DISTINCT a.Id) as accounts_in_family
FROM family f
JOIN sf.Account a ON a.Id = f.Id
```

**If the user asks by name (not ID), find the parent first:**
```sql
-- Find parent for a company (check if it IS a parent, or get its parent)
SELECT COALESCE(p.Id, a.Id) as family_root_id,
       COALESCE(p.Name, a.Name) as family_root_name
FROM sf.Account a
LEFT JOIN sf.Account p ON a.ParentId = p.Id AND p.IsDeleted = 0
WHERE a.IsDeleted = 0 AND a.Name LIKE '%company_name%'
```

**Key fields:**
- `ParentId` — FK to parent Account.Id (NULL = standalone or root parent)
- `Parent_Account_Name__c` — text field with parent's name (NULL if no parent)
- `Credit_Top_50__c` — boolean, top 50 credit exposures. Applied at the account level, not family level (only 2 of 50 are child accounts).
- `Top_25__c` — boolean, top 25 accounts

## ENTITY DISAMBIGUATION

**Opportunity** = a deal in the sales pipeline. Has StageName (27 values). Exists from inception through close.
**Lease** = the actual contract after Closed Won. Has Stage__c (10 values) and Sub_Stage__c (29 values). Links to Opportunity via Opportunity__c.
**Asset** = individual equipment on a lease. Has equipment ID fields and financial metrics. Links to Lease via Lease__c.
One deal (Opportunity) may produce multiple Leases, each with multiple Assets.

### Lease Record Types
Each Lease has a RecordType.Name that determines its structure:
- **Regular** — standard lease
- **Sale Leaseback** — customer sells equipment to CSC, leases it back (grouped with Regular for rollups)
- **Accumulating** — pre-commencement funding, equipment added over time before billing starts
- **Accumulating Sale Leaseback** — accumulating + sale leaseback (grouped with Accumulating for rollups)
- **Extension** — lease term extension (grouped with Extension for rollups)
- **Extension Sale Leaseback** — extension + sale leaseback (grouped with Extension for rollups)
- **Restructure** — renegotiated terms (grouped with Extension for rollups)

**Record_Type_Rollup__c** simplifies to: Regular, Accumulating, Extension

### Lease Business Line Classification
- `HaaS__c` (Yes/No) — Hardware as a Service. "Yes" = HaaS lease, "No" = Standard.
- `Internal_Purchased_Sold__c` — Syndication status: Internal (CSC originated), Purchased (bought from syndication partner), Sold (syndicated out), To Be Syndicated
- `Disposition_Type__c` — CSC Originated, Syndicated Purchased, etc.
- `Payment_Frequency__c` — Monthly, Quarterly Arrears, Quarterly Beginning, Semi-Annual, Annual. Affects N_Divisor and IR_Divisor calculations.

### Account Risk & Credit Fields
- `Risk_RatingPicklist__c` — numeric risk rating (1-7 scale, on Account)
- `Performance_Grade__c` — color-coded grade (Blue, etc.)
- `Available_Credit__c` = Total Credit Limit - Total Cost in DIP
- `Active_DIP__c` = Total_Active_Cost + Total_Cost_in_DIP (total exposure)
- `A_R_Watchlist__c` — boolean, flagged accounts with AR concerns
- `Underwriting_Status__c` — credit review status
- `Days_Since_Last_Review__c` = TODAY() - Last_Review__c
- `Hardware_Mix__c` = Total_Active_HFCE / Total_Active_Cost (hard asset ratio)

### Asset Cost Classification
Assets have a `Factor_Category__c` that determines hard vs. soft cost:
- **Hard (HFCE):** H, H2, H3, H4, F (furniture), E, C (copier)
- **Soft:** S (software), IS (installation/services), M (maintenance), LHI (leasehold improvement), FR (freight)
- `Hard_Soft__c` — derived field: "Hard" or "Soft"
- Important: "Installed" is the active asset status (not "Active"). Filter `Status__c = 'Installed'` for currently active equipment.

## OPPORTUNITY STAGES (StageName — 27 values)

Pipeline stages in order: Qualified (25%) → Term Sheet (40%) → Signed Term Sheet (50%) → Signed Proposal (75%) → Final Negotiation (80%) → CSC Approval Process (85%) → Credit (90%) → Administrative Approval (95%) → CSC Procurement (98%) → Scanned Documents (99%) → Closed Won (100%)

Closed Lost: Closed Lost, Closed Lost - CSC Decision, Closed Lost Purchased
Terminated: Terminated - Buyout, Terminated - Default, Terminated - Return, Terminated - Extension, Terminated - Restructure, Terminated - Abandoned, Terminated - Ext Own, Terminated - Partial Buyout/Return, Terminated - Softcost Only
Other: Placeholder (EXCLUDE), Transmission Failure (EXCLUDE), Closed Lease Line

### Defining "Active Lease"

"Active lease" is ambiguous. Use the right filter:

| What the user means | Filter | ~Count |
|---------------------|--------|--------|
| **Currently billing / in-term** (most common) | See default query below | ~3,942 |
| **Deal in Progress (pre-commencement)** | `DIP__c = 1` | ~271 |
| **Total exposure (active + DIP)** | Active filter + `DIP__c = 1` | ~4,213 |

**CRITICAL: `Won__c` alone is NOT sufficient for "active leases."** Won__c only captures `Closed + In Term Rent` (2,466 leases). It misses:
- `Commenced + In Term Rent` (498 leases, $212M) — actively billing but Won = 0
- `Closed + Month-to-Month` (947 leases, $135M) — past original term, still billing, Won = 0

### Month-to-Month Transition Logic

When a lease reaches its `Expiration_Date__c` (original term end) and no extension, buyout, or return has been executed, `Sub_Stage__c` automatically flips from `In Term Rent` → `Month-to-Month`. This is a Salesforce automation — not a manual step.

**Key fields:**
- `Expiration_Date__c` — stays frozen at original term end. Never updated. For M2M leases, this is effectively the M2M start date.
- `Adjusted_Expiration_Date__c` — always exactly 3 months (89-92 days) ahead of `Expiration_Date__c`. Rolling billing horizon. NOT the actual end date.
- `Months_Remaining__c` — goes negative for M2M leases (avg -32 = ~2.7 years past original term).

**Data profile (947 M2M leases):**
- 96% have `Expiration_Date__c` in the past (already past original term)
- 4% (38) have expiration dates within days of today (about to roll over)
- All expiration dates fall on month-ends
- The longest M2M lease has been rolling since 2012

**Common CEO questions → how to answer:**
- "Which leases are month-to-month?" → `Sub_Stage__c = 'Month-to-Month'`
- "When did it go month-to-month?" → `Expiration_Date__c` (the original term end)
- "How long has it been month-to-month?" → `DATEDIFF(month, Expiration_Date__c, GETDATE())`
- "Which leases are about to go month-to-month?" → In Term Rent where `Expiration_Date__c` is within next 90 days

```sql
-- Leases approaching M2M transition (next 90 days)
SELECT l.Name, l.Expiration_Date__c, a.Name as customer
FROM sf.Lease l
JOIN sf.Account a ON l.Account__c = a.Id AND a.IsDeleted = 0
WHERE l.IsDeleted = 0
  AND l.Sub_Stage__c = 'In Term Rent'
  AND l.Stage__c IN ('Closed', 'Commenced')
  AND l.Expiration_Date__c BETWEEN GETDATE() AND DATEADD(day, 90, GETDATE())
ORDER BY l.Expiration_Date__c
```

**Default "active leases" query (use this when someone says "active leases"):**
```sql
WHERE (l.Won__c = 1
    OR (l.Stage__c = 'Commenced' AND l.Sub_Stage__c = 'In Term Rent')
    OR (l.Stage__c = 'Closed' AND l.Sub_Stage__c = 'Month-to-Month'))
  AND l.IsDeleted = 0
```

**Key formulas:**
- `Won__c` = `Stage__c = 'Closed' AND Sub_Stage__c = 'In Term Rent'` only — does NOT include Month-to-Month or Commenced
- `DIP__c` = Deal in Progress — funded but pre-commencement (Accumulating leases ARE billing rent despite being DIP)

### Useful Stage Filters
- Active pipeline: `StageName NOT IN ('Closed Won','Closed Lost','Closed Lost - CSC Decision','Closed Lost Purchased','Placeholder','Transmission Failure') AND IsClosed = 0`
- Deals in approval: `StageName IN ('CSC Approval Process','Credit','Administrative Approval')`
- Active leases (billing): Use the default active query above (NOT just `Won__c = 1`)
- Deals in progress: `DIP__c = 1`
- Leases in prep: `Stage__c IN ('Lease Prep','Documentation','PO Processing','QA','Invoice Processing')`
- Accumulating (pre-commencement but billing): `Stage__c = 'Accumulating'`
- Troubled deals: `StageName IN ('Terminated - Restructure','Terminated - Default')`

## LEASE STAGES AND SUB-STAGES

### Stage__c (10 values)
Lease Prep → Documentation → PO Processing → QA → Invoice Processing → Security Deposit → Accumulating → Commenced → Closed
Also: Placeholder (EXCLUDE)

### Sub_Stage__c — Complete Mapping (33 values)

**Accumulating stage** (no sub-stage — NULL):
- Equipment arriving in stages, billing accumulating rent. DIP = 1.

**Commenced stage:**
- `In Term Rent` — actively billing within formal lease term. **This is "active" but Won__c = 0.** (498 leases, $212M)

**Closed stage — Active sub-stages:**
- `In Term Rent` — Won__c = 1. Active and billing. (2,466 leases, $819M)
- `Month-to-Month` — past original term, continues billing month-to-month. Won__c = 0. (947 leases, $135M)

**Closed stage — Terminal sub-stages (lease ended):**
- `Terminated - Buyout` — lessee purchased equipment. Most common exit. (3,872 leases, $525M)
- `Terminated - Return` — equipment returned to CSC. (1,220 leases, $128M)
- `Terminated - Extension` — original replaced by extension lease. (1,039 leases, $233M)
- `Terminated - Partial Buyout/Return` — some equipment bought, some returned. (889 leases, $61M)
- `Terminated - Default` — lessee defaulted. (564 leases, $119M)
- `Terminated - Abandoned` — lease abandoned. (364 leases, $34M)
- `Terminated - Ext Own` — extended then purchased. (251 leases, $4M)
- `Terminated - Softcost Only` — only soft costs remain. (132 leases, $10M)
- `Terminated - Restructure` — replaced by restructured lease. (56 leases, $9M)
- `Closed Terminated` — generic closed/terminated. (1,572 leases, $52M)
- `Closed Lost - CSC Decision` — CSC chose not to proceed. (165 leases, $50M)
- `Closed Lost - Client Decision` — client chose not to proceed. (56 leases, $4M)
- `Closed Lost - Reversed` — reversed/corrected. (1 lease)

**Documentation stage sub-stages:**
- `Docs Sent` — lease docs sent to customer. DIP = 1. (28 leases)
- `Docs Received` — signed docs returned. DIP = 0. (22 leases)
- `Docs Not Generated` — docs not yet created. DIP = 1. (12 leases)
- `Internal Review` — docs under internal review. DIP = 1. (4 leases)
- `Ready to Send` — docs ready for customer. DIP = 1. (3 leases)
- `Docs Generated` — docs created, not yet sent. DIP = 1. (2 leases)

**PO Processing stage sub-stages:**
- `POs Not Generated` — purchase orders not yet created. DIP = 1. (16 leases)
- `POs Generated` — POs created. DIP = 1. (11 leases)
- `POs Sent` — POs sent to vendors. DIP = 1. (8 leases)

**QA stage sub-stages:**
- `Extension` — extension being processed in QA. DIP = 1. (7 leases)
- `With Operations` — in ops review. DIP = 1. (5 leases)

**Invoice Processing stage:**
- `Processing` — invoices being processed. DIP = 1. (16 leases)

**Security Deposit stage:**
- `Security Deposit Sent` — deposit invoice sent. DIP = 1. (8 leases)
- `Security Deposit Generated` — deposit invoice created. DIP = 1. (4 leases)

**Lease Prep stage:** (no sub-stage — NULL). DIP = 1. (5 leases)

## EXTENSIONS AND ADDENDUMS

Leases can have extensions and addendums — these are **separate Lease records** under the same `Master_Lease__c`.

**Addendum** (`-ADD-` in Name, ~802 leases): Additional equipment added to an existing schedule. Same `Schedule__c` letter as the original. Each addendum has its own assets. When counting total equipment or cost for a schedule, SUM across original + all addendums.

**Extension** (`-EXT-` in Name, ~1,059 leases): Lease term extended after original expires. `Schedule__c` gets a `-EXT`/`-Ext` suffix (casing inconsistent — use `UPPER()` or `LIKE '%EXT%'`). The original lease's Sub_Stage__c becomes `Terminated - Extension` or `Terminated - Ext Own`.

**Boolean flags (on the lease record):**
- `Addendum__c = 1` → this lease is an addendum
- `Extension__c = 1` → this lease is an extension
- Both false → original lease

**FK links (on the addendum/extension, pointing back to the original):**
- `Previous_Lease_Addendum__c` = Lease.Id of the original (populated on addendum leases)
- `Previous_Lease_Extension__c` = Lease.Id of the original (populated on extension leases)

**Key rules:**
- To filter: use `Addendum__c` / `Extension__c` booleans (cleanest)
- To trace back to original: join on `Previous_Lease_Extension__c` or `Previous_Lease_Addendum__c`
- Name patterns (`-EXT-`, `-ADD-`) also work but booleans are authoritative
- Both share the same `Master_Lease__c` as the original
- When asked about "total under a lease" or "all equipment for a customer", always include addendums and extensions — GROUP BY Master_Lease__c, not individual Lease Id
- When asked about currently active leases, extensions may be the active record while the original is `Closed`/`Terminated`
- Double-count risk: don't sum original + extension financials for "current" questions — the extension replaces the original

```sql
-- Trace an extension/addendum back to its original
SELECT ext.Name AS ext_name, orig.Name AS orig_name, orig.Stage__c
FROM sf.Lease ext
JOIN sf.Lease orig ON ext.Previous_Lease_Extension__c = orig.Id
WHERE ext.IsDeleted = 0 AND orig.IsDeleted = 0

-- All leases (original + addendums + extensions) under a master lease
SELECT l.Name, l.Schedule__c, l.Stage__c, l.Sub_Stage__c,
       CASE WHEN l.Extension__c = 1 THEN 'Extension'
            WHEN l.Addendum__c = 1 THEN 'Addendum'
            ELSE 'Original' END AS lease_type,
       COUNT(a.Id) AS assets, SUM(a.Acquisition_Cost__c) AS acq_cost
FROM sf.Lease l
LEFT JOIN sf.Asset a ON l.Id = a.Lease__c AND a.IsDeleted = 0
WHERE l.IsDeleted = 0 AND l.Master_Lease__c = '<master_lease_number>'
GROUP BY l.Name, l.Schedule__c, l.Stage__c, l.Sub_Stage__c,
         l.Previous_Lease_Extension__c, l.Previous_Lease_Addendum__c
ORDER BY l.Schedule__c, l.Name
```

## ACCUMULATING LEASE LIFECYCLE

Accumulating leases (`Record_Type_Rollup__c = 'Accumulating'`) are CSC's mechanism for funding equipment that arrives in stages. Key difference from regular leases: **CSC bills rent on each piece of equipment as it's accepted, before the formal lease term starts.**

### Two-Phase Billing

**Phase 1 — Accumulating** (`Stage__c = 'Accumulating'`):
- Equipment is accepted piece by piece over weeks/months. Each asset starts generating rent immediately upon acceptance.
- Billing type in vw_Lease_Matching_Master: `inv_doc_type_updated = 'Lease Billing - Accumulating'`
- The monthly billed amount **steps up** as more equipment is added (e.g., $2K → $6K → $14K as assets land).
- The accumulating rate per asset uses the **same factor rate calculation** as post-commencement (cost × factor rate). The total monthly amount grows because more assets are being added, not because the rate changes.
- `Accumulating_Billing_Cycle_Start__c` = date accumulating billing began.
- `Days_of_Accumulating__c` = total days spent in accumulating phase.
- `Total_Accumulating_Revenue__c` = total rent collected during accumulating phase. Persists after commencement as a historical record.

**Phase 2 — Commenced** (`Stage__c = 'Commenced'`, `Sub_Stage__c = 'In Term Rent'`):
- **Commencement is manually triggered in Salesforce by the ops team**, which passes the change to the billing system.
- Billing type flips to `inv_doc_type_updated = 'Lease Billing'`
- Monthly rate = full consolidated amount (`Total_Period_Lease_Rate__c`) — same rate calculation, now applied to all equipment.
- Formal lease term clock starts at `Commencement_Date__c`.

### Currently Active Accumulating Leases
- 177 leases in `Stage__c = 'Accumulating'` with ~$108M total cost pre-commencement.
- These are NOT Won (`Won__c = 0`) but ARE DIP (`DIP__c = 1`) and ARE billing rent.
- When the CEO asks "what are we billing?" or "total revenue this month," accumulating rent should be included.

### Key Fields
| Field | Description |
|-------|-------------|
| `Accumulating_Lease__c` | Boolean — true if this is an accumulating-type lease |
| `Date_Moved_to_Accumulating__c` | When lease entered accumulating stage |
| `Accumulating_Billing_Cycle_Start__c` | When accumulating billing began |
| `Days_of_Accumulating__c` | Total days in accumulating phase |
| `Total_Accumulating_Revenue__c` | Total rent collected during accumulating (persists post-commencement) |
| `Accumulating_Revenue_New__c` | Accumulating revenue (resets to 0 on some commenced leases) |
| `Fees_from_Accumulating__c` | Any fees charged during accumulating period |

### Query Patterns
```sql
-- Currently accumulating leases with their billing history
SELECT l.Name, l.Total_Cost__c, l.Total_Period_Lease_Rate__c,
       l.Total_Accumulating_Revenue__c, l.Days_of_Accumulating__c,
       l.Accumulating_Billing_Cycle_Start__c, l.Commencement_Date__c
FROM sf.Lease l
WHERE l.IsDeleted = 0 AND l.Stage__c = 'Accumulating'
  AND l.Record_Type_Rollup__c = 'Accumulating'
ORDER BY l.Total_Accumulating_Revenue__c DESC

-- Monthly accumulating billing for a specific lease (shows rate step-ups as equipment lands)
SELECT lmm.Invoice_Month, lmm.sales_amount, lmm.inv_doc_type_updated,
       RTRIM(lmm.document_number) AS doc_num
FROM dbo.vw_Lease_Matching_Master lmm
WHERE lmm.Name = '<lease_name>'
  AND lmm.inv_doc_type_updated = 'Lease Billing - Accumulating'
ORDER BY lmm.Invoice_Month

-- Total accumulating revenue across all currently accumulating leases
SELECT SUM(l.Total_Accumulating_Revenue__c) AS total_acc_rev,
       SUM(l.Total_Cost__c) AS total_cost_pre_commence,
       COUNT(*) AS lease_count
FROM sf.Lease l
WHERE l.IsDeleted = 0 AND l.Stage__c = 'Accumulating'
```

### Important: Don't Double-Count Revenue
When calculating total revenue for a lease that has commenced after an accumulating phase:
- `Total_Accumulating_Revenue__c` = pre-commencement rent (accumulating phase)
- Post-commencement rent = billing rows where `inv_doc_type_updated = 'Lease Billing'` AND `Invoice_Month >= Commencement_Date__c`
- These are additive — accumulating revenue is earned BEFORE the formal term, regular billing is DURING the term.

## EQUIPMENT SEARCH STRATEGY

When users ask about equipment (e.g., "industrial dehydrators", "solar panels", "forklifts"):

**Step 1 — Fuzzy search descriptions first:**
```sql
WHERE (a.Asset_Description_Model__c LIKE '%keyword%'
    OR a.Ext_Descript__c LIKE '%keyword%'
    OR a.Ext_Descript_2__c LIKE '%keyword%'
    OR a.Manufacturer_Name__c LIKE '%keyword%')
```

**Step 2 — Fall back to Equip_Type__c category** (53 values):
IT: Desktop, Laptop, Tablet, Monitor, IT Equipment, Server, Copier/Printer, Phone Equipment
Industrial: CNC Machine, Crane/Hoist, Forklift, Industrial Equipment, Material Handling, Robotics, Welding Equipment
Medical: Dental Equipment, Medical Equipment, MRI/Imaging, Surgical Equipment
Energy: Battery/Energy Storage, EV Charging, Generator, LED Lighting, Solar
Food: Brewery/Distillery, Food & Beverage Processing, Kitchen Equipment, Packaging/Filling, Refrigeration/Cold Storage
Transport: Aircraft, Marine/Watercraft, Trailer, Vehicles
Construction: Construction Equipment, Excavation, HVAC & Chillers
Office: Furniture, Office Equipment
Other: AV/Broadcast, Car Wash, Cannabis/Grow, Fitness Equipment, Laundry, Modular Building, Printing/Graphics, Signage, Telecom/Fiber, Textile/Garment, Turf/Groundskeeping, Vending, Waste/Recycling, Water Treatment

## FINANCIAL METRICS (on sf.Asset)

| Metric | Field | Unit | Formula / Meaning |
|--------|-------|------|-------------------|
| Acquisition Cost | Acquisition_Cost__c | USD | Original cost to CSC |
| Monthly Rent | Monthly_Lease_Rate__c | USD | `Acquisition_Cost__c * Factor_Rate__c + Asset_Lease_Rate_Adjustment__c` |
| Factor Rate | Factor_Rate__c | % | Monthly rate factor applied to acquisition cost to calculate rent |
| Months on Lease | Months_On_Lease__c | # | `(Analysis_End_Date - Lease.Acceptance_Date) / 365 * 12` |
| Total Revenue | Total_Asset_Revenue__c | USD | `(Months_On_Lease * Monthly_Lease_Rate) + Inventory_Sale_Amount + Buyout_Amount + Repair_Cost` — includes rental income + all end-of-lease proceeds |
| Annual ROA | Annual_ROA__c | % | `((Total_Asset_Revenue - Acquisition_Cost) / Acquisition_Cost) / Months_On_Lease * 12` — annualized return. 15-25% healthy, <10% underperforming |
| NPV | NPV__c | USD | PV of monthly rent at 0.3333% monthly discount rate (~4% annual). Positive = profitable |
| NPV/TC | NPV_TC__c | ratio | `NPV / Acquisition_Cost` — NPV as % of cost |
| Book Exposure | Book_Exposure__c | USD | `Acquisition_Cost - (0.0208 * Months_On_Lease * Acquisition_Cost)`, floored at 0. ~25% annual straight-line depreciation |
| Gain/Loss | Net_Book_Gain_Loss__c | USD | `(Inventory_Sale_Amount + Buyout_Amount) - Book_Exposure` |
| Residual Income | Residual_Income__c | USD | `Inventory_Sale_Amount + Buyout_Amount + Repair_Cost` — total end-of-lease proceeds |
| Sale Residual | Sale_Residual__c | % | `Residual_Income / Acquisition_Cost` — recovery as % of original cost |
| Asset Rental Income | Asset_Rental_Income__c | USD | `Monthly_Lease_Rate * Months_On_Lease` — pure rental revenue (excludes buyout/sale) |
| Asset Rental Gain/Loss | Asset_Rental_Gain_Loss__c | USD | `Asset_Rental_Income - Acquisition_Cost` — rental-only profitability |
| FMV | Fair_Market_Value__c | USD | Current estimated market value |
| Buyout Amount | Buyout_Amount__c | USD | Purchase option price at lease end |

### Important formula notes
- `Total_Asset_Revenue__c` includes EVERYTHING (rent + buyout + sale + repairs). Use `Asset_Rental_Income__c` for rent-only revenue.
- `Annual_ROA__c` is based on Total_Asset_Revenue, so it includes end-of-lease proceeds — it's total return, not just rental yield.
- `Book_Exposure__c` uses a flat 2.08%/month depreciation (~25%/year). It floors at 0 so fully depreciated assets show $0.
- `Monthly_Lease_Rate__c` on Asset is the asset-level rate (cost × factor). The lease-level `Total_Period_Lease_Rate__c` is the sum across all assets + UCC fees.

## KEY LEASE-LEVEL FINANCIAL FIELDS

| Field | Formula / Meaning |
|-------|-------------------|
| `Total_Cost__c` | Sum of all cost components: hardware (H+H2+H3+H4) + software + furniture + copier + misc + fees. For extensions, uses `Extension_Cost__c` instead of hardware. |
| `Total_Hardware_Cost__c` | `Hardware_Cost__c + Hardware_Cost_2__c + Hardware_Cost_3__c + Hardware_Cost_4__c` |
| `Total_Period_Lease_Rate__c` | Total rent per period (sum of asset-level rates + UCC fee). The "headline" rent number for a lease. |
| `Total_Active_Lease_Rate_UCC__c` | Active lease rate + UCC + transaction + addendum fees. Used for current billing. |
| `Unbilled_Remaining_Rent__c` | `Months_Remaining * Total_Active_Lease_Rate_UCC` — future rent stream. Key exposure metric. |
| `Net_Equity_Margin__c` | `Present_Value - Total_Cost + Partial + Misc_Revenue + Accumulating_Revenue + Addendum_Fee + Equity_Adjustment` — CSC's equity position. |
| `Profitability_Index__c` | `Projected_NPV / Total_Cost` — NPV per dollar invested. |
| `Present_Value__c` | PV of lease payments using `Annual_Rate__c` as discount rate. |
| `DIP__c` | Boolean: true if lease is in progress (Lease Prep, QA, Security Deposit, Accumulating, or pre-commencement stages). "Deal in Progress." |
| `Won__c` | Boolean: `Stage = 'Closed' AND Sub_Stage = 'In Term Rent'` only. Does NOT include Month-to-Month or Commenced. Use the full active lease filter instead. |
| `Months_Remaining__c` | Months left in lease term from today. |
| `Commencement_Date__c` | Calculated from Acceptance_Date: if accepted on the 1st, same date; otherwise rolls to 1st of next month. |
| `Expiration_Date__c` | `Commencement_Date + Lease_Term months`. |

## PAYMENT SCHEDULE TABLES (sf.Payment_Schedule + sf.Payment_Schedule_Line_Item)

**IMPORTANT: Only populated for currently active leases. Historical/closed leases do NOT have payment schedule data.**

The scheduled rent stream for a lease. Payment_Schedule is the header (one per lease); Payment_Schedule_Line_Item has one row per month with the scheduled rent amount.

### sf.Payment_Schedule (~4K rows)
- `Id` — primary key
- `Name` — e.g., "PS-3138"
- `Lease__c` — FK to sf.Lease.Id
- `Step_Lease_Rate__c` — boolean, true if rent changes across the term

### sf.Payment_Schedule_Line_Item (~131K rows)
- `Id` — primary key
- `Payment_Schedule__c` — FK to sf.Payment_Schedule.Id
- `Lease__c` — FK to sf.Lease.Id (direct shortcut)
- `Amount__c` — scheduled rent for this month
- `Month__c` — sequence number within term (1, 2, 3...)
- `Billing_Date__c` — when this payment is billed
- `Rental_Month__c` — the rental period (first of month)
- `Effective_Factor__c` — monthly rate factor (Amount / Acquisition Cost)

### Query Patterns
```sql
-- Full rent stream for a lease
SELECT psl.Month__c, psl.Amount__c, psl.Billing_Date__c, psl.Rental_Month__c
FROM sf.Payment_Schedule_Line_Item psl
WHERE psl.IsDeleted = 0 AND psl.Lease__c = '<lease_id>'
ORDER BY psl.Billing_Date__c

-- Total scheduled rent by lease (active leases only)
SELECT psl.Lease__c, l.Name,
       COUNT(*) AS term_months, SUM(psl.Amount__c) AS total_scheduled_rent
FROM sf.Payment_Schedule_Line_Item psl
JOIN sf.Lease l ON psl.Lease__c = l.Id
WHERE psl.IsDeleted = 0 AND l.IsDeleted = 0
GROUP BY psl.Lease__c, l.Name

-- Detect step leases (where Amount__c varies across months)
SELECT ps.Lease__c, l.Name, ps.Step_Lease_Rate__c,
       MIN(psl.Amount__c) AS min_rent, MAX(psl.Amount__c) AS max_rent
FROM sf.Payment_Schedule ps
JOIN sf.Payment_Schedule_Line_Item psl ON ps.Id = psl.Payment_Schedule__c
JOIN sf.Lease l ON ps.Lease__c = l.Id
WHERE ps.IsDeleted = 0 AND psl.IsDeleted = 0 AND l.IsDeleted = 0
  AND ps.Step_Lease_Rate__c = 1
GROUP BY ps.Lease__c, l.Name, ps.Step_Lease_Rate__c
```

## BILLING VIEW: dbo.vw_Lease_Matching_Master

Cross-system view (~514K rows) joining SF lease data with Great Plains billing/payment transactions.
**Grain:** One row per **payment application** per invoice document per lease schedule. A single invoice (`document_number`) may appear on multiple rows if multiple payments/credits were applied against it. `sales_amount` repeats (it's the invoice total on every row) while `total_amount_applied` differs per row (each individual payment/credit).
**Schema:** `dbo` (NOT `sf`)

**CRITICAL for aggregation:**
- `SUM(total_amount_applied)` = correct for total collections (each row is a distinct payment application)
- `SUM(sales_amount)` **OVERCOUNTS** — use `SUM(DISTINCT sales_amount)` or deduplicate by `document_number` first for billed revenue
- Safest billed revenue pattern: `SELECT SUM(sales_amount) FROM (SELECT DISTINCT document_number, sales_amount FROM dbo.vw_Lease_Matching_Master WHERE ...) x`

### Key Columns
- `id` = Salesforce Lease ID (JOIN to sf.Lease.Id)
- `account__c` = Salesforce Account ID
- `Name` = Lease name
- `Master_Lease__c` = Master lease number
- `Schedule__c` = Schedule letter (A, B, C...)
- `Ecosystem__c` = Industry ecosystem (denormalized)
- `Invoice_Month` = Billing month (date, first of month)
- `document_number` = GP invoice number
- `document_date`, `posted_date`, `paid_date` = date strings
- `inv_doc_type_updated` = billing category (USE THIS TO FILTER)
- `sales_amount` = invoice amount (pre-tax)
- `payment` = cash payment applied (does NOT include credits/offsets)
- `total_amount_applied` = **USE THIS for collections** — includes cash payments, credits, and offsets
- `balance` = outstanding balance (0 = paid)
- `Unbilled_Remaining_Rent__c` = remaining unbilled rent
- `Loan_Package`, `Loan_Number`, `Bank_Name` = funding info

### inv_doc_type_updated Values
Lease Billing, Lease Billing - Accumulating, Lease Billing - Partial Rent, Lease Billing - Remaining Rent, Security Deposit, Buyout, Property Tax, Repairs, Transportation/Insurance, Misc

### Billing Query Patterns
```sql
-- Outstanding balances
SELECT customer_name, Master_Lease__c, document_number, sales_amount, balance
FROM dbo.vw_Lease_Matching_Master WHERE balance > 0 ORDER BY balance DESC

-- Monthly billing summary
SELECT Invoice_Month, SUM(sales_amount) AS billed, SUM(total_amount_applied) AS collected
FROM dbo.vw_Lease_Matching_Master WHERE inv_doc_type_updated = 'Lease Billing'
GROUP BY Invoice_Month ORDER BY Invoice_Month DESC

-- Join billing to SF for full context
SELECT lmm.*, a.Name AS AccountName, l.Name AS LeaseName
FROM dbo.vw_Lease_Matching_Master lmm
JOIN sf.Lease l ON lmm.id = l.Id AND l.IsDeleted = 0
JOIN sf.Account a ON l.Account__c = a.Id AND a.IsDeleted = 0
```

### Raw GP Source: dbo.trial_balance_prod_desc_no_cut

**Use when `vw_Lease_Matching_Master` is missing data.** The view only covers leases commenced after 1/1/2015 and joins at the schedule level — transactions without a specific schedule (buyouts billed to "all schedules", finance charges, debit memos, property tax, etc.) are dropped. The raw trial_balance table has ~680K rows vs ~514K in the view.

**Key columns:** CustomerID (char 15), CustomerName (char 65), [Master Lease] (varchar 21), Schedule (varchar 21), DocumentNumber (char 21), DocType, [Inv Doc Type (Updated)] (varchar 30 — same categories as inv_doc_type_updated in the view), DocumentDate, SalesAmount, Balance, TrxDescription, Comment, Amount_Applied, Payment, [Total Pmts/Credits Applied], [Doc Amt-Total]

**All GP text fields have trailing spaces — always use RTRIM().**

**Join to Salesforce — use `CustomerID` as the primary key (more consistent than `[Master Lease]`):**
- `CustomerID` = GP customer number = `sf.Lease.Master_Lease__c` (account-level, matches 83% of rows)
- `[Master Lease]` can differ from CustomerID when multiple master lease agreements exist under one customer (matches only 77% of rows)
- `Schedule` = schedule letter = `sf.Lease.Schedule__c` (for lease-level matching)

```sql
-- Account-level: trial_balance → sf.Lease → sf.Account (PREFERRED join via CustomerID)
SELECT DISTINCT RTRIM(tb.CustomerID) as GP_CustomerID, RTRIM(tb.CustomerName) as GP_Name,
       a.Name as SF_AccountName, a.Id as SF_AccountId
FROM dbo.trial_balance_prod_desc_no_cut tb
JOIN sf.Lease l ON RTRIM(tb.CustomerID) = l.Master_Lease__c AND l.IsDeleted = 0
JOIN sf.Account a ON l.Account__c = a.Id AND a.IsDeleted = 0
WHERE tb.CustomerName LIKE '%search_term%'

-- Schedule-level: match specific lease (use CustomerID + Schedule)
SELECT tb.*, l.Name as SF_LeaseName, l.Id as SF_LeaseId
FROM dbo.trial_balance_prod_desc_no_cut tb
JOIN sf.Lease l ON RTRIM(tb.CustomerID) = l.Master_Lease__c
                AND RTRIM(tb.Schedule) = l.Schedule__c
                AND l.IsDeleted = 0
WHERE RTRIM(tb.CustomerID) = '15085'
```

**When to use trial_balance instead of the view:**
- Buyouts not tied to a specific schedule (Schedule = NULL, empty, or "all schedules")
- Finance charges, debit memos, promissory note interest (100% have no schedule)
- Security deposits (82% have no schedule)
- Property tax (92% have no schedule)
- Any billing data for leases commenced before 1/1/2015
- When the view returns no results but you know billing exists for that customer

**Inv Doc Type values (16 total):** Lease Billing (546K rows, $2.3B), Security Deposit (50K, $167M), Misc (26K, $294M), Property Tax (14K, $37M), Fin Chg (13K, $9M), Buyout (9K, $262M), Lease Billing - Accumulating (8K, $90M), Transportation/Insurance (7K, $14M), Repairs (3K, $5M), Debit Memo (3K, $45M), Lease Billing - Partial Rent (1K, $11M), Unapplied Return, Tolls, Unapplied Payment, Prom Note Int, Lease Billing - Remaining Rent

### AR Aging (Delinquency / Past Due)

There are NO pre-built aging buckets in the billing view. Aging must be computed from `document_date` vs. current date on invoices with `balance > 0`. Only `doc_type = 'Invoice'` carries open balances.

**How to compute aging:**
```sql
-- AR aging by bucket (deduplicated by document_number)
WITH invoices AS (
    SELECT document_number,
        RTRIM(customer_id) as customer_id,
        RTRIM(customer_name) as customer_name,
        MAX(TRY_CAST(document_date AS date)) as doc_date,
        MAX(balance) as open_balance,
        MAX(id) as lease_id,
        MAX(account__c) as account_id
    FROM dbo.vw_Lease_Matching_Master
    WHERE balance > 0 AND doc_type = 'Invoice'
    GROUP BY document_number, RTRIM(customer_id), RTRIM(customer_name)
)
SELECT
    CASE
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 30 THEN 'Current (0-30)'
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 60 THEN '31-60'
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 90 THEN '61-90'
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 120 THEN '91-120'
        ELSE '120+'
    END as aging_bucket,
    COUNT(*) as invoices,
    SUM(open_balance) as total_balance,
    COUNT(DISTINCT customer_id) as customers
FROM invoices
GROUP BY
    CASE
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 30 THEN 'Current (0-30)'
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 60 THEN '31-60'
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 90 THEN '61-90'
        WHEN DATEDIFF(day, doc_date, GETDATE()) <= 120 THEN '91-120'
        ELSE '120+'
    END
ORDER BY aging_bucket
```

**Key facts:**
- Total open AR: ~$71.3M across ~7,044 invoices
- Current (0-30 days): ~$30.5M (2,649 invoices, 314 customers) — largest bucket, normal billing cycle
- 120+ days: ~$27.8M (3,314 invoices, only 44 customers) — concentrated risk
- `inv_doc_type_updated` breaks down open AR by billing type: Lease Billing (6,524), Accumulating (194), Repairs (97), Security Deposit (59), Buyout (53), etc.

**"Who's past due?" — use this pattern:**
```sql
-- Top past-due customers (120+ days)
WITH invoices AS (
    SELECT document_number, RTRIM(customer_name) as customer_name,
        MAX(TRY_CAST(document_date AS date)) as doc_date,
        MAX(balance) as open_balance, MAX(account__c) as account_id
    FROM dbo.vw_Lease_Matching_Master
    WHERE balance > 0 AND doc_type = 'Invoice'
    GROUP BY document_number, RTRIM(customer_name)
    HAVING DATEDIFF(day, MAX(TRY_CAST(document_date AS date)), GETDATE()) > 120
)
SELECT customer_name, COUNT(*) as invoices,
    SUM(open_balance) as total_past_due,
    MIN(doc_date) as oldest_invoice,
    DATEDIFF(day, MIN(doc_date), GETDATE()) as max_days_past
FROM invoices
GROUP BY customer_name
ORDER BY SUM(open_balance) DESC
```

**Account-level AR flags (Salesforce):**
- `A_R_Watchlist__c` — boolean, manually flagged for AR concerns (14 accounts, $18.7M exposure)
- `A_R_Watchlist_Notes__c` — text notes on AR status
- `Current_Default__c` — boolean, currently in default (28 accounts, mostly terminated/low exposure)
- These flags are independent of billing data — they're manually set in Salesforce. Cross-reference with billing aging for a complete picture.

## FUNDING & SYNDICATION

CSC has two funding models:

### Bank Participation (Warehousing)
Most leases are funded by bank partners via credit facilities. The billing view's `Bank_Name` column shows the funder. 54 bank partners total. Top banks by lease count: United Bank (1,781), PNC (990), Atlantic Union (824), Blue Ridge (559), M&T (539), Capital One (470). `CSC Financed` (731 leases) = CSC retained the risk on its own balance sheet. `CCA Financed`/`CCA Financial` = funded through a CSC affiliate.

### Syndication (Co-Investment)
For large deals that exceed CSC's risk appetite, portions are syndicated to co-investors. Only 11 syndication facilities exist (out of 4,379 total Credit_Facility records), linking to 89 leases. $113M total required syndication, ~$55M completed/funded.

**Named syndication partners** (Account.Syndication_Partner__c = 1): SQN Venture Partners, Upper90, CapX Partners, Bow River, Rosenthal, Gibraltar Equipment Finance, NFS Leasing, Copia Group, Verdant Commercial Capital, TCRED SPV 1.

**Key entity: Credit_Facility (sf.Credit_Facility)**
- Links to Account: `Credit_Facility.Account__c = Account.Id`
- Links to Lease: `Lease.Credit_Facility__c = Credit_Facility.Id`
- `Syndication__c` — boolean, true = syndication deal (only 11)
- `Required_Syndication_Amount__c` — total $ to be syndicated
- `Syndication_Funded__c` — $ actually funded by syndication partner
- `Remaining_To_Be_Syndicated__c` — $ still to be placed
- `Status__c` — facility status (Pending, Expired, etc.)
- `Line_Amount__c` — total credit facility size
- `Total_Facility__c` — total facility amount

**Syndication pipeline stages** (all $ amounts on Credit_Facility):
`Syndication_Preliminary__c` → `Syndication_Soft_Commitment__c` → `Syndication_Signed_Term_Sheet__c` → `Syndication_Documentation__c` → `Syndication_Open_In_Progress__c` → `Syndication_Completed__c` → `Syndication_Funded__c`

**Lease-level fields:**
- `Syndication_Deal__c` — FK to a specific syndication sub-deal (89 leases have this)
- `Syndicated_Vendor__c` — unused (0 populated)
- `Syndication_GL__c` — unused (0 populated)
- `Include_Syndicated_NOA__c` — boolean, include in syndicated Notice of Assignment

**Billing view funding fields:**
- `Bank_Name` — funding bank/source (54 distinct values)
- `Loan_Package` — loan package identifier
- `Loan_Number` — individual loan number

**"Who funds this lease?" patterns:**
```sql
-- Funding source for a specific lease
SELECT DISTINCT RTRIM(b.Bank_Name) as funder, b.Loan_Package
FROM dbo.vw_Lease_Matching_Master b
WHERE b.id = @lease_id AND b.Bank_Name IS NOT NULL

-- Exposure by funding bank
SELECT RTRIM(b.Bank_Name) as bank,
    COUNT(DISTINCT b.id) as leases,
    COUNT(DISTINCT b.document_number) as invoices
FROM dbo.vw_Lease_Matching_Master b
WHERE b.Bank_Name IS NOT NULL AND RTRIM(b.Bank_Name) != ''
GROUP BY RTRIM(b.Bank_Name)
ORDER BY leases DESC

-- Active syndication deals
SELECT cf.Name, a.Name as account_name, cf.Line_Amount__c,
    cf.Required_Syndication_Amount__c, cf.Syndication_Funded__c,
    cf.Remaining_To_Be_Syndicated__c, cf.Status__c
FROM sf.Credit_Facility cf
JOIN sf.Account a ON cf.Account__c = a.Id AND a.IsDeleted = 0
WHERE cf.IsDeleted = 0 AND cf.Syndication__c = 1
ORDER BY cf.Required_Syndication_Amount__c DESC
```

## INDUSTRY CLASSIFICATION

**Account.Ecosystem__c** (22 values — use for high-level sector): TMT, BioTech, Medical, Food & Beverage, Advanced Manufacturing, CleanTech, AI, AgTech, PetCare, Robotics & Automation, MedTech, Foodtech, Mobility, Defense, Commercial & Professional Services, Logistics, Power & Infrastructure, Retail, Space, Pharma, Other

NOTE: "Technology" is NOT a valid ecosystem — use **TMT** (Technology, Media, Telecom). "Healthcare" splits into **Medical**, **MedTech**, and **BioTech**. "Manufacturing" = **Advanced Manufacturing**.

**Account.Industry** (93+ values — detailed classification within each Ecosystem)

**Opportunity.Industry__c** (75 values — may differ from Account.Industry)

Prefer Ecosystem__c for high-level sector queries. Use Industry for detailed breakdowns.

## ASSET STATUS VALUES (Status__c — 36 values, inconsistent)

**"Installed" = currently active on a lease.** This is the key status for active equipment — NOT "Active".
- `Total_Active_Lease_Rate__c` on Lease = sum of rates from assets with Status = "Installed"
- `Total_Active_Cost__c` on Lease = sum of costs from assets with Status = "Installed" + active deposits

Other statuses: Returned, Missing, Missing - Billable, Missing-Billable, mising-billable (TYPOS EXIST — use UPPER() for comparison), Off-Lease, Sold, Refurbished, Scrapped, In-Transit, Awaiting Delivery, On-Hand, Equipment Cost, Pending Return, Default Recovery, Under Repair, Buyout Completed, Abandoned Asset, 1st DELETED, etc.

## WORKOUTS (TROUBLED / DEFAULTED ACCOUNTS)

Workouts track accounts in financial distress — defaults, liquidations, forbearance agreements, etc. **Workouts are at the ACCOUNT level**, not per-lease. One active workout covers all leases under that account.

### Key: Workout links to Account, not Lease
- `sf.Workout.Account__c = sf.Account.Id`
- To find troubled leases, join Workout → Account → Opportunity → Lease
- Or cross-reference with lease-level Sub_Stage__c values like `Terminated - Default`

### Workout_Type__c (severity/approach — from most severe to least)
| Type | Meaning | Active Count |
|------|---------|-------------|
| **Liquidation** | Company failed, recovering assets and cash. Most severe. | 23 |
| **Non-Accrual** | CSC stopped recognizing revenue — payment highly unlikely. | 14 |
| **Forbearance Agreement** | Formal agreement to defer/restructure payments. Customer still operating but distressed. | 12 |
| **Distressed Restructure** | Renegotiating lease terms under financial stress. | 5 |
| **Settlement Agreement** | Negotiated resolution (often partial recovery). | 2 |
| **Asset Transfer** | Equipment moved to new lessee or returned. | 0 active |
| **Promissory Note** | Debt converted to a note. | 0 active |
| **At Risk** | Early warning — not yet in default but concerning. | 0 active |
| **Slow Payment** | Chronic late payer. Least severe. | 0 active |

### Workout_Sub_Type__c (bankruptcy type, when applicable)
ABC, Chapter 11, Chapter 11 - 363, Chapter 7, Dissolution

### Workout_Status__c (lifecycle)
| Status | Meaning | Count |
|--------|---------|-------|
| **Active** | Currently being worked. **Use this to find current trouble.** | 56 |
| **Cured** | Customer recovered, leases back to normal. | 36 |
| **Complete** | Workout resolved (assets recovered, settlement reached, etc.) | 163 |
| **Cancelled** | Workout opened in error or situation resolved before action. | 20 |

### Default_Status__c (escalation level)
No Action Taken → In Default → Notice of Default Sent

### Legal_Status__c (litigation tracking)
No Planned Litigation → Preparing Litigation → Active Litigation → Closed Litigation

### Conviction_to_Cure__c (internal assessment)
High / Medium / Low — CSC's subjective assessment of whether the account will recover.

### Stage__c (approval workflow)
Information Gathering → Pending Investment Committee → Pending Workout Committee → Approved

### Key Financial Fields on Workout
| Field | Description |
|-------|-------------|
| `Total_Cost_Account__c` | Total lease cost across all leases for this account |
| `Potential_Loss__c` | Estimated total loss exposure |
| `Uncollected_Rent__c` | Rent billed but not collected |
| `AR_Unpaid_Balances__c` | Outstanding AR balance |
| `Equipment_Book_Value__c` | Current book value of equipment on troubled leases |
| `Projected_FLV__c` | Projected forced liquidation value of equipment |
| `Projected_Remaining_Recovery__c` | Expected additional recovery |
| `Bad_Debt_Months__c` | Months of bad debt accumulated |
| `Rent_Collected_at_Workout__c` | Rent collected since workout began |
| `Total_Workout_Collections__c` | All collections during workout |
| `Active_Bank_Debt__c` | Outstanding bank/funding debt |
| `Net_Cash_Gain_Loss__c` | Net cash position on the workout |
| `Current_Net_Gain_Loss__c` | Current gain/loss position |
| `Legal_Expense__c` | Legal costs incurred |
| `Legal_Income__c` | Legal recoveries |
| `Recovery_Expenses__c` | Equipment recovery/transportation costs |

### Other Workout Fields
| Field | Description |
|-------|-------------|
| `Begin_Date__c` | When workout started |
| `End_Date__c` | When workout resolved |
| `Comments__c` | Free-text notes (long text) |
| `Next_Steps__c` | Current action items |
| `Billing_Status__c` | Active, On-Hold |
| `Billing_Type__c` | Advance, Rental Month |
| `Deposit_Status__c` | Escrow, Income |
| `Clawback_Approved__c` | Boolean — broker commission clawback approved |
| `Relief_Letter_Sent__c` | Boolean — formal relief communication sent |
| `Include_in_Workout_Reporting__c` | Boolean — include in management reports |
| `Managing_Legal_Counsel__c` | Internal attorney assigned |
| `External_Legal_Representative__c` | FK to external counsel |

### Query Patterns
```sql
-- Active workouts with financial exposure (CEO dashboard)
SELECT w.Name, w.Workout_Type__c, w.Workout_Status__c, w.Default_Status__c,
       w.Legal_Status__c, w.Conviction_to_Cure__c,
       a.Name AS account_name, a.Ecosystem__c,
       w.Total_Cost_Account__c, w.Potential_Loss__c,
       w.Uncollected_Rent__c, w.AR_Unpaid_Balances__c,
       w.Projected_FLV__c, w.Equipment_Book_Value__c,
       w.Begin_Date__c, w.Next_Steps__c
FROM sf.Workout w
JOIN sf.Account a ON w.Account__c = a.Id AND a.IsDeleted = 0
WHERE w.IsDeleted = 0 AND w.Workout_Status__c = 'Active'
ORDER BY w.Potential_Loss__c DESC

-- Summary of active workout exposure by type
SELECT w.Workout_Type__c, COUNT(*) AS accounts,
       SUM(w.Total_Cost_Account__c) AS total_cost,
       SUM(w.Potential_Loss__c) AS potential_loss,
       SUM(w.Uncollected_Rent__c) AS uncollected_rent
FROM sf.Workout w
WHERE w.IsDeleted = 0 AND w.Workout_Status__c = 'Active'
GROUP BY w.Workout_Type__c
ORDER BY potential_loss DESC

-- Leases under a troubled account
SELECT w.Name AS workout, a.Name AS account,
       l.Name AS lease, l.Stage__c, l.Sub_Stage__c, l.Total_Cost__c
FROM sf.Workout w
JOIN sf.Account a ON w.Account__c = a.Id AND a.IsDeleted = 0
JOIN sf.Lease l ON l.Account__c = a.Id AND l.IsDeleted = 0
WHERE w.IsDeleted = 0 AND w.Workout_Status__c = 'Active'
ORDER BY w.Potential_Loss__c DESC, l.Total_Cost__c DESC

-- Accounts in active litigation
SELECT w.Name, a.Name AS account, w.Legal_Status__c,
       w.Total_Cost_Account__c, w.Legal_Expense__c
FROM sf.Workout w
JOIN sf.Account a ON w.Account__c = a.Id AND a.IsDeleted = 0
WHERE w.IsDeleted = 0 AND w.Legal_Status__c IN ('Active Litigation', 'Preparing Litigation')
```

## SCHEMA ARCHITECTURE (BEYOND sf)

Four additional schemas beyond `sf`:

| Schema | Tables | What's in it |
|--------|--------|-------------|
| `gp` | 472 | **Native GP Dynamics tables** — uses GP numeric IDs (e.g., `gp.RM00101`, `gp.GL30000`, `gp.SOP10102`). This is the source of truth for GP data. |
| `Sage_CSCLeasing` | 64 | **Sage Fixed Assets — CSC Leasing company.** Native Sage tables: Asset (149K), BookParts (1M), EventLog (11M). |
| `Sage_Leasewave_Assts` | 67 | **Sage Fixed Assets — Leasewave Assets company.** Same structure, much larger: Asset (701K), BookParts (5M), EventLog (47M). |
| `dbo` | ~800 | **CSC-built views, snapshots, staging.** Trial balance, Lease Matching pipeline, PBI views, snapshot copies of gp/Sage data. |

**Key rule:** GP source data lives in `gp.*`. Sage source data lives in `Sage_CSCLeasing.*` or `Sage_Leasewave_Assts.*`. The `dbo` schema has derived/processed versions.

### Key gp Schema Tables

`gp.GL_Posted_Tranactions` (3.9M) — All posted GL journal entries. Note typo in name ("Tranactions").
`gp.view_RM_Transactions` (844K) — Combined open+history AR. Source for `dbo.RM_Transactions_snapshot_*`.
`gp.view_AR_Apply_Detail` (671K) — Payment-to-invoice application. Source for `dbo.AR_Apply_Detail_snapshot_*`.
`gp.view_SOP_LINE_DETAILS` (2.5M) — Purchase order line items.
`gp.RM00101` (4K) — **Customer Master.** `CUSTNMBR`, `CUSTNAME`, `ADDRESS1`, `CITY`, `STATE`, `PYMTRMID`, `INACTIVE`.
`gp.GL30000` (2.8M) — Account Summary (GL balances).
`gp.SOP10102` (1.7M) — SOP line items (work/open).
`gp.FA41900` (1.9M) — Fixed Asset detail history.
`gp.PM00200` (6.7K) — **Vendor Master.**
`gp.SalesWithApplyInfo` (584K) — Pre-joined sales with apply detail.

GP table number convention: `00*`=Setup/Master, `10*`=Work/Open, `20*`=Temp, `30*`=History. Prefixes: RM=Receivables, GL=General Ledger, SOP=Sales Order Processing, PM=Payables, FA=Fixed Assets, TX=Tax, UPR=Payroll.

### Key dbo Snapshots & Views

`dbo.RM_Transactions_snapshot_YYYYMMDD` (~785K) — Snapshot of `gp.view_RM_Transactions`. DocTypes: Invoice (591K/$2.4B), Payment (159K), Return (22K), Finance Charge (11K), Debit Memo (1.6K).
`dbo.AR_Apply_Detail_snapshot_YYYYMMDD` (~622K) — Snapshot of `gp.view_AR_Apply_Detail`.
`dbo.SageAssets` (~679K, 97 cols) — Flattened Sage asset register from both companies. Key fields: `CompAsstNo`, `User1` (equip type), `User2` (customer), `IsInactive`. Join to SF: `CompAsstNoClean` ≈ `sf.Asset.Sage_Asset__c`.
`dbo.sage_depreciation_details` (View) — Per-asset depreciation by book (LW/FED/STATE). 365K active LW assets, $1.25B acquired, $678M NBV.
`dbo.gp_lease_schedule_map` (3,145) — GP master lease + schedule bridge table.
`dbo.pbi_*` (34 views) — Power BI datasets: `pbi_lease_detail`, `pbi_workout_detail`, `pbi_workouts_active`, `pbi_asset_detail`, `pbi_opportunity_detail`, `pbi_default_detail`, etc.
`dbo.loan_package_ar*` (13 views) — Loan package AR with quarterly snapshots and vintage analysis.

**Snapshot convention:** `*_YYYYMMDD` or `*_snapshot_YYYYMMDD`. Views without date suffix = current data.

## QUERY CHECKLIST
1. Identify primary entity: Opportunity, Lease, Asset, Account, or Billing?
2. Apply IsDeleted = 0 on ALL sf tables
3. Exclude Placeholder records
4. Use correct join path from entity relationships above
5. For equipment queries: search descriptions first, then Equip_Type__c
6. Include human-readable names (Account, Opportunity, Lease names), not just IDs
7. Order results sensibly (by date DESC, amount DESC, or relevance)
8. Use LEFT JOINs — not all Opportunities have Leases, not all Leases have Assets
9. GP text fields have trailing spaces — use RTRIM()
