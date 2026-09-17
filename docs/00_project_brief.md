# Project Brief — Subscriber Retention: Where Should Next Quarter's Save Budget Go?

| Field | Value |
|---|---|
| **Project** | KKBOX Subscriber Retention Budget Allocation |
| **Author** | Laxmi Gupte |
| **Version** | 0.1 — written before data access |
| **Date drafted** | 17/09/2026 |
| **Status** | Draft — pre-analysis |
| **Related docs** | `01_analysis_plan.md`, `02_decision_log.md`, `03_backlog_and_risks.md` |

---

## 0. A note on framing

This is a **portfolio project**, not client work. The dataset is real — subscriber records donated by KKBOX for the WSDM Cup 2018 churn prediction challenge. The **business scenario, stakeholders and budget constraints are constructed by me** to make the analysis behave like a real assignment rather than an academic exercise.

I have flagged every invented business parameter explicitly in Section 8 (Assumptions). Nothing in this repository should be read as a statement about KKBOX's actual commercial performance or decisions.

---

## 1. Business context

KKBOX is a subscription music streaming service operating across Asia, with a paid-subscription model sitting alongside an ad-supported free tier. Subscribers hold plans of varying length — most commonly 7, 30 or 180 days — which either auto-renew or require an active renewal decision at expiry.

Because the majority of subscriptions run on 30-day cycles, **a large share of the subscriber base makes a renewal decision every single month**. Roughly 970,000 subscriptions expire in the cohort month under analysis (March 2017). Each of those is a moment at which the company either retains a paying customer or loses one, and the volume means small movements in renewal rate translate into material revenue.

A subscriber is treated as **churned** when no new valid subscription transaction occurs within 30 days of their membership expiry date. This is KKBOX's own definition, published with the dataset and implemented in `WSDMChurnLabeller.scala`. I have adopted it unchanged rather than inventing my own, so that the label matches how the business actually counts churn.

---

## 2. The problem

The Subscriber Growth team runs an outbound retention campaign — a blended push, email and in-app offer — targeted at subscribers approaching expiry. Contact capacity is finite, so only a fraction of the expiring cohort can be reached in any month.

The current targeting rule is: **contact everyone whose auto-renew flag is off.**

Nobody has tested whether that rule is any good. Specifically, three things are unknown:

1. **Whether those subscribers are actually at risk.** Auto-renew status may simply be correlated with a subscriber type, not with churn intent.
2. **Whether they are worth saving.** The rule takes no account of how much revenue a given subscriber represents. A 7-day trial holder and a long-tenured 180-day plan holder count the same.
3. **What the campaign can afford to pay per save.** Without a value figure per retained subscriber, there is no basis for approving or sizing the budget.

Finance has asked the Head of Subscriber Growth to justify the spend before the budget is released. She has no analysis to give them.

---

## 3. Objective

Produce a defensible, numbers-backed recommendation for **who receives retention spend in the next monthly expiry cohort, and what the maximum justifiable cost per save is for each target group** — in a form the Head of Subscriber Growth can take to Finance without further analytical work.

---

## 4. Primary question

> **Which expiring subscribers should receive retention spend next month, and what is the maximum defensible cost per save for each group?**

### Supporting questions

| # | Question | Why it matters to the decision |
|---|---|---|
| **Q1** | What is the true 30-day non-renewal rate among expiring subscribers, and how does it vary by tenure, plan length, payment method, auto-renew status and discount depth? | Establishes where churn actually concentrates — the baseline the current rule is implicitly betting on |
| **Q2** | Which listening behaviours in the 30 days before expiry separate non-renewers from renewers, and how much of that signal is visible early enough to act on? | Determines whether behavioural targeting is possible at all, and how much lead time CRM has to execute |
| **Q3** | What is expected remaining subscriber value by segment, and therefore the economic ceiling on cost per save? | Converts the analysis into a budget number Finance can approve |
| **Q4** | If the team can contact only a capped number of subscribers, does a behavioural risk score capture more at-risk value than the current auto-renew rule? | Tests the status quo directly and decides whether a model is worth operationalising |
| **Q5** | Is the auto-renew relationship causal or confounded, and what would be needed to find out? | Prevents a spurious recommendation and defines the follow-up experiment |

