# MLB Pitcher Strikeout Props – MVP

## Overview

An automated system for identifying positive expected-value (EV) bets on MLB pitcher strikeout Over/Under props. The MVP fetches live odds and historical pitcher/team data, builds features capturing recent form and matchup context, generates calibrated probabilities via XGBoost, computes EV, and selects disciplined bets using fractional Kelly sizing. Post-game, we track closing-line value (CLV) and actual outcomes to continuously validate edge and retrain models.

## What the MVP Does

1. **Fetch data** – Daily schedule, probable pitchers, team splits, Statcast aggregates, and live strikeout odds.
2. **Build features** – Pitcher form (K/9, CSW%, whiff%, pitch mix), opponent team K% vs hand, park factors, and market prices.
3. **Predict** – Calibrated classifier outputs P(Over | line, features).
4. **Compute EV** – Compare model probability to implied odds; filter by minimum EV threshold.
5. **Select bets** – Apply fractional Kelly sizing with caps; respect correlation/exposure limits.
6. **Track CLV** – Log bet prices vs closing prices; measure actual ROI and calibration metrics.

## Non-Goals for MVP

- **No lineup-weighted features** at v0 (team-level only; lineup integration is Phase 1.5).
- **No umpire or weather features** (deferred to Phase 2).
- **No scraping** outside published API terms-of-service.
- **No reinforcement learning** (bandit/RL requires simulator and logs; Phase 4).
- **Polymarket integration** deferred to optional separate module (Phase 5+).

## Repository Structure (Planned)

```
strikeouts/
├── docs/              # This planning pack
├── configs/           # YAML configs (API keys via env)
├── src/
│   ├── providers/     # MLB Stats, Statcast, Odds wrappers
│   ├── features/      # Feature engineering pipelines
│   ├── model/         # Train, calibrate, score
│   ├── selection/     # EV calc, Kelly sizing, filters
│   ├── execution/     # Nightly ETL, game-day loop
│   └── evaluation/    # CLV, Brier, calibration metrics
├── data/
│   ├── cache/         # JSON/Parquet provider caches
│   ├── outputs/       # Bets, results, logs
│   └── models/        # Trained model artifacts
├── tests/
└── notebooks/         # Exploratory analysis
```

## Target Performance

- **ROI**: 1–5% per bet (before fees/slippage), sustained over 100+ bets.
- **CLV**: Positive on average (our price better than closing).
- **Calibration**: Brier score < 0.24; well-behaved calibration curves.
- **Edge discipline**: Only bet when EV ≥ 3% and Kelly fraction > 0.

## Next Steps

1. Review all planning documents in [docs/](docs/).
2. Implement provider interfaces per [API_CONTRACTS.md](API_CONTRACTS.md).
3. Build nightly ETL and game-day execution loops per [EXECUTION_PLAN.md](EXECUTION_PLAN.md).
4. Train baseline models per [MODEL_SPEC.md](MODEL_SPEC.md).
5. Deploy guards and monitoring per [RISK_AND_GUARDS.md](RISK_AND_GUARDS.md).
6. Iterate on features and thresholds guided by [EVALUATION.md](EVALUATION.md) and [ROADMAP.md](ROADMAP.md).
