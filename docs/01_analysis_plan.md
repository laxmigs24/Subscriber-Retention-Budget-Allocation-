# Analysis Plan

| Field | Value |
|---|---|
| **Project** | KKBOX Subscriber Retention Budget Allocation |
| **Author** | Laxmi Gupte |
| **Version** | 0.1 — written before data access |
| **Date drafted** | 17-09-2026 |
| **Status** | Planned — no analysis executed |
| **Parent doc** | `00_project_brief.md` |

---

## Purpose

This document states **how each question will be answered, with what, and what would count as an answer** — written before the data was opened.

It exists for two reasons. First, pre-committing to methods and thresholds prevents the most common failure in analytical work: deciding what counts as a finding *after* seeing the results. Second, it gives a reviewer a way to check whether the analysis that happened is the analysis that was planned.

Section 7 records what changed and why. **A plan that changed is not a failed plan** — but an undocumented change is a failed process.

---

## 1. Decisions taken before looking at the data

These are pre-committed. Changing any of them after seeing results requires a dated entry in Section 7 and in `02_decision_log.md`.

| Decision | Committed value | Rationale |
|---|---|---|
| **Primary KPI** | Value-weighted renewal rate | A headcount rate treats a 7-day trial and a 180-day subscriber identically. The budget decision is about revenue, so the metric must be about revenue. |
| **Practical significance threshold** | **2 percentage points** | A renewal-rate difference below 2pp between segments does not change who gets contacted, so it will not be reported as a finding regardless of statistical significance. |
| **Stance on p-values** | Effect sizes and 95% Wilson confidence intervals reported first; p-values reported second, where used at all | At n ≈ 200,000 virtually every comparison returns p < 0.001. Statistical significance carries almost no information here; practical significance carries all of it. |
| **Minimum segment size** | **n ≥ 500** | Segments below this are collapsed into an "other" bucket or flagged as indicative only. Prevents recommending budget toward a segment defined by noise. |
| **Model success criterion (Q4)** | Model must capture **≥10% more at-risk value** than the auto-renew rule at equal contact volume | Below that, the added operational complexity isn't worth it, and the honest recommendation is to keep the simple rule. **This threshold is set before the model is built.** |
| **Leakage rule** | No feature may use data observable at or after each subscriber's `membership_expire_date` | Both a validity requirement and a production-realism requirement — CRM must be able to compute the score before expiry |
| **Sampling validation gate** | Sample churn rate within **0.5pp** of population; plan-length and auto-renew mix within **2pp** | If the sample fails this gate, resample before proceeding. Recorded either way. |
| **Causal language** | Prohibited throughout | All data is observational. "Associated with", not "drives" or "causes". |

---

## 2. The plan

### Q0 — Data audit and sampling *(prerequisite, not a business question)*

| | |
|---|---|
| **What I need to know** | Is the data usable, and is my sample representative? |
| **Method** | Profile all tables: row counts, null rates, duplicate `(msno, transaction_date)` pairs, `bd` (age) outliers, gender missingness, integer date parsing (`YYYYMMDD`), orphan records across tables. Draw ~200k `msno` from `train_v2`. Compare sample vs. population on churn rate, plan-length mix, auto-renew rate and payment-method mix. |
| **Tool** | pandas (chunked reads); `7z` streaming for `user_logs.csv` |
| **Why this tool** | The files exceed memory; chunked profiling is the only viable route, and the streaming filter avoids writing 30GB to disk |
| **Output** | `notebooks/01_data_audit.ipynb` — a data quality table; `data/sample_msno.txt`; decision log entries |
| **Gate** | Sampling validation thresholds above. **Do not proceed past M2 without this passing.** |
| **Known risk** | Late-March expiries may have incomplete pre-expiry windows if `user_logs.csv` proves unusable. Fallback documented in `03_backlog_and_risks.md`. |

---

### Q1 — Where does non-renewal actually concentrate?

| | |
|---|---|
| **Sub-questions** | What is the overall renewal rate, headcount and value-weighted? How does it vary by tenure band, plan length, payment method, auto-renew status and discount depth? |
| **What I expect to find** | Churn concentrates in short tenure; value concentrates in long tenure. **If true, the highest-churn segment is not the highest-value segment, and the current targeting rule is optimising the wrong thing.** Recorded here so that confirming it counts as a finding and contradicting it counts equally. |
| **Method** | Segment-level renewal rates (both definitions) with 95% Wilson confidence intervals. Two-dimensional cross-tabs for plan length × auto-renew. Discount depth bucketed into bands. |
| **Tool** | SQL for aggregation (set-based work, reproducible, reviewable); pandas + statsmodels for intervals; Tableau for the stakeholder view |
| **Why SQL here** | These are group-by aggregations over joined tables at different grains — exactly what SQL is for, and it makes the logic inspectable in a `.sql` file rather than buried in notebook cells |
| **Output** | Segment KPI table; dashboard charts 1–3; deck slides 2–3 |
| **What counts as an answer** | A ranked table of segments by renewal rate **and** by value at risk, with intervals, and an explicit statement of where the two rankings disagree |
| **Stop condition** | Once segments are defined and rates computed, stop. Do not explore additional dimensions without a stated reason — this is the most likely place for the project to sprawl into unfocused EDA. |