Q5 is included deliberately even though this dataset **cannot** answer it. Saying so, and specifying the test that would, is more useful to the stakeholder than a confident answer the data doesn't support.

---

## 5. The decision this enables

| Decision | Owner | What they need from this work |
|---|---|---|
| Approve or reject the retention budget | Finance Business Partner | Cost per save ceiling, total reachable value, a downside case |
| Choose the targeting strategy for next cohort | Head of Subscriber Growth | Ranked segments with value and risk attached |
| Build and execute the contact list | CRM / Lifecycle Manager | A documented, reproducible targeting rule and expected list size |
| Decide whether to invest in scoring infrastructure | Head of Subscriber Growth | Head-to-head result: model vs. simple rule at equal budget |

---

## 6. Stakeholders

| Stakeholder | Type | Decision they own | Metrics they care about | What would make them reject this work |
|---|---|---|---|---|
| Head of Subscriber Growth | **Primary** | Targeting strategy, budget request | Value-weighted retention rate, reachable at-risk value | A recommendation she can't explain to Finance in one slide |
| Finance Business Partner | Secondary | Budget release | Cost per save, payback, downside scenario | Assumptions that aren't stated, or a single-point estimate with no sensitivity |
| CRM / Lifecycle Manager | Secondary | List build and send | Segment definitions, list size, reachability | A rule that can't be translated into a query against production data |
| Product Analytics | Secondary | Owns engagement metric definitions | Metric definitions, consistency with existing reporting | Redefining engagement metrics without saying so |

---

## 7. Scope

### 7.1 In scope

| Area | Detail |
|---|---|
| **Cohort** | Subscribers whose membership expires in **March 2017** (`train_v2` label set) |
| **Outcome** | Binary non-renewal within 30 days of expiry, per KKBOX's published definition |
| **Behavioural window** | Listening activity in the **30 days strictly before** each subscriber's own expiry date, plus weekly aggregates for the 8 weeks prior |
| **Segmentation dimensions** | Tenure band, plan length, payment method, auto-renew flag, discount depth, registration channel, city |
| **Unit economics** | Monthly ARPU, expected remaining tenure, contribution-margin-adjusted CLV, cost-per-save ceiling |
| **Targeting evaluation** | Model score vs. current auto-renew rule vs. random, compared at equal contact volume |
| **Outputs** | Tableau dashboard, stakeholder slide deck, Streamlit planning tool, documented repository |

### 7.2 Out of scope — and why

This list exists to prevent scope drift and to make the boundaries of the recommendation explicit to anyone reading the work.

| Excluded | Reason |
|---|---|
| **Music recommendation / content affinity modelling** | Different business problem (WSDM Cup Task 1). Does not inform a budget allocation decision. |
| **Acquisition analysis, CAC, channel ROAS** | No acquisition cost or marketing spend data exists in this dataset. Any CAC figure would be invented. |
| **Pricing or plan-structure optimisation** | Requires price variation under controlled conditions. Observed price differences are confounded with customer selection. |
| **Creative, message or offer testing** | No campaign exposure or response data. Cannot be inferred. |
| **Causal estimation of the auto-renew or discount effect** | Observational data with obvious selection effects. Addressed as a designed experiment in the backlog instead. |
| **Production scoring pipeline, MLOps, model monitoring** | The decision is "who to contact next month", not "how to run a model in production". Deferred to backlog pending a positive answer to Q4. |
| **Leaderboard-style model optimisation (AUC maximisation)** | The decision requires a *ranking* good enough to beat a simple rule, not a maximised score. Additional accuracy beyond that point changes no decision. |
| **Full-population analysis (all ~6.7M members, ~30GB of logs)** | Deliberately sampled. Rationale and validation recorded in `02_decision_log.md`. |
| **Free / ad-supported tier behaviour** | Not present in the dataset. All findings apply to paid subscribers only. |
| **Subscriber base forecasting** | Requires multiple cohort months and seasonality data. One cohort month is insufficient. |
| **Geographic or market-level strategy** | `city` is an anonymised integer with no lookup. Usable as a segmentation variable, not as a geography. |
| **Song-, artist- or genre-level analysis** | Not available in the churn dataset. |

