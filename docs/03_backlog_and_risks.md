# Backlog and Risks

What I would do next, in priority order, and what could be wrong with what exists.

---

## Backlog

Ranked by the value of the answer against the cost of getting it.

### 1. Holdout test to establish causality — *highest value, cannot be substituted*

Every figure in this project is observational. The analysis identifies which subscribers are at risk; it cannot say the campaign changes their behaviour.

**Design:** withhold contact from a random 10% of the target list. Primary metric: 30-day renewal rate. Guardrail: complaint and unsubscribe rate. Randomisation unit: subscriber. Duration: one expiry cohort, roughly four weeks.

**Why it matters more than anything else here:** the 8% save-rate assumption drives the entire ROI calculation and has never been measured. A single cohort converts the whole analysis from an association into a number Finance can rely on. Nothing else in this backlog changes the recommendation as much.

**Effort:** one page to specify, four weeks to run.

### 2. Separate uplift assumptions for the two purchase behaviours

The analysis found that the flagged population contains subscribers (monthly, 29% churn) and prepaid block buyers (76–86% churn). A single 8% uplift is almost certainly wrong across both — a save offer and a re-purchase prompt are different interventions with different response rates.

Fold into the holdout test as a second treatment arm rather than running separately.

### 3. Out-of-time validation on the February cohort

`train.csv` holds the February 2017 expiry cohort. Training on February and validating on March would test whether the model's edge generalises across months, or depends on one month's promotional mix — a live concern given that `payment_plan_days` carries 41% of model gain.

**Effort:** 2–3 hours, reusing the existing pipeline.

### 4. Survival analysis to replace the geometric lifetime assumption

Expected remaining tenure currently comes from `1 / (1 − renewal rate)`, which assumes a constant renewal probability. Renewal probability generally rises with tenure, so this is **conservative** — it understates long-tenured subscribers.

A Kaplan-Meier estimate by segment would replace the weakest input to CLV. Reporting how much the recommendation moves when the weakest assumption is fixed is more interesting than the estimate itself.

**Effort:** 1.5 hours with `lifelines`.

### 5. Streamlit campaign planner

A one-screen tool reading the scored subscriber list: sliders for contact budget and cost per contact, a targeting-rule dropdown, returning contacts, at-risk value reached, expected saves and breakeven. Lets a CRM manager change an assumption in a planning meeting and watch the recommendation move — which the dashboard deliberately does not do.

**Effort:** 3–4 hours.

### 6. Multi-cohort seasonality view

One month cannot distinguish a structural pattern from a March one. Several cohorts would show whether the 41% auto-renew-off churn rate is stable.

**Effort:** moderate — requires re-running the pipeline per cohort.

---

## Risks

Things that could make the conclusions wrong, roughly in order of how much they would change them.

### Assumption risk

**The 8% uplift is invented.** It drives every ROI figure. The recommendation holds down to 4% (sensitivity-tested), but below that the campaign stops paying back at any targeting quality. **Mitigation:** item 1 above. Until then, treat ROI figures as conditional.

**The 30% contribution margin is invented.** Streaming content royalties consume most of subscription revenue, but the exact figure is not public. CLV scales linearly with it, so a 20% margin would cut the cost-per-save ceiling by a third. **Mitigation:** surfaced prominently rather than buried; tested at 20 / 30 / 40%.

**Contact cost is assumed at NT$12.** The best method breaks even at NT$15.32 — 28% headroom. If real cost exceeds NT$15, the campaign fails regardless of targeting.

### Generalisation risk

**One cohort, one month.** March 2017 only. No seasonality view, and no way to tell whether the promotional mix that drives the plan-band effect repeats.

**`payment_plan_days` carries 41% of model gain.** The model's edge depends heavily on one feature reflecting a concentrated group of prepaid buyers. If next month's promotional mix differs, performance may not hold. **Mitigation:** item 3 above.

**2017 data.** Findings are methodological rather than current commercial intelligence.

### Statistical risk

**Behaviour missed its threshold by 0.2pp** (2.7% against a 5% bar) on a 7,036-row test set. That is within noise. The recommendation is "not worth the build cost", not "useless", and a larger test set could flip it.

**No confidence intervals on the targeting comparison.** Precision figures are point estimates from one split. A repeated-split or bootstrap estimate would show how stable the model-versus-heuristic gap is.

**Sampling.** 200,000 of the labelled cohort. Validated to 0.009pp on churn rate, but small segments carry wide intervals and several were excluded on that basis.

### Data risk

**11.4% of subscribers have no member record**, so tenure is unknown for them. They are retained and banded rather than excluded, but tenure-specific findings exclude them.

**`01 weekly or less` is effectively a free-trial bucket** — 136 subscribers, CLV €0.05, 88% free plans. It sits at the bottom of every ranking and carries no signal. Treated as noise.

**No causal identification anywhere.** Auto-renew status is strongly associated with renewal, and two thirds of that gap survives stratification by tenure and plan — but subscribers *choose* auto-renew. Nothing here supports the claim that switching someone to auto-renew would improve their retention, and that claim is not made.

### Scope risk

**No acquisition or channel data exists in this dataset.** The analysis cannot speak to CAC, ROAS or channel mix. The same framework applies to acquisition — swap the CLV ceiling for a CAC ceiling and the targeting logic is identical — but that is an assertion, not a result.

---

## Explicitly not planned

- Production scoring pipeline or model monitoring — the decision is "who to contact next month", not "how to run a model in production". Revisit only if the holdout test confirms the uplift assumption.
- Behavioural scoring infrastructure — the analysis recommends against it (2.7% incremental value).
- Further model tuning — the pre-committed threshold was resolved; additional accuracy changes no decision.