---

### Q2 — Which behaviours signal risk, and how early?

| | |
|---|---|
| **Sub-questions** | Do churners listen less, or differently? Is the signal volume (days active) or quality (completion ratio)? How many days before expiry does the divergence become visible? |
| **What I expect to find** | Engagement declines before expiry, and completion ratio separates churners from renewers more cleanly than raw listening time. **If the divergence only appears in the final 3–5 days, behavioural targeting is operationally useless** and I will say so. |
| **Method** | Build expiry-anchored aggregates: 30-day window totals and rates, plus weekly aggregates across the 8 weeks before expiry. Compare churner vs. renewer distributions using **standardised mean differences**, not t-tests. Plot the weekly decay curve for both groups. |
| **Tool** | SQL window functions for the anchored aggregation; pandas for comparison; matplotlib for the decay curve; Tableau for the stakeholder version |
| **Why window functions** | Each subscriber has a *different* expiry date, so the window is per-row, not global. `ROW_NUMBER()` isolates the expiry-anchored transaction; range-based aggregation builds the window relative to it. This is the single most technically substantive piece of SQL in the project. |
| **Output** | Behavioural feature table; engagement decay chart (dashboard visual 4, deck slide 4) |
| **What counts as an answer** | A named signal, with the number of days before expiry at which it becomes detectable, and a statement of whether that lead time is operationally sufficient |
| **Pre-committed null finding** | If no signal is detectable **≥14 days before expiry**, I will report that behavioural targeting cannot be executed in time and recommend targeting on account attributes alone. This is a legitimate result, not a failure. |

---

### Q3 — What is a save worth, and what can we pay for one?

| | |
|---|---|
| **Sub-questions** | What is monthly ARPU by segment? What is expected remaining tenure? What is contribution-margin-adjusted CLV? What is the ceiling on cost per save and cost per contact? |
| **Method** | Normalise ARPU across plan lengths. Derive expected remaining months from segment renewal rate (assumption A9). Apply contribution margin (A8). Compute max cost per save (= CLV) and max cost per contact (= uplift × CLV). Build a sensitivity table across uplift 4% / 8% / 12% and margin 20% / 30% / 40%. |
| **Tool** | pandas |
| **Why not SQL** | This is a small derived table with chained arithmetic and scenario variation — clearer and more auditable in pandas than in nested SQL |
| **Output** | Unit economics table; sensitivity grid; deck slide 5 (the Finance slide) |
| **What counts as an answer** | A cost-per-save ceiling per target segment **that holds at the pessimistic corner of the sensitivity grid.** A recommendation that only works at 12% uplift and 40% margin is not a recommendation. |
| **Known weakness** | A9 (geometric survival) understates lifetime for long-tenured subscribers because renewal probability generally rises with tenure. Addressed by the Kaplan–Meier stretch; the size of the correction is reported rather than quietly absorbed. |

---

### Q4 — Does a risk score beat the rule we already have?

| | |
|---|---|
| **Sub-questions** | Can a model rank at-risk value better than the auto-renew rule at equal contact volume? By how much? Which features drive it? |
| **Method** | LightGBM binary classifier. Leakage audit before training (checklist below). Train/validation split. Class imbalance handled via `scale_pos_weight`. Evaluate via **decile lift** and **cumulative at-risk value captured vs. contacts**, compared head-to-head against the auto-renew rule and a random baseline at the contact cap (A5). Feature importance read as diagnosis, not as result. |
| **Tool** | LightGBM, scikit-learn |
| **Why a model at all** | The CRM team can contact ~5% of the cohort. Someone has to order the list. A model is the mechanism for ordering it — not the point of the project. |
| **Why not more models** | Comparing five algorithms would improve nothing about the decision. One model, evaluated against the incumbent rule, answers the question. |
| **Output** | Lift table; cumulative value-capture curve (dashboard visual 5, deck slide 6); `data/scored_sample.csv` for the Streamlit planner |
| **What counts as an answer** | Incremental at-risk value captured vs. the auto-renew rule, at the contact cap, as a number and a percentage |
| **Pre-committed decision rule** | **<10% incremental value → recommend keeping the simple rule** and redirecting the effort. This outcome is reported as a finding, not buried. |
| **AUC** | Computed once, reported in a footnote, with a sentence on why it is not the decision metric |

**Leakage audit checklist** *(run before training, recorded in the notebook)*
- [ ] No feature derived from `membership_expire_date` arithmetic
- [ ] No transaction dated at or after the expiry date
- [ ] No log data dated at or after the expiry date
- [ ] No feature encoding the renewal event itself (e.g. next transaction date)
- [ ] Per-feature correlation with the label reviewed; anything anomalously high investigated before use
- [ ] `is_cancel` on the expiry-anchored transaction reviewed specifically — cancellation is not churn, but it may partially encode the outcome

---

### Q5 — Is the auto-renew relationship causal?