### 7.3 Explicitly deferred (not rejected)

These are good ideas that don't fit the current time box. They live in `03_backlog_and_risks.md`.

- Kaplan-Meier survival analysis to replace the assumed expected-tenure figure *(planned as a stretch within this project)*
- Holdout experiment design to establish campaign causality *(planned as a stretch within this project)*
- Out-of-time validation using the February expiry cohort (`train.csv`)
- Multi-cohort seasonality analysis

---

## 8. Assumptions

Every assumption below is either (a) a property of the data I'm accepting, or (b) a business parameter I've had to invent because the dataset doesn't contain it. Invented parameters are marked **[INVENTED]** and must be sensitivity-tested rather than reported as fact.

| # | Assumption | Value / statement | Impact if wrong | How I'll handle it |
|---|---|---|---|---|
| A1 | The KKBOX churn definition reflects how the business counts churn | No valid renewal within 30 days of expiry | Fundamental — all findings would be mis-anchored | Adopted from `WSDMChurnLabeller.scala`, unchanged. Not varied. |
| A2 | A stratified random sample of subscribers represents the population | ~200,000 subscribers from `train_v2` | Segment-level rates biased | **Validated** against population churn rate, plan mix and auto-renew mix before proceeding. Target agreement within 0.5pp. |
| A3 | March 2017 is a representative expiry month | No seasonal adjustment applied | Rates could be systematically high or low | **Cannot be tested with one cohort.** Stated as a limitation in the README. Listed as a risk. |
| A4 | Reporting FX rate | **NT$34 = €1**, fixed | Absolute euro figures shift | Convenience rate for readability only. All underlying analysis in NT$. Ratios and rankings unaffected. |
| A5 | **[INVENTED]** Monthly contact capacity | **5% of the expiring cohort** (~48,500 of ~970,000; ~10,000 within the sample) | Changes list size and which segments make the cut | Expressed as a *rate* so it scales. Varied 2% / 5% / 10% in the Streamlit planner. |
| A6 | **[INVENTED]** Cost per contact | **NT$12 (≈ €0.35)** blended push/email/in-app | Changes breakeven, not targeting order | Slider input in the Streamlit planner. Reported as a breakeven rather than a fixed cost wherever possible. |
| A7 | **[INVENTED]** Campaign save uplift | **8%** of contacted at-risk subscribers retained who would otherwise have churned | Directly scales campaign ROI | **Sensitivity-tested at 4% / 8% / 12%.** The recommendation must hold at 4% or it isn't a recommendation. |
| A8 | **[INVENTED]** Contribution margin on subscription revenue | **30%** (streaming content royalties assumed to consume the majority of revenue) | Scales the cost-per-save ceiling proportionally | Stated prominently. This is the first number a Finance partner will challenge, so it is surfaced rather than buried. |
| A9 | Expected remaining tenure can be derived from the observed segment renewal rate | Geometric survival: expected months ≈ 1 / (1 − renewal rate) | Overstates lifetime if renewal probability rises with tenure (it usually does) | **Known to be conservative.** Replaced with an empirical Kaplan-Meier estimate in the survival-analysis stretch; the delta is reported. |
| A10 | Behavioural features are available to CRM at decision time | Listening data from before expiry | If unavailable in production, the targeting rule is unusable | Every feature is restricted to data observable **strictly before** the expiry date. Documented as a leakage rule in `01_analysis_plan.md`. |
| A11 | Subscribers churn independently of one another | No network or household effects modelled | Confidence intervals slightly optimistic | Accepted. Noted in limitations. |
| A12 | All analysis is observational | No randomisation anywhere in the data | Causal language would be unsupportable | **No causal claims made.** Enforced as a writing rule; the experiment design doc closes the gap. |

