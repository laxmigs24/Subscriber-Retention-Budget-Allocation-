# Subscriber Retention: Where Should the Save Budget Go?

**Which expiring subscribers should receive retention spend, and what is a save actually worth?**

A retention-budget analysis on 200,000 subscribers of a music streaming service. It tests the CRM team's existing targeting rule, finds it sound, and answers the question the rule cannot: of the 23,452 subscribers it flags, which 9,999 should be contacted.

**Headline finding: whether this campaign makes or loses money depends entirely on how the contact list is ordered — a €24,780 annual swing on identical spend.**

🔗 **[Interactive dashboard (Tableau Public)](https://public.tableau.com/app/profile/laxmi.gupte/viz/KKBOX_17907749007090/Dashboard1)** · 📊 **[Stakeholder deck (PDF)](deck/retention_budget_recommendation.pdf)**

---

> **This is a portfolio project, not client work.** The dataset is real — subscriber records donated by KKBOX for the WSDM Cup 2018 churn challenge. The business scenario, stakeholders and budget constraints are constructed by me so the analysis behaves like a real assignment rather than an academic exercise. Every invented business parameter is labelled and sensitivity-tested. See [`docs/00_project_brief.md`](docs/00_project_brief.md).

---

## The situation

A music streaming service has roughly 970,000 subscriptions expiring every month. An outbound save campaign — push, email, in-app — contacts subscribers before expiry, but capacity covers only about 5% of the cohort.

The team's rule is: **contact everyone whose auto-renew is off.** Finance wants the spend justified before releasing budget, and nobody has checked whether those subscribers are at risk, whether they are worth saving, or what a save can cost.

## What the analysis found

| | |
|---|---|
| **The existing rule is sound** | Auto-renew off churns at **41.2%** against **4.7%** for auto-renew on. Two thirds of that 36.5pp gap survives stratification by tenure and plan, so it is not simply a proxy for customer type. |
| **But it cannot prioritise** | It flags 23,452 subscribers against capacity for 9,999. **57% go uncontacted on no principled basis.** |
| **Ordering decides profitability** | Three of six targeting methods return **below break-even**. Random ordering loses €1,088/month; expected-value ranking returns €977. Same spend, same capacity. |
| **There is a hard cost ceiling** | The best method breaks even at **NT$15.32** per contact against an actual cost of NT$12 — 28% headroom. Random targeting breaks even at NT$8.30, *below* what is already paid, so it cannot work at any budget. |
| **Two products in one population** | Monthly plans are 78% of subscribers and churn at 29%. Anything longer churns at **76–86%** — these are prepaid block purchases, not lapsing subscriptions. |
| **Tenure does not discriminate** | 1.7pp spread across tenure bands, below the 2pp practical threshold fixed before analysis. The original hypothesis was wrong. |
| **Behaviour is not worth building for** | Listening features carry **34.5% of model gain** but add **2.7% of incremental value** — below the 5% threshold set before fitting. |

### Targeting methods compared, at equal contact volume

| Method | Precision | At-risk value reached | ROI | Break-even |
|---|---|---|---|---|
| **Model × customer value** | **66.8%** | **€16,897** | **1.28×** | NT$15.32 |
| Model, account data only | 63.8% | €16,452 | 1.24× | NT$14.92 |
| Rank by customer value | 52.8% | €15,152 | 1.14× | NT$13.74 |
| Fewest listening days | 49.6% | €10,810 | 0.82× | NT$9.80 |
| Longest since last play | 46.2% | €9,787 | 0.74× | NT$8.87 |
| Random within rule | 41.3% | €9,154 | 0.69× | NT$8.30 |

## Recommendations

1. **Fund the campaign, but rank the list by expected value** — risk score × customer value, not risk alone. Returns 1.28× against 0.69× for arbitrary selection. *Owner: Subscriber Growth*
2. **Split the treatment.** Monthly subscribers get a save offer; prepaid-block customers get a re-purchase prompt. One message for two behaviours leaves value on the table. *Owner: CRM*
3. **Hold contact cost below NT$15.** Above that the campaign stops paying back regardless of targeting. *Owner: CRM*
4. **Do not build behavioural scoring infrastructure.** It adds 2.7% of value for a meaningful engineering cost. *Owner: Product Analytics*

---

## Approach

```
business framing  →  data audit & sampling  →  SQLite build  →  SQL feature layer
       ↓                                                              ↓
  brief + plan                                              expiry-anchored windows
  written before                                                      ↓
  data access                          segment KPIs  →  unit economics  →  targeting model
                                                                      ↓
                                              dashboard  ·  deck  ·  recommendations
```

| Stage | Tool | Why |
|---|---|---|
| Framing, scope, assumptions | Markdown | Written **before** data access — the git history shows it |
| Audit, sampling, validation gate | pandas, chunked reads | 30 GB of logs streamed, never extracted |
| Database build | Python → SQLite | Reproducible in under an hour from scripts alone |
| Feature layer | SQL (CTEs, window functions) | Per-subscriber windows anchored to each individual expiry date |
| Segment KPIs, unit economics | pandas, statsmodels | Chained arithmetic and scenario grids are clearer here than in nested SQL |
| Targeting model | LightGBM | One model, evaluated on business value rather than AUC |
| Stakeholder output | Tableau Public, PDF deck | |

### Technical details worth a look

- **`sql/01`** — transaction dedupe and expiry-anchor selection, with a leakage guard excluding any transaction dated after expiry
- **`sql/02`** — behavioural windows built on a subscriber × week spine so silence counts as zero rather than vanishing ([why that matters](docs/02_decision_log.md))
- **`src/filter_logs.py`** — streams a 30 GB archive through a filter without writing it to disk
- **`notebooks/03`** — leakage audit before fitting; both success thresholds fixed in advance

---

## What I got wrong, and how I caught it

The most useful parts of this project are the three errors.

**A join artefact that produced a false null result.** The weekly behavioural table created a row only where log rows existed, so subscribers who went silent were dropped from that week's average rather than counted as zero. The statistic became "active days among the active" — flat by construction, at ~4.5 days in every one of eight weeks. It read as "no behavioural signal exists". Caught because the flatness was implausible, not because anything errored. Fixing it dropped the week-1 figure from 4.58 to 3.20.

**Non-neutral exclusions.** Dropping 22,747 subscribers with missing tenure moved the cohort churn rate by 0.46pp — past the 0.1pp neutrality gate set in the analysis plan. That group churns at ~5.4%, so excluding it inflated the headline. Reclassified from excluded to flagged; the gate now passes at 0.009pp.

**The wrong denominator for CLV.** `payment_plan_days` carried 41% of model gain — more than all sixteen behavioural features combined. Investigating why revealed that a long plan with auto-renew off is a **prepaid block purchase, not a subscription**. Tenure-based CLV was the wrong basis entirely. Correcting it cut total at-risk value from €140,551 to €69,586 and changed the targeting ranking.

Full record in [`docs/02_decision_log.md`](docs/02_decision_log.md).

---

## Limitations

- **No causal claim.** All data is observational. The analysis identifies who is at risk; it cannot say the campaign changes behaviour.
- **The 8% save rate is assumed, not measured.** The recommendation holds down to 4%, but has never been tested.
- **One cohort, one month.** March 2017. No seasonality view.
- **2017 data**, one market, `city` anonymised.
- **Behaviour missed its threshold by 0.2pp** on a 7,036-row test set — within noise. The finding is "not worth the build cost", not "useless".

**Next step:** withhold contact from a random 10% of the target list and measure the difference in renewal. Four weeks, and it converts every figure here from an association into a number Finance can rely on. Full backlog in [`docs/03_backlog_and_risks.md`](docs/03_backlog_and_risks.md).

---

## Repository

```
├── docs/
│   ├── 00_project_brief.md       objective, scope, in/out, assumptions
│   ├── 01_analysis_plan.md       question → method → tool, written before analysis
│   ├── 02_decision_log.md        dated decisions with rationale and cost
│   ├── 03_backlog_and_risks.md   what's next, what could be wrong
│   ├── TABLEAU_BUILD_GUIDE.md    dashboard spec
│   └── VALIDATION_NOTES.txt      what reconciles and what doesn't
├── src/
│   ├── filter_logs.py            streams the 30 GB archive through a filter
│   └── 01_sample_and_load.py     chunked CSV → SQLite, indexed
├── sql/
│   ├── 01_clean_transactions.sql dedupe + expiry anchor + leakage guard
│   ├── 02_expiry_anchored_window.sql  30-day and 8-week windows on a spine
│   └── 03_segment_kpis.sql       dimensions, economics, analysis_base
├── notebooks/
│   ├── 01_data_audit.ipynb       profiling, sampling, validation gate
│   ├── 02_retention_and_unit_economics.ipynb   Q1–Q3, Q5
│   └── 03_risk_scoring_and_targeting.ipynb     Q4, leakage audit, model
├── dashboard/data/               five aggregate CSVs the dashboard reads
├── outputs/                      analysis result tables
├── deck/                         stakeholder PDF
├── images/                       charts used in the deck and README
└── data/                         raw and derived data — gitignored, see data/README.md
```

## Reproducing this

Raw data is **not committed** — it is distributed under Kaggle competition terms and is ~30 GB uncompressed.

```bash
# 1. download the archives from Kaggle into data/raw/
#    https://www.kaggle.com/c/kkbox-churn-prediction-challenge/data
#    members_v3, train_v2, transactions, transactions_v2, user_logs, user_logs_v2

# 2. audit, profile, sample 200k subscribers, write sample_msno.txt
jupyter notebook notebooks/01_data_audit.ipynb

# 3. stream-filter the 30 GB log archive without extracting it
7z e -so data/raw/user_logs.csv.7z | python3 src/filter_logs.py

# 4. build the database
python3 src/01_sample_and_load.py

# 5. feature layer, in order
sqlite3 data/kkbox.db < sql/01_clean_transactions.sql
sqlite3 data/kkbox.db < sql/02_expiry_anchored_window.sql
sqlite3 data/kkbox.db < sql/03_segment_kpis.sql

# 6. analysis
jupyter notebook notebooks/02_retention_and_unit_economics.ipynb
jupyter notebook notebooks/03_risk_scoring_and_targeting.ipynb
```

Every SQL file ends with validation queries that print when run. Both notebooks carry gates that halt on failure.

**Stack:** Python (pandas, NumPy, statsmodels, scikit-learn, LightGBM, matplotlib) · SQL (SQLite) · Tableau Public · Git

---

*Data: KKBOX, released for the WSDM Cup 2018 churn prediction challenge. Figures in EUR at a fixed NT$34 = €1 for readability. Assumes 8% campaign uplift and 30% contribution margin; both sensitivity-tested.*
