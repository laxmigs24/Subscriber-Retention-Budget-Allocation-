# Dashboard Brief — KKBOX Retention Budget Allocation

Everything needed to build the dashboard is in this document and in `dashboard_data.json`. No database access required.

---

## 1. The situation

KKBOX is a subscription music streaming service. Roughly 970,000 subscriptions expire each month, and the Subscriber Growth team runs an outbound save campaign against subscribers approaching expiry. Contact capacity is finite.

The team's existing targeting rule is **contact everyone whose auto-renew flag is off**. The analysis tested that rule and found it sound: auto-renew off churns at 41.2% against 4.7% for auto-renew on, and 66% of that gap survives stratification by tenure and plan.

What the rule cannot do is **prioritise**. It flags 23,452 subscribers against capacity for 9,999 — so 57% go uncontacted, currently on no principled basis.

**The dashboard exists to answer one question: should Finance fund this campaign, and how should the list be ordered?**

---

## 2. Audience and purpose

| | |
|---|---|
| Primary | Head of Subscriber Growth — decides targeting strategy, requests budget |
| Secondary | Finance Business Partner — releases or blocks the budget |
| Read time | Under one minute, without asking the analyst anything |
| Tone | Decision document, not an exploration |

**All figures describe the target population only** — subscribers with auto-renew off. This is not a whole-company churn dashboard.

---

## 3. The argument the dashboard must make

In this order:

1. **The campaign is not inherently profitable or unprofitable — the list order decides.** Three of six targeting methods return below 1.0x. Random targeting loses €1,088 a month; the model returns €977. Same spend, same capacity.
2. **Cost per contact has a hard ceiling.** The best method breaks even at NT$15.32 against an actual cost of NT$12 — 28% headroom. Random targeting breaks even at NT$8.30, below actual cost, so it cannot work at any budget.
3. **The flagged population contains two different products.** Monthly plans are 78% of subscribers and churn at 29%. Everything longer churns at 76–86% at up to 12x the value per cycle — these are prepaid block purchases, not lapsing subscriptions, and they need a re-purchase prompt rather than a save offer.
4. **Behavioural data is not worth building for.** Behavioural features carry 34.5% of model gain but add only 2.7% of incremental value, below the 5% threshold fixed before the model was fitted.

---

## 4. Required views

### KPI strip — eight tiles, one row

From `kpi_cards` in the JSON, in the given order. Tiles 7 and 8 carry the decision and must be visually heavier than the rest. Tile 7 green if ROI >= 1, red otherwise. Tile 8 shows the subtitle "actual cost NT$12".

### View 1 — ROI by targeting method *(the headline)*

- Horizontal bars, sorted descending by `roi`
- Source: `roi_by_method`
- Colour by `pays_back`: green for "Pays back", muted red for "Loses money"
- **Dashed reference line at 1.0, labelled "breakeven"**
- Bar labels formatted `0.00x`
- Tooltip: method, precision, churners reached, cost, value saved, net
- Title: **"Whether this campaign pays back depends on the list, not the budget"**

### View 2 — Breakeven cost per contact

- Horizontal bars, same sort order as View 1
- Field: `breakeven_ntd`
- Single colour
- **Solid red reference line at 12**, labelled "actual cost per contact NT$12"
- Labels formatted `NT$0.00`
- Title: **"How much can a contact cost before this stops working?"**

### View 3 — Value capture curve

- Line chart, x = subscribers contacted (0 to 23,452), y = % of at-risk value captured
- Four lines: Random within rule, CLV-ranked, Fewest active days, Model x CLV
- **Dashed vertical reference line at 9,999**, labelled "contact capacity"
- Curve shape: concave, rising steeply then flattening. Anchor points at capacity (9,999 contacts): Random 43.3%, Fewest active days 51.2%, CLV-ranked 71.7%, Model 80.0%. All four reach 100% at 23,452.
- Title: **"Value captured as the list gets longer"**
- Note: only the region left of the dashed line is reachable

### View 4 — Two products in one population

