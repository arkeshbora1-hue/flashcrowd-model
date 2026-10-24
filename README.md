# flashcrowd-model (PC3)

Predicts Wikipedia flash crowds 1–3 hours ahead from the edit stream, then pre-scales regional capacity.
Runs end to end on synthetic data today; swap in PC1's Snowflake extract when it lands (same three tables,
see `CONTRACTS.md` §3).

```bash
make install        # or: pip install -e ".[dev]"
make all            # tests -> synthetic data -> leak checks -> train -> backtest
make forecast T=900 # live forecast for issue hour 900
make causes         # cause-label on/off comparison
```

## Layout

```
CONTRACTS.md                      shared with PC1/PC2: time convention, surge definition, schemas, engine API
src/flashcrowd_engine/            the shared engine PC1 integrates (engine-v0.1)
  sim.py        hour-step capacity simulator: boot delay, launch limits, min/max fleet, billing
  forecasts.py  ForecastStore -> ForecastView: policies only ever see rows issued <= t
  policies.py   static, reactive (headroom), autopilot (forecast quantile), oracle (ceiling only)
  decision.py   newsvendor service level, quantile interpolation, multi-region budget allocation
  grading.py    costs, unserved %, SLA breaches, false launches, forecast metrics, lead time, Pareto
src/flashcrowd_model/
  synth.py        synthetic pages/edits/pageviews incl. bot bursts, edit wars, hard negatives, silent surges
  sql/labels.sql  SURGE_HOURS + SURGE_ONSETS views (portable DuckDB/Snowflake SQL)
  sql/features.sql decision grid + issue-time features + labels per horizon
  leakcheck.py    perturbation test + schema + split-embargo checks; training refuses if any fail
  train.py        LightGBM 1/2/3 h classifiers, isotonic calibration, size quantiles, walk-forward CV
  forecast_job.py live (filters raw data by availability first) and batch modes, same code path
  backtest.py     knob sweeps, calib-chosen operating points, cost-weight sweep, charts, replay levels
  causes.py       optional cause labels (heuristic stand-in + Gemini adapter)
tests/            31 tests: engine accounting/boot/limits/look-ahead, labels, leak checks, live==batch
```

## Results on synthetic data (seed 7, test window hours 759–1007)

Synthetic data is built to have a real edit-to-views lead, so these numbers show the pipeline works,
not what Wikipedia will give. Re-run on PC1's data before quoting anything.

| | Model | Persistence |
|---|---|---|
| PR-AUC, 1 h / 2 h / 3 h | 0.92 / 0.87 / 0.78 | 0.55 / 0.40 / 0.28 |

| Test window, default cost weight | Autopilot | Reactive | Static | Oracle (ceiling) |
|---|---|---|---|---|
| Total cost | 16,272 | 20,039 | 23,426 | 11,713 |
| Unserved demand | 1.43% | 2.91% | | |
| False launch rate | 39% | 43% | | |

- Autopilot saves 7–21% vs reactive across the cost-weight sweep (0.25× to 4× the unserved penalty).
- 84% of surge onsets are flagged; 64% early enough to beat the 1 h boot time; mean lead 1.3 h.
- Heuristic cause labels change nothing (16,266 vs 16,272), so they stay off unless Gemini beats that.
- Size quantiles are under-dispersed at the low end (q10 covers ~23%, should be 10%).

Outputs: `out/results.json` (with data fingerprint), `out/pareto.png`, `out/replay_L1.png`,
`out/replay_levels.json` (for PC1/PC2), `out/train_metrics.json`, `out/leakcheck.json`.
