# FLASHCROWD PC3 commands. Store: FLASHCROWD_STORE=snowflake (real data) or duckdb:<file> (default: local synthetic).
PY ?= python3
export PYTHONPATH := src

.PHONY: install test synth train forecast batch backtest gemini sql all clean

# Install the engine + full model pipeline + test tools.
install:
	$(PY) -m pip install -e ".[model,gemini,dev]"

# Engine contract tests + pipeline tests (leak checks, SQL parity, end-to-end on small synthetic data).
test:
	$(PY) -m pytest -q

# Offline stand-in for PC1's Snowflake tables (same schema) -> data/flashcrowd_local.duckdb.
synth:
	$(PY) -m flashcrowd_model.synth

# Systematic training run: validate -> features -> leak gate -> search -> calibrate -> fit -> evaluate -> gate.
train:
	$(PY) -m flashcrowd_model.train

# Live forecast for now (cron every 15 min). Writes FORECASTS + REGION_FORECASTS.
forecast:
	$(PY) -m flashcrowd_model.forecast_job live

# Historical forecasts for a window, e.g. make batch START=2026-10-22 END=2026-10-23T23:00
batch:
	$(PY) -m flashcrowd_model.forecast_job batch --start $(START) --end $(END)

# Every policy through the shared engine on the test days; Pareto chart, headline, boss levels.
backtest:
	$(PY) -m flashcrowd_model.backtest

# Gemini cause labels for history, e.g. make gemini START=2026-10-17 END=2026-10-24T09:00
gemini:
	$(PY) -m flashcrowd_model.gemini_labeler --start $(START) --end $(END)

# Print the Snowflake feature SQL + SURGE_HOURS view for a window (for PC1 / the slide).
sql:
	$(PY) -m flashcrowd_model.sql_features --dialect snowflake --start $(START) --end $(END)

all: test synth train backtest

clean:
	rm -rf artifacts data/*.duckdb