---

## 9. Metric definitions

Defined here once, before analysis, so that no metric quietly changes meaning between the notebook, the dashboard and the deck.

| Metric | Definition | Notes |
|---|---|---|
| **Churn / non-renewal** | No valid subscription transaction within 30 days of `membership_expire_date` | Per KKBOX's published labeller |
| **Renewal rate (headcount)** | 1 − (churned subscribers / expiring subscribers) | Reported, but **not** the primary KPI |
| **Renewal rate (value-weighted)** | 1 − (Σ monthly ARPU of churned / Σ monthly ARPU of expiring) | **Primary KPI.** Treats a 180-day plan holder and a 7-day holder proportionally to their revenue |
| **Monthly ARPU** | `actual_amount_paid / payment_plan_days × 30` | Normalises 7 / 30 / 180-day plans onto one comparable scale |
| **Discount depth** | `(plan_list_price − actual_amount_paid) / plan_list_price` | Zero when paying list price; bucketed into bands for segmentation |
| **Tenure** | Months between `registration_init_time` and expiry date | Banded: 0–3, 3–6, 6–12, 12–24, 24+ months |
| **Expected remaining months** | Under A9: `1 / (1 − segment renewal rate)` | Replaced by Kaplan–Meier estimate in the stretch |
| **CLV (contribution)** | `Monthly ARPU × Expected remaining months × contribution margin (A8)` | The margin adjustment is what makes this a number Finance can use |
| **Max cost per save** | Equal to CLV (contribution). Paying more than the value retained destroys value | The ceiling, not the target |
| **Max cost per contact** | `Save uplift (A7) × CLV (contribution)` | The operationally useful figure — most contacts do not convert to saves |
| **Reachable at-risk value** | Σ CLV of at-risk subscribers within the contact cap (A5) | The size of the prize |
| **Active listening days** | Count of distinct days with any log activity in the 30 days before expiry | Engagement volume proxy |
| **Completion ratio** | `num_100 / (num_25 + num_50 + num_75 + num_985 + num_100)` | Engagement *quality* — distinguishes real listening from skipping |
| **Engagement trend** | Week-4 activity vs. week-1 activity in the 8-week pre-expiry window | The early-warning signal |
| **Lift @ decile 1** | Churners captured in the top-scored 10% ÷ churners captured by random 10% | Model evaluation metric |
| **Incremental value captured** | At-risk value reached by model targeting − at-risk value reached by the auto-renew rule, at equal contact volume | **The metric that answers Q4** |

---

## 10. Data sources

| Source | Grain | Period | Role |
|---|---|---|---|
| `members_v3.csv` | One row per subscriber | Registration through Mar 2017 | Demographics, registration channel, tenure anchor |
| `transactions.csv` | One row per transaction | Jan 2015 – Feb 2017 | Prior transaction history, discount history, prior cancellations |
| `transactions_v2.csv` | One row per transaction | Mar 2017 | Expiry-anchored transaction, plan, price, auto-renew |
| `user_logs.csv` | One row per subscriber per day | Jan 2015 – Feb 2017 | Pre-expiry behavioural window (streamed and filtered, never fully extracted) |
| `user_logs_v2.csv` | One row per subscriber per day | Mar 2017 | Completes the pre-expiry window for late-March expiries |
| `train_v2.csv` | One row per subscriber | Mar 2017 expiries | Churn label |
| `WSDMChurnLabeller.scala` | — | — | Authoritative label logic, read and documented |