- Combo chart, x = `plan_band`
- Bars: `subscribers`, coloured by `purchase_type` (Subscription vs Prepaid block)
- Line with markers on a secondary axis: `clv_eur`, labelled in euro
- Tooltip: churn rate, amount paid, at-risk EUR, share of at-risk value
- Title: **"Two products in one population"**
- The story: monthly is 78% of subscribers but 37% of at-risk value; annual is 8% of subscribers but 39% of value

### View 5 — Feature importance is not business value

- Two bars: account 65.5%, behaviour 34.5% of model gain
- Annotation on the behaviour bar: **"34.5% of model gain, 2.7% of incremental value — below the 5% threshold set before fitting"**
- Small strip, not a full panel
- Title: **"Feature importance is not business value"**

---

## 5. Layout

Fixed 1200 x 900.

```
┌──────────────────────────────────────────────────────────────┐
│  Retention campaign — fund it, but fix the targeting          │
│  March 2017 expiry cohort · 200k sampled subscribers          │
├──────────────────────────────────────────────────────────────┤
│  KPI strip — 8 tiles, ~90px tall                              │
├───────────────────────────────┬──────────────────────────────┤
│  View 1 — ROI by method       │  View 2 — Breakeven cost      │
├───────────────────────────────┼──────────────────────────────┤
│  View 3 — Value capture curve │  View 4 — Two products        │
├───────────────────────────────┴──────────────────────────────┤
│  View 5 — gain vs value (short strip)                         │
└──────────────────────────────────────────────────────────────┘
```

**No filters.** The dashboard makes an argument; filters invite the reader off it. Interactivity belongs elsewhere.

**Footer caption, small text:**

> Observational data, March 2017 expiry cohort. Assumes 8% campaign uplift and 30% contribution margin; both sensitivity-tested. No causal claims.

---

## 6. Design

| | |
|---|---|
| Palette | Restrained. One accent for "pays back" (green), one muted red for "loses money", neutral greys elsewhere. Avoid rainbow categoricals. |
| Reference lines | Dashed for capacity and breakeven thresholds, solid red for actual cost. These carry meaning — do not style them as decoration. |
| Titles | Every view title is a **claim**, not a topic. If a title could sit above any dataset, it is doing no work. |
| Numbers | Euro to whole units. ROI to 2dp with an `x` suffix. NT$ to 2dp. Percentages to 1dp. |
| Density | Five views plus a KPI strip. Do not add charts to fill space. |

---

## 7. Data dictionary

All data is in `dashboard_data.json`.

| Key | Grain | Fields |
|---|---|---|
| `kpi_cards` | one per metric | metric, value, format, subtitle, emphasis |
| `roi_by_method` | one per targeting method | method, churners_reached, precision, at_risk_eur, pct_of_ceiling, vs_random, saves, value_saved_eur, net_eur, roi, breakeven_ntd, kind, pays_back |
| `plan_economics` | one per plan band | plan_band, subscribers, churn_rate, amount_paid_ntd, expected_cycles, clv_ntd, clv_eur, at_risk_eur, purchase_type, share_of_at_risk_pct, share_of_subscribers_pct |
| `gain_vs_value` | one per feature type | kind, share_of_gain_pct, incremental_value_pct |
| `model_stats` | single object | AUC both models, uplift figures and thresholds, top feature, decile lift |
| `cohort_context` | single object | whole-cohort background figures, for reference only |
| `assumptions` | single object | FX, contact cap, cost per contact, uplift, margin |

**Note on `pct_of_ceiling`:** percentage of total at-risk value captured at the contact cap, measured on a 30% test set of 7,036 subscribers. `saves`, `value_saved_eur`, `net_eur` and `roi` are scaled to the full 23,452 population at 9,999 contacts.

---

## 8. What not to do

- Do not build a general churn dashboard. This is about one budget decision in one population.
- Do not add filters, parameters or drill-downs.
- Do not present AUC prominently. It is a footnote; the decision metric is at-risk value captured at capacity.
- Do not describe the model as predicting churn "accurately". It orders a list better than the alternatives, and that is the claim.
- Do not use causal language anywhere. The data is observational.
- Do not add charts that inform no decision.
