# PC1 ↔ PC3 ↔ PC2 integration

Contracts: `CONTRACTS.md` (roadmap §3, verbatim). Everything below is generated or tested by this repo.

## 0. Connection (same as PC1's `sf.py`)

PC3 connects with PC1's key-pair helper, vendored as `flashcrowd_model/sf.py`. One fix for PC1's copy: `_file_` must be `__file__`, otherwise it raises `NameError` on import.

```
.env                       FLASHCROWD_STORE=snowflake, SNOWFLAKE_ACCOUNT / USER / ROLE / WAREHOUSE / DATABASE / SCHEMA
secrets/fc_pc3_rsa_key.p8  PC3's private key (git-ignored)
```

## 1. Snowflake (`FLASHCROWD.CORE`)

| Object | PC3 reads | PC3 writes | Notes |
|---|---|---|---|
| `EDITS` | yes | – | namespace 0, 10 wikis; `is_revert` recomputed from `comment` if NULL |
| `PAGEVIEWS_HOURLY` | yes | – | `published_at` must be the dump's Last-Modified; `flashcrowd check` fails if its median lag isn't 30–360 min |
| `MAIN_PAGE_EVENTS`, `COUNTRY_SHARE`, `INFRA_MEASUREMENTS` | yes | – | the last two are optional (defaults are used) |
| `CAUSE_LABELS` | yes | **yes** | Gemini labeller, idempotent per window |
| `FORECASTS` | – | **yes** | every 15 min: top 300 titles × 3 horizons; `top_reasons` VARIANT |
| `REGION_FORECASTS` | – | **yes** | every 15 min: 3 regions × 3 target hours |
| `SURGE_HOURS` (view) | – | **yes, once** | `flashcrowd setup`; PC1's scorecard reads it |

## 2. Game sessions (PC1 `sessions.py` / `ws.py`)

```bash
pip install "git+https://github.com/<ORG>/flashcrowd-model.git@engine-v0.3"     # numpy only
```

```python
from flashcrowd_engine import GameSession

s = GameSession.from_level_file(f"levels/{level_id}.json", session_id=sid)   # files from artifacts/handoff/pc1/levels/
s.info()                     # POST /sessions                -> {"session_id","start","end","constants":{"C","B","SCALE"}}
s.action(body)               # POST /sessions/{id}/action    -> {"ok":true} | {"ok":false,"error":"bad_delta"|"min_servers"|...}
msg = s.tick()               # every sim minute -> WS message: {"type":"tick",...} and finally {"type":"end","review_url":...}
s.review()                   # GET /sessions/{id}/review     -> grades + surges with brilliant/on_time/late/missed/overspent
s.reasons("TYO")             # GET /agent/reasons?region=TYO -> {"region","action","reasons","p_surge"}
```

The tick contains `players.you.regions` (running, booting, demand_rps, cap_rps, dropped_rps), the scores of all four players, `radar` (top 8 article forecasts issued ≤ now) and `alerts` (first time a title reaches 0.6). Speed, pause and the WebSocket loop stay in PC1's code: call `tick()` as often as the chosen speed needs.

Each level package is self-contained: regional demand, measured constants, the forecasts issued around the level, and the scheduled plan. No Snowflake query is needed at session start. `GET /levels` is `artifacts/handoff/pc1/levels.json`, served as-is.

To build demand live from Snowflake instead, the lower-level pieces are still there: `Simulator`, `ForecastBook`, `region_minute_demand`, and the `Autopilot`, `Reactive` and `Scheduled` policies.

## 3. Live scorecard

```python
from flashcrowd_model.scorecard import build
build(store, since="2026-10-24T14:00", threshold=bundle.threshold)   # CONTRACTS §3.5 scorecard object
```

`flashcrowd scorecard 2026-10-24T14:00` writes the same object to `artifacts/live/scorecard.json`. A forecast is only scored once every hour in its window has been published. The rule is the same as the model's and the `SURGE_HOURS` view's.

## 4. PC2 (frontend)

`artifacts/handoff/pc2/mocks/` holds the seven `?mock=1` files: `levels.json`, `session.json`, `ticks.jsonl` (361 messages), `review.json`, `forecasts.json`, `scorecard.json` and `reasons.json`. They are produced by playing a real level through the engine, so every number is consistent with every other. `artifacts/handoff/pc2/charts/` holds the PNGs for "How it works".

## 5. Jobs on `fc-core` (PC3)

```cron
*/15 * * * *  cd ~/flashcrowd-model && .venv/bin/flashcrowd live      >> ~/logs/forecast.log 2>&1
*/15 * * * *  cd ~/flashcrowd-model && .venv/bin/flashcrowd scorecard 2026-10-24T13:00 >> ~/logs/scorecard.log 2>&1
40 3 * * *    cd ~/flashcrowd-model && .venv/bin/flashcrowd train     >> ~/logs/train.log 2>&1
```

Set the scorecard's date to when live forecasting started: 13:00 UTC is 14:00 BST, the event start.

## 6. Known risk: smooth regional demand

Whole-region demand ramps slowly and boot times are minutes, so no policy drops requests. The headline becomes **server-hours saved at equal service**. The review's regional surge rule (needed servers ≥ 1.5× the trailing 3 h median, at least +2 servers) finds few surges.

`flashcrowd export` keeps 1.5× for any level where it finds a surge. Otherwise it uses the biggest jump the level really contains (at least 1.1× and +1 server), and writes the value into the level file and the handoff README.