| | |
|---|---|
| **Method** | Compare the crude auto-renew renewal-rate difference against the same difference computed **within** tenure × plan-length strata. Report how much of the gap survives stratification. Do the same for discount depth. |
| **Tool** | pandas; one two-proportion test on the stratified discount comparison |
| **Why only one test** | At this sample size, tests are near-uninformative. One is included to demonstrate the mechanics and, more importantly, to demonstrate knowing when they don't help. |
| **Output** | A written paragraph in the README and deck slide 7; `docs/04_experiment_design.md` |
| **What counts as an answer** | An honest statement that the data cannot separate the effect of auto-renew from the type of subscriber who enables it, plus a specified holdout test that could |
| **Prohibited output** | Any sentence implying that switching a subscriber to auto-renew would improve their retention |

---

## 3. Sequencing and dependencies

```
Q0 (audit + sample)  ──┬──> Q1 (segment rates) ──┐
                       │                          ├──> Q3 (unit economics) ──> Q4 (targeting) ──> Recommendation
                       └──> Q2 (behavioural)  ────┘                                ▲
                                                                                   │
                                                                     Q5 (confounding) runs alongside,
                                                                     constrains the wording of the recommendation
```

**Critical path:** Q0 → Q1 → Q3. These three produce the business answer on their own. Q2 and Q4 make the recommendation *operational* but the recommendation exists without them.

**Implication for time pressure:** if the schedule slips, cut Q4 before Q3, and cut the model before the unit economics. A project with a cost-per-save ceiling and no model is a complete piece of analysis. A project with a model and no unit economics is a Kaggle notebook.

---

## 4. Validation plan

Quality control is planned, not improvised.

| Check | When | Pass condition |
|---|---|---|
| Sample vs. population | After sampling | Churn rate within 0.5pp; plan and auto-renew mix within 2pp |
| Row count reconciliation | After SQLite load | Loaded rows = filtered source rows, per table |
| Orphan records | After load | Every labelled subscriber has ≥1 transaction; unmatched subscribers counted and explained |
| Duplicate transactions | After cleaning | Zero duplicate `(msno, transaction_date)` pairs remaining |
| Window integrity | After feature build | No negative window lengths; completion ratio within [0,1]; no window extending past expiry |
| Metric reconciliation | After analysis | Renewal rate computed in SQL matches the pandas figure to 3 decimal places |
| Dashboard reconciliation | After Tableau build | Every KPI card matches the notebook figure exactly |
| Tool reconciliation | After Streamlit build | Planner set to the auto-renew rule reproduces the notebook's figures exactly |
| Reproducibility | Before final commit | All notebooks run clean from a restarted kernel |

---

## 5. Analytical guardrails — what I will not do

Stated in advance, because each is a real temptation under time pressure.

- **No unfocused EDA.** Every chart must map to a question in Section 2. Distribution plots that inform no decision do not get produced.
- **No metric switching after results.** If the value-weighted rate produces an inconvenient story, the story changes, not the metric.
- **No model tuning past the decision threshold.** Once the Q4 criterion is resolved either way, modelling stops.
- **No causal language.** Enforced at the writing stage, checked in the final review pass.
- **No dropping the inconvenient finding.** If the simple rule wins, the simple rule wins, and it goes in the deck.
- **No decorative charts.** If I can't state the decision a visual informs, it is cut.
- **No silent exclusions.** Every filtered-out record is counted and explained.

---

## 6. Effort allocation

| Question | Planned hours | % of core |
|---|---|---|
| Framing (this document + brief) | 1.0 | 7% |
| Q0 — audit, sampling, database build | 3.0 | 20% |
| Q1 + Q2 — feature layer (SQL) | 2.0 | 13% |
| Q1 + Q3 — core analysis and unit economics | 2.5 | 17% |
| Q4 — risk scoring | 1.5 | 10% |
| Q5 — confounding | 0.25 | 2% |
| Dashboard | 1.5 | 10% |
| Deck | 1.5 | 10% |
| README and documentation | 2.0 | 13% |
| **Core total** | **15.0** | |
| Streamlit planner | 3.5 | |
| Survival analysis | 1.5 | |
| Experiment design doc | 1.0 | |
| **Full total** | **21.0** | |

Roughly **20% of the budget goes to framing and documentation before and after the analysis.** That ratio is deliberate — the analysis is worth nothing if the stakeholder can't act on it.

---

## 7. What changed and why

> Fill this in **as you go**, not retrospectively. One row per meaningful deviation from the plan above. The goal is not to have an empty table — it is to have an honest one.

| # | Date | Planned | What actually happened | Why it changed | Impact on the conclusion |
|---|---|---|---|---|---|
| *(example — delete before publishing)* | *2026-09-18* | *Use full `user_logs.csv` history for the 8-week window* | *Restricted history to 10 weeks pre-expiry* | *Streaming filter over the full file took 40 min per pass; 10 weeks covers the window plus buffer at a quarter of the runtime* | *None — the analysis window is 8 weeks* |
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |

---

## 8. Change history

| Version | Date | Change | Reason |
|---|---|---|---|
| 0.1 | [DATE] | Initial plan, pre-data-access | — |
| | | | |
