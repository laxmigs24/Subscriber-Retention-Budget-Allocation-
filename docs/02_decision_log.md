# Decision Log

Dated record of choices made during the project, with rationale and cost. Newest at the bottom.

This file exists because the decisions are the analysis. A reader who disagrees with a conclusion should be able to find the choice that produced it.

---

**2026-09-17 — Dataset: KKBOX WSDM Cup 2018 churn challenge.**
*Rationale:* real subscriber data from a media business, with subscription transactions and daily listening logs, supporting both a retention question and genuine unit economics.
*Constraint:* distributed under Kaggle competition terms, so **no raw data is committed**. Reproducibility comes from scripts (`src/`, `notebooks/01`), not from committed files. See `data/README.md`.

**2026-09-17 — Archive extraction rewritten to use isolated temporary directories with a recursive file search.**
*Problem:* three of the five `_v2` archives nest their CSV under `data/churn_comp_refresh/` rather than at the archive root. A flat extraction produced `data/data/churn_comp_refresh/train_v2.csv`, and a shared output folder would have let `transactions_v2.csv.7z` overwrite `transactions.csv` **silently, with no error**.
*Fix:* each archive unpacks into its own temp directory, is checked for exactly one file, then renamed to the canonical name.
*Cost:* marginally slower extraction.

**2026-09-17 — Sampled 200,000 of the labelled subscribers (seed 42) rather than analysing the full cohort.**
*Rationale:* the full listening history is roughly 30 GB uncompressed; a validated sample keeps the whole project reproducible on one laptop.
*Validation gate, set before sampling:* sample churn rate within 0.5pp of population, plan-length and auto-renew mix within 2pp. **Gate passed.**
*Cost:* reduced precision on small city and payment-method segments.

**2026-09-17 — Streamed `user_logs.csv.7z` through a filter rather than extracting it.**
*Rationale:* ~30 GB uncompressed, of which ~97% is subscribers outside the sample. `7z e -so | python src/filter_logs.py` keeps only the sampled rows and never writes the full file to disk.
*Cost:* one non-restartable 20–40 minute pass.

**2026-09-17 — Age (`bd`) values outside 13–100 nulled with an `age_stated` flag, rather than dropping the rows.**
*Rationale:* the rows are otherwise valid subscribers, and *whether* age was stated is itself potentially informative.

**2026-09-18 — Dates stored as `INTEGER YYYYMMDD`, matching the source.**
*Rationale:* keeps the 30-day window join as an integer `BETWEEN`, which uses the `user_logs(msno, log_date)` index directly across ~12M rows.
*Cost:* date arithmetic needs conversion. Mitigated by computing both window boundaries once, in `sql/01`, and storing them as integers so `sql/02` and `sql/03` never parse a date.

**2026-09-18 — Expiry anchor defined as the latest transaction dated on or before the subscriber's March expiry, with the purchase row preferred over a same-day cancellation.**
*Rationale:* `transaction_date <= membership_expire_date` is a **leakage guard** — a transaction dated after expiry *is* the renewal, which is the outcome being predicted. Preferring the purchase row means plan and price describe what was actually bought.
*Cost:* cancellations are carried as flags rather than as the anchor; cancelling is not the same as churning.

**2026-09-18 — Transaction deduplication limited to exact duplicates across every field.**
*Rationale:* rows sharing `(msno, transaction_date)` but differing in price or cancellation status are legitimate same-day events. Collapsing them would silently discard cancellations.

**2026-09-19 — Weekly behavioural aggregates rebuilt on a subscriber × week spine.**
*Problem:* the original query created a row only where log rows existed, so a subscriber who went silent in a given week was **dropped from that week's average** rather than counted as zero. The resulting statistic was "active days among the active" — truncated by construction, and almost flat (~4.5 active days in all eight weeks for both churners and renewers). It read as "no behavioural signal exists". It was an artefact of the join.
*How it was caught:* the flatness was implausible, not because anything errored.
*Fix:* cross join every subscriber to weeks 1–8, left join the aggregates, coalesce volume metrics to zero. Quality metrics stay null, because "didn't listen" and "listened but skipped everything" are different states.
*Effect:* week-1 average fell from 4.58 to 3.20 — the v1 figure was inflated by ~43%.

