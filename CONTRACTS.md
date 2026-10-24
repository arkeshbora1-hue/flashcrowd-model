# FLASHCROWD contracts (v0.1)

This file is the single source of truth shared by PC1 (data + integration), PC2 (UI) and PC3 (model + engine).
Anything here changes only with a version bump that matches an `engine-vX.Y` git tag.

## 1. Time convention

- Unit: **integer hours since dataset start** (`hour`), UTC. Real time = `EPOCH0 + hour` (EPOCH0 lives in
  `flashcrowd_model/config.py`; PC1 sets it from the Snowflake extract).
- Hour bucket `h` covers `[h, h+1)`.
- **Issue time** `t` is the start of bucket `t`. A forecast issued at `t` may use:
  - edits with `ts < t` (edit buckets `<= t-1`);
  - pageviews for buckets `<= t - 1 - PAGEVIEW_LAG` (default lag 1 h, so `<= t-2`). Public pageview
    files appear after the hour closes; using hour `t-1` at `t` is a leak.
  - the operator's own served traffic for buckets `<= t-1` (it is our traffic, known in real time).
- **Horizon** `k in {1,2,3}`: forecast issued at `t` for bucket `t + k - 1`.
  Servers requested at `t` with boot time `B` hours serve from bucket `t + B`, so the autopilot reads horizon `B + 1`.

## 2. Surge definition

For page `p` and bucket `h`:

```
baseline_7d(p, h) = median(views(p, h-168 .. h-1))          -- excludes h itself
surge(p, h)       = views(p, h) >= max(SURGE_K * baseline_7d, baseline_7d + SURGE_MIN_ABS)
```

Defaults: `SURGE_K = 3`, `SURGE_MIN_ABS = 500` views/hour. The first 168 h are burn-in (no labels).
View: `SURGE_HOURS` (see `sql/labels.sql`).

## 3. Raw tables (PC1 → PC3)

| table | columns |
|---|---|
| `pages` | `page_id` INT, `qid` TEXT, `lang` TEXT, `region` TEXT |
| `edits` | `ts` DOUBLE (hours), `page_id` INT, `qid` TEXT, `lang` TEXT, `editor` TEXT, `is_bot` BOOL |
| `pageviews` | `hour` INT, `page_id` INT, `views` INT (user agent only, no spiders) |

Bot edits are kept in `edits` and flagged; features count them separately and never as human signal.

## 4. Forecast outputs (PC3 → PC1/PC2)

`article_forecasts` (one row per page × issue time × horizon):

| column | type | meaning |
|---|---|---|
| `page_id`, `qid`, `lang`, `region` | | page identity |
| `issued_at` | INT | issue hour `t` |
| `target_hour` | INT | `t + horizon - 1` (always `>= issued_at`) |
| `horizon` | INT | 1, 2 or 3 |
| `p_surge` | DOUBLE | calibrated probability of `surge(p, target_hour)` |
| `base_views` | DOUBLE | seasonal baseline for the target hour |
| `size_q10`, `size_q50`, `size_q90` | DOUBLE | views at target hour **if** it surges |
| `cause_label` | TEXT NULL | optional Gemini cause label (only issue-time inputs) |
| `model_version` | TEXT | e.g. `fc-2026-10-24-a` |

`region_forecasts` (one row per region × issue time × horizon): `region`, `issued_at`, `target_hour`, `horizon`,
`p_surge` (probability regional demand exceeds its own surge threshold), `q10`, `q50`, `q90`, `q99`
(regional demand in views/hour), `model_version`.

Invariant checked by `forecast_job`: `target_hour >= issued_at` and every input row had `available_at <= issued_at`.

## 5. Engine API (`flashcrowd_engine`, PC1 integrates this)

```python
from flashcrowd_engine import SimConfig, Simulator, ForecastStore
from flashcrowd_engine.policies import ReactivePolicy, StaticPolicy, AutopilotPolicy
from flashcrowd_engine.grading import grade

store = ForecastStore(region_forecasts_df)             # schema above
sim = Simulator(SimConfig(boot_steps=1))
res = sim.run(demand=np.array([...]), policy=AutopilotPolicy(tau=0.9), forecasts=store.for_region("eu-west"),
              start_hour=720)
print(grade(res))
```

- One simulator step = one hour bucket. Demand in views/hour; capacity = `servers * capacity_per_server`.
- Order inside step `t`: promote booted servers → policy decides from an `Observation` → apply scaling limits →
  serve demand → bill active + booting servers.
- A policy only ever sees `Observation.demand_history` (buckets `< t`) and `Observation.forecasts`, a
  `ForecastView` built from rows with `issued_at <= t`. Asking for anything later raises `LookAheadError`.

## 6. Replay levels (PC3 → PC1/PC2)

`out/replay_levels.json`: list of `{level_id, region, start_hour, end_hour, peak_hour, peak_views, note}`, picked
only from the held-out test window.

## 7. Versioning

| tag | contents |
|---|---|
| `engine-v0.1` | sim, policies, decision, grading + tests; schemas above frozen |
| `engine-v0.2` | backtest + Pareto sweep stable |
| `engine-v1.0` | live `forecast_job`, replay levels, results reproducible from seed |
