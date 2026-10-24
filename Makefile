PY ?= python3
export PYTHONPATH := src

.PHONY: install test data leakcheck train backtest forecast causes all clean

install:            ## editable install with test deps
	$(PY) -m pip install -e ".[dev]"

test:               ## engine + model tests (H0-H3 gate for engine-v0.1)
	$(PY) -m pytest -q

data:               ## synthetic data -> data/flashcrowd.duckdb (swap for PC1's extract later)
	$(PY) -m flashcrowd_model.synth

leakcheck:          ## H3-H6 gate: must print ALL PASSED before anything trains
	$(PY) -m flashcrowd_model.leakcheck

train: leakcheck    ## H6-H9: 1/2/3 h classifiers + size quantiles, walk-forward, calibrated
	$(PY) -m flashcrowd_model.train

backtest:           ## H9-H12: policies through the simulator, cost-weight sweep, Pareto, replay levels
	$(PY) -m flashcrowd_model.backtest

forecast:           ## H12-H16: live job for one issue hour, e.g. make forecast T=900
	$(PY) -m flashcrowd_model.forecast_job --issue-time $(T)

causes:             ## cause labels on/off comparison (heuristic stand-in; use --causes gemini with a key)
	$(PY) -m flashcrowd_model.train --causes heuristic
	$(PY) -m flashcrowd_model.backtest --model models/forecast_model_heuristic.pkl --suffix _heuristic

all: test data train backtest

clean:
	rm -rf out models data/*.duckdb
