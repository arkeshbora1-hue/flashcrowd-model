# flashcrowd-model (PC3)

This repo holds PC3's whole share of FLASHCROWD:
- the shared simulator engine (`flashcrowd_engine`, which PC1 imports)
- labels, and features in both Python and Snowflake SQL
- systematic model training
- the newsvendor decision engine
- the backtest and Pareto chart
- the live forecast job and the Gemini cause labeller
- slide and Devpost material

It follows `FLASHCROWD_ROADMAP.md`; `CONTRACTS.md` is §3 copied verbatim.

```bash
make install            # engine (numpy only) + model pipeline + tests
make test               # 34 tests: engine contract, leak checks, SQL parity, end-to-end
make synth              # offline stand-in for PC1's tables (same schema) -> data/flashcrowd_local.duckdb
make train              # systematic training run -> artifacts/runs/<run_id>/ + champion in artifacts/model.pkl
make backtest           # every policy through the engine on the held-out days, Pareto chart, boss levels
make forecast           # live forecast now (cron every 15 min)
```

To run on the real data, set `FLASHCROWD_STORE=snowflake` and the `SNOWFLAKE_*` variables (see `.env.example`). Run the same commands; nothing else changes. PC1's guide is `INTEGRATION.md`.

## On the real data (PC1's Snowflake)

```bash
cp .env.example .env                 # account, user FC_PC3, role, warehouse, database, schema are pre-filled
# put PC1's key at secrets/fc_pc3_rsa_key.p8
flashcrowd bootstrap                 # check -> setup -> train -> backtest -> export -> first live forecast
```

`bootstrap` stops at the first problem and says what to ask PC1 for. When it finishes:
- send `artifacts/handoff/pc1/` to PC1 (level packages for `GameSession`, and `levels.json`);
- send `artifacts/handoff/pc2/` to PC2 (the seven mock files and the charts);
- schedule `flashcrowd live` every 15 minutes (see `INTEGRATION.md` §5).

## Run it in an IDE

**In the browser (GitHub Codespaces):** push the repo to GitHub, then choose **Code → Codespaces → Create codespace**. You get full VS Code with a terminal; it installs everything and builds the local synthetic data. Add `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD` and `GEMINI_API_KEY` as Codespaces secrets when asked.

**On your computer (VS Code):**
```bash
git clone <repo> && cd flashcrowd-model
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -e ".[model,gemini,dev]"
cp .env.example .env                                    # fill in Snowflake + Gemini
code .
```

**The terminal menu.** Run `flashcrowd` in any terminal for a menu of every step, or `flashcrowd <step>` directly: `doctor`, `status`, `test`, `synth`, `train`, `backtest`, `live`, `batch START END`, `gemini START END`, `sql START END`, `store local|snowflake`. The same steps appear in VS Code under **Terminal → Run Task** (Ctrl/Cmd+Shift+B opens the menu). Under **Run and Debug** (F5), each step runs with breakpoints.

## Pipeline

```
Snowflake EDITS / PAGEVIEWS_HOURLY / MAIN_PAGE_EVENTS / COUNTRY_SHARE / CAUSE_LABELS / INFRA_MEASUREMENTS
  │  data.load_window      portable SQL; heavy aggregation in the warehouse; candidate titles pushed down
  ▼
preprocess (data.py)      titles, wikis, ns 0, revert flags, de-dup, desktop+mobile summed, hour -> published_at
  ▼
validate (validate.py)    PASS / WARN / FAIL — a wrong published_at, missing dumps or too few days stop the run
  ▼
grid + features           features.py (Python, canonical) == sql_features.py (Snowflake SQL, parity-tested)
  │                       every value as of t: edits ts <= t, views only from dumps published <= t
  ▼
labels (labels.py)        surge = views >= max(5 x same-hour 7-day median, floor); y_h = onset in (t, t+h]
  ▼
leak gate (leakcheck.py)  provenance <= t on every row + perturbation test + schema + split embargo
  ▼
train (train.py)          rolling-origin CV search -> isotonic on pooled OOF -> final fit -> test once -> gate
  ▼
forecast_job.py           live / batch -> post-process -> FORECASTS + REGION_FORECASTS (+ JSON for the API)
  ▼
flashcrowd_engine         minute simulator, reactive / scheduled / persistence / oracle, newsvendor autopilot, review
  ▼
backtest.py + charts.py   Pareto, headline, reliability, lead time, feature importance, surge example, boss levels
```

## Systematic training

`configs/train.json` holds every choice: the split, the search space, the calibration settings, the validation thresholds and the promotion gate. Each run:

1. Gets its own folder: `artifacts/runs/<run_id>/` with `config.json`, `data_report.json`, `leakcheck.json`, `cv.json`, `metrics.json`, `model.pkl` and `charts/`.
2. Picks hyperparameters on **rolling-origin CV**. Each fold validates on one day before the test days and trains on everything earlier. A 3 h embargo before every held-out day stops label windows from crossing into it. The roadmap's default settings (`is_unbalance=True`, 31 leaves) are always one of the candidates, so the report shows what they scored.
3. Calibrates with isotonic regression on the **pooled out-of-fold** predictions. That gives 3× the positives of a single validation day.
4. Touches the test days exactly once.
5. Is promoted to champion only if it beats persistence by ≥ 0.05 PR-AUC. It must also be no worse than the current champion, re-scored on the **same** new test days. `--force` overrides the gate.

`artifacts/registry.json` lists every run. `artifacts/model.pkl` is always the champion, and it is what the forecast job loads.

## Results on synthetic data (seed 7, held-out 15–16 Oct)

The synthetic data proves the pipeline works, not what Wikipedia will give. Re-run on PC1's data before quoting anything.

| | Model | Persistence |
|---|---|---|
| PR-AUC, onset within 1 / 2 / 3 h | 0.34 / 0.26 / 0.27 | 0.00 / 0.00 / 0.01 |
| Onsets caught (33 in the test days) | 76%, median lead 1 h | 0% |
| Chosen settings vs the roadmap's default (CV PR-AUC, 2 h) | 0.39 | 0.13 with `is_unbalance=True` |

| Test days | Served | Server-hours |
|---|---|---|
| Autopilot κ=5 | 100% | 792 |
| Scheduled | 100% | 802 |
| Reactive | 100% | 1,047 |
| Oracle (ceiling) | 100% | 564 |

Headline: **serving as much as the reactive autoscaler, FLASHCROWD uses 24% fewer server-hours.** Scheduled is nearly as good on these days, and the slides should say so. See `INTEGRATION.md` §6 for why no policy drops requests here.

## Layout

```
CONTRACTS.md  INTEGRATION.md  configs/train.json  .env.example  Makefile  slides/
src/flashcrowd_engine/  constants  demand  forecasts  sim  policies  decision  grading      (numpy only)
src/flashcrowd_model/   config  store  data  validate  labels  features  sql_features  leakcheck
                        train  registry  model  evaluate  explain  regions  postprocess
                        forecast_job  gemini_labeler  backtest  charts  synth
src/flashcrowd_model/sql/ddl_snowflake.sql   (roadmap §3.2 verbatim)
tests/  test_engine.py  test_pipeline.py
```

Every block of code is preceded by a `#` comment saying what it does and why.