**2026-09-19 — Subscribers with missing tenure reclassified from excluded to flagged.**
*Problem:* 22,747 subscribers (11.4%) have no matching `members_v3` record. Excluding them moved the cohort churn rate from 8.98% to 9.44% — 0.46pp, well past the 0.1pp neutrality gate set in `01_analysis_plan.md`. The excluded group churns at roughly 5.4%, so dropping it inflated the headline.
*Fix:* retained with `tenure_band = '99 unknown'`, excluded only from tenure-specific cuts.
*Result:* gate now passes at 0.009pp.

**2026-09-19 — Payment method dropped as a segmentation dimension.**
*Rationale:* of roughly 30 methods, most fall below the 500-subscriber floor set in the analysis plan. Several have fewer than 50.

**2026-09-19 — Discount test re-stratified on tenure alone.**
*Rationale:* tenure × plan left no stratum above the minimum size, so the test could not run at all.
*Outcome:* still untestable — discounting is too rare in this cohort. Reported as a non-result rather than dropped.

**2026-09-20 — `PRAGMA journal_mode = OFF` and `synchronous = OFF` during the SQLite load.**
*Rationale:* these trade crash-safety for speed. The database is fully rebuildable from the scripts in under an hour, so the trade is free. **This would be reckless on a production database.**

**2026-09-24 — Model restricted to the auto-renew-off population.**
*Rationale:* training on the full cohort would produce a model that mostly rediscovers `is_auto_renew` (41.2% vs 4.7% churn), score highly, and answer a question the business has already solved. The feature is asserted constant within the target group so this cannot happen quietly.
*Consequence:* this reframed the project. The question stopped being "does the rule target the wrong people" (it does not) and became "which 9,999 of the 23,452 it flags do we contact".

**2026-09-24 — CLV recomputed by plan band rather than tenure band. ⚠️ The most consequential correction in the project.**
*Problem:* `payment_plan_days` carried 41% of total model gain — more than all sixteen behavioural features combined. Investigating why revealed that within the target population, anything longer than a monthly plan churns at 76–86% against 29% for monthly, and these are not free-plan artefacts (median NT$447–1,788).
*Interpretation:* **a long-duration plan with auto-renew switched off is a prepaid block purchase, not a subscription.** When the time runs out the customer does not renew, and the product worked exactly as sold.
*Consequence:* a tenure-based CLV was the wrong denominator. Value per cycle spans roughly 12× across plan bands and renewal propensity moves with it. Total at-risk value fell from €140,551 to €69,586, and the model × CLV ranking changed materially.
*Open question:* the 8% uplift assumption is unlikely to hold equally across a save offer and a re-purchase prompt.

**2026-09-24 — Both model uplift thresholds fixed before any model was fitted.**
*Values:* the model must capture ≥10% more at-risk value than the best simple heuristic; behavioural features must add ≥5% over account-only.
*Rationale:* deciding what counts as success after seeing results is the most common failure in analytical work.
*Outcome:* model cleared its bar at +11.5%. **Behaviour missed its bar at +2.7%** — 0.2pp short, on a 7,036-row test set. Reported as "not worth the build cost", not as "useless", because the margin is within noise.

**2026-09-27 — Two dashboards retained: a published Tableau Public workbook and a self-contained D3 HTML page.**
*Rationale:* Tableau is the portfolio-relevant artefact; the HTML is a one-click live link. Both read from the same aggregate CSVs in `dashboard/data/`, so they cannot disagree.

**2026-09-30 — Repository restructured: chart-ready aggregates in `dashboard/data/`, analysis outputs in `outputs/`, raw and derived data gitignored.**
*Rationale:* a reviewer should be able to tell what feeds the dashboard and what is an analysis result without opening anything.