**Licence note:** this data is provided under Kaggle competition terms. **Raw data files are not committed to this repository.** `data/README.md` documents how to obtain them, and `src/01_sample_and_load.py` reproduces the sample deterministically.

---

## 11. Constraints

| Constraint | Detail |
|---|---|
| **Time** | ~22 focused hours across one week |
| **Compute** | Single laptop. `user_logs.csv` (~30GB uncompressed) exceeds comfortable working memory and is streamed rather than stored |
| **Data currency** | 2017. Findings are methodological rather than current-state commercial intelligence |
| **Single market view** | `city` is anonymised; no geographic interpretation possible |
| **No experimental data** | Every comparison is observational |
| **Distribution** | Raw data cannot be redistributed; reproducibility achieved through scripts, not committed data |

---

## 12. Success criteria

This project succeeds if:

1. The Head of Subscriber Growth can state **which segments get budget and why**, from the deck alone, without opening a notebook.
2. Finance receives a **cost-per-save ceiling with a stated downside case**, not a single-point estimate.
3. The CRM manager can **reproduce the target list** from a documented rule.
4. **Every recommendation traces to a specific number** in the analysis.
5. The work states clearly **what it cannot conclude**, and what would be required to conclude it.
6. A reader can follow the reasoning **without needing the model to be correct** — the unit economics stand on their own.

It does **not** succeed on the basis of model accuracy, technique count, or dashboard complexity.

---

## 13. Deliverables

| Deliverable | Audience | Location |
|---|---|---|
| Stakeholder slide deck (8 slides, PDF) | Head of Growth, Finance | `deck/` |
| Tableau dashboard (published, linked) | Head of Growth, Finance | `dashboard/` |
| Streamlit campaign planner | CRM Manager | Linked from README |
| Analysis notebooks (3) | Analyst peer / technical reviewer | `notebooks/` |
| SQL feature layer | Data team | `sql/` |
| Project documentation | Reviewer, future self | `docs/` |
| README | Everyone — the primary artifact | Repository root |

---

## 14. Milestones

| Milestone | Target hour | Definition of done |
|---|---|---|
| M1 — Framing complete | 1 | Brief and analysis plan committed **before** data access |
| M2 — Data validated | 4 | Sample validated against population; SQLite built and integrity-checked |
| M3 — Feature layer complete | 6 | Expiry-anchored behavioural window built and sanity-checked |
| M4 — Business answer complete | 8.5 | Cost-per-save ceiling and reachable value computed with sensitivity |
| M5 — Targeting decision made | 10 | Model vs. rule head-to-head resolved, either way |
| M6 — Stakeholder outputs ready | 13 | Dashboard published, deck exported |
| M7 — **Shippable** | 15 | README, docs, reproducible notebooks, clean repo |
| M8 — Tool delivered | 18.5 | Streamlit planner deployed and cross-checked against notebook |
| M9 — Analysis deepened | 22 | Survival analysis integrated; experiment design documented |

The project is deliberately **shippable at M7**. Everything after is upside on a finished artifact.

---

## 15. Definition of done

- [ ] Every claim in the deck traces to a number in a notebook
- [ ] Every notebook runs end-to-end from a clean kernel
- [ ] No raw data, database file or credential is tracked in Git
- [ ] Every invented business parameter is labelled and sensitivity-tested
- [ ] Limitations section written and honest
- [ ] Decision log has at least 8 dated entries
- [ ] A reviewer unfamiliar with the dataset can understand the business case in under two minutes from the README

---

## 16. Change history

| Version | Date | Change | Reason |
|---|---|---|---|
| 0.1 | [DATE] | Initial brief, pre-data-access | — |
| | | | |

> Update this table whenever scope, assumptions or success criteria change. A brief that visibly evolved is more credible than one that didn't — but only if the changes are explained.
