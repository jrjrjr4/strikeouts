# Roadmap

This document outlines the phased development plan from MVP through advanced features.

---

## MVP (Weeks 1–2): Core System

**Goal**: End-to-end pipeline with team-level features, baseline model, and manual bet execution.

### Deliverables

1. **Data Providers** (implement per [API_CONTRACTS.md](API_CONTRACTS.md)):
   - `MlbStatsProvider`: schedule, probables, boxscore, team splits.
   - `StatcastProvider`: pitcher game logs, rolling aggregates (via pybaseball).
   - `OddsProvider`: strikeout O/U lines and prices.

2. **Nightly ETL**:
   - Fetch recent Statcast data for active pitchers.
   - Compute rolling windows (N=5): K/9, CSW%, whiff%, chase%, zone%, pitch mix, delta_csw_3.
   - Refresh team batting splits (K% vs LHP/RHP).
   - Cache to JSON; retain 60 days.

3. **Feature Engineering**:
   - **Pitcher form**: k9, csw_pct, whiff_pct, chase_pct, zone_pct, pitch mix, delta_csw_3, days_rest.
   - **Opponent**: `team_k_vs_hand` (team-level; no lineup weighting yet).
   - **Context**: home_away_flag, park_k_factor (static lookup).
   - **Market**: line_decimal, price_over_decimal, price_under_decimal.

4. **Model**:
   - Train logistic regression (L2) + Platt calibration.
   - Train XGBoost + isotonic calibration.
   - Compare on test set (Brier, log-loss, calibration curves).
   - Deploy better-performing model.

5. **Bet Selection**:
   - EV ≥ 3%, fractional Kelly (λ=0.2, max 2% bankroll).
   - Caps: per-bet ($200), per-slate ($1500), same-game (1.5×).
   - Filters: spread ≤ 5%, odds ≥ 1.4, no duplicate markets.

6. **Game-Day Loop**:
   - T-6h: fetch schedule/probables/odds; build preliminary features; watchlist.
   - T-30m: refresh odds; finalize features (team baseline, no lineups); score; select bets; log tickets.
   - Post-game: fetch closing odds, actual Ks; compute CLV, ROI; write results.

7. **Monitoring**:
   - Daily logs: bets placed, CLV, ROI, Brier.
   - Kill-switches: daily loss limit (5%), CLV < -20 bps for 3 days.

### Success Criteria

- [ ] Pipeline runs end-to-end without errors.
- [ ] 100 bets placed over 2–3 weeks (real or paper trading).
- [ ] Average CLV > 0 (positive closing line value).
- [ ] Brier score < 0.24 on production bets.
- [ ] No kill-switch triggers (model stable).

### Non-Goals for MVP

- ❌ Lineup-weighted features (Phase 1.5).
- ❌ Umpire or weather features (Phase 2).
- ❌ Alt-line pricing (Phase 2).
- ❌ Two-tower or neural net models (Phase 3).
- ❌ Contextual bandit or RL (Phase 4).
- ❌ Polymarket integration (Phase 5+).

---

## Phase 1.5 (Weeks 3–4): Lineup-Weighted Features

**Goal**: Improve opponent modeling by using confirmed batting lineups.

### Enhancements

1. **Fetch Confirmed Lineups**:
   - At T-30m: `get_boxscore(gamePk)` → extract batting order (player IDs 1–9).
   - Fallback: use team baseline if lineup unavailable.

2. **Batter Splits**:
   - Fetch batter K% vs pitcher hand (LHP/RHP) from MLB Stats API.
   - Cache batter splits (season-to-date or rolling last-30 days).

3. **New Features**:
   - `lineup_weighted_k_vs_hand = Σ(batter_k_vs_hand[i] × expected_pa_weight[i])` for i=1–9.
   - `expected_pa_weights = [4.8, 4.7, 4.6, 4.5, 4.4, 4.3, 4.1, 3.9, 3.7]` (by batting order).
   - `lineup_confirmed` flag (binary): 1 if lineup used, 0 if team baseline.

4. **Model Retraining**:
   - Add lineup features to training data (where available).
   - Retrain XGBoost; compare to baseline model.
   - **A/B test**: Run lineup model vs team-baseline model for 100 bets; compare CLV and Brier.

5. **Expected Impact**:
   - Brier improvement: -0.01 to -0.02 (e.g., 0.23 → 0.21).
   - CLV improvement: +20 to +50 bps (better accuracy on matchup-dependent games).

### Success Criteria

- [ ] Lineup features integrated; fallback to team baseline working.
- [ ] A/B test shows lineup model CLV ≥ baseline model CLV.
- [ ] Brier score ≤ 0.22 on bets with confirmed lineups.

---

## Phase 2 (Weeks 5–8): Umpire, Weather, Alt-Lines

**Goal**: Add context features; expand to multiple lines per pitcher.

### Enhancements

1. **Umpire Features**:
   - Fetch umpire assignment from MLB Stats API (available T-3h usually).
   - Join to historical umpire stats table (K% per game vs league average).
   - Add `ump_k_factor` (0.95–1.05); fallback to 1.0 if unknown.

2. **Weather Features**:
   - Fetch weather for stadium at T-3h (temp, humidity, wind speed/direction).
   - Compute `weather_run_env_factor` (regression on historical data: hot/dry/wind-out → lower Ks).
   - Fallback: 1.0 (neutral).

3. **Alt-Line Pricing**:
   - Fetch multiple lines per pitcher (e.g., 5.5, 6.5, 7.5).
   - Score each line separately; select best EV (respecting per-market cap: max 1 line per pitcher).
   - **Future**: Predict full K distribution (Poisson/NegBin) to price all lines simultaneously.

4. **Model Retraining**:
   - Add umpire and weather features.
   - Retrain; validate that features improve Brier (expect marginal +0.005–0.01 improvement).

5. **Uncertainty Quantification**:
   - Train ensemble of K=10 models (bootstrap samples).
   - Compute `std(p_over)` across ensemble; flag high-uncertainty bets (std > 0.05).
   - Reduce stake on uncertain bets: `stake_adjusted = stake × max(0.5, 1 - 2 × std)`.

### Success Criteria

- [ ] Umpire and weather features integrated; fallback working.
- [ ] Alt-line selection working (max 1 line per pitcher).
- [ ] Brier score ≤ 0.21 on production bets.
- [ ] Uncertainty-adjusted sizing reduces drawdown by 10–20%.

---

## Phase 3 (Weeks 9–16): Two-Tower Matchup Model

**Goal**: Explicitly model pitcher–opponent interactions via neural network.

### Enhancements

1. **Two-Tower Architecture**:
   - **Pitcher tower**: Dense layers on pitcher features → 16-dim embedding.
   - **Opponent tower**: Dense layers on lineup/team features → 16-dim embedding.
   - **Head**: Concatenate embeddings + line + market features → Dense → sigmoid → p_over.

2. **Training**:
   - TensorFlow/PyTorch implementation.
   - Binary cross-entropy loss; Adam optimizer; batch size 64.
   - Early stopping on validation Brier.

3. **Calibration**:
   - Post-hoc Platt or isotonic regression.
   - Compare calibration curves to XGBoost baseline.

4. **Validation**:
   - Test Brier, ECE on holdout.
   - **Shadow deployment**: Run two-tower + XGBoost in parallel for 2 weeks; log predictions from both; compare CLV and Brier.
   - Deploy two-tower if CLV ≥ baseline and Brier ≤ baseline.

5. **Feature Store Refactor**:
   - Move to columnar storage (Parquet) for faster training data loading.
   - Implement feature versioning (schema evolution).

### Success Criteria

- [ ] Two-tower model trained; calibrated.
- [ ] Shadow deployment shows two-tower CLV ≥ XGBoost CLV.
- [ ] Brier score ≤ 0.20 (stretch goal).

---

## Phase 4 (Weeks 17–24): Contextual Bandit for Sizing/Timing

**Goal**: Learn optimal bet sizing and timing via online learning.

### Prerequisites

- ≥500 historical bets logged (with features, stakes, CLV, ROI).
- Simulator built (replay historical odds sequences; simulate bet outcomes).

### Enhancements

1. **Contextual Bandit Formulation**:
   - **State**: Current features (pitcher form, opponent, line, market, time-to-game).
   - **Actions**: Discrete bet sizes (0%, 0.5%, 1%, 1.5%, 2% of bankroll) or timing (bet now vs wait 1h).
   - **Reward**: CLV (immediate) or ROI (delayed).

2. **Algorithms**:
   - **Thompson Sampling**: Bayesian bandit; sample action from posterior over EV.
   - **LinUCB**: Linear upper confidence bound; balance exploration/exploitation.

3. **Offline Evaluation**:
   - Use logged historical bets (off-policy evaluation with inverse propensity weighting).
   - Compare bandit policy vs fixed Kelly policy on replay.

4. **Online Deployment**:
   - Start with ε-greedy (90% bandit policy, 10% random exploration).
   - Monitor CLV and ROI; compare to baseline (fixed Kelly).
   - Gradually reduce ε to 5% as policy converges.

5. **RL Extension** (optional):
   - Sequential decision-making: when to bet during the day as odds shift.
   - Q-learning or policy gradient (requires simulator with odds drift model).

### Success Criteria

- [ ] Bandit policy improves CLV by +20 bps vs fixed Kelly (validated in simulator).
- [ ] No increase in drawdown vs baseline.
- [ ] Deployed with ε=10% exploration; monitored for 4 weeks.

---

## Phase 5+ (Months 6–12): Advanced Features & Polymarket

**Goal**: Expand feature set; explore alternative venues.

### Potential Enhancements

1. **Polymarket Integration**:
   - Fetch odds from Polymarket CLOB API.
   - Compare to sportsbook odds; identify arbitrage opportunities (cross-venue).
   - **Use cases**:
     - Hedge sportsbook positions if Polymarket spread favorable.
     - Exploit rule/news edges (e.g., pitcher scratch announced; Polymarket slow to update).
   - **Risks**: Resolution disputes, lower liquidity, gas fees (if on-chain settlement).
   - **Module**: Separate pipeline; do not mix with core sportsbook bets (different risk profiles).

2. **Pitch-Level Dynamics**:
   - Ingest real-time pitch data during game (via MLB Stats API live feeds).
   - Adjust in-game props dynamically (if books offer live strikeout lines).
   - **Challenge**: Latency, data delay; likely not profitable unless sub-second edge.

3. **Multi-Task Learning**:
   - Joint model for Ks, hits, runs; share pitcher/opponent representations.
   - **Benefit**: More training data; transfer learning from correlated outcomes.

4. **Automated Line Shopping**:
   - Integrate multiple sportsbook APIs; always select best available odds.
   - Track book limits; rotate across books to avoid detection.

5. **Game Theory Modeling**:
   - Model how sportsbooks set lines (regression on public betting % + sharp action).
   - Identify "steam moves" (sharp money); follow or fade.

6. **Ensemble of Models**:
   - Combine XGBoost, two-tower, and score distribution models via stacking or weighted average.
   - **Hyperparameter**: weights tuned to minimize Brier on validation set.

---

## Timeline Summary

| Phase | Duration | Focus | Key Deliverable |
|-------|----------|-------|-----------------|
| **MVP** | Weeks 1–2 | Core pipeline, team-level features, baseline model | 100 bets, CLV > 0, Brier < 0.24 |
| **1.5** | Weeks 3–4 | Lineup-weighted features | A/B test: lineup model vs baseline |
| **2** | Weeks 5–8 | Umpire, weather, alt-lines, uncertainty | Brier ≤ 0.21, uncertainty sizing |
| **3** | Weeks 9–16 | Two-tower matchup model, feature store | Shadow deploy two-tower; Brier ≤ 0.20 |
| **4** | Weeks 17–24 | Contextual bandit for sizing/timing | +20 bps CLV improvement |
| **5+** | Months 6–12 | Polymarket, pitch-level, multi-task, ensembles | Explore new edges; diversify venues |

---

## Decision Gates

**Between phases**, validate success criteria before proceeding:

- **MVP → 1.5**: CLV > 0 and Brier < 0.24 over 100 bets.
- **1.5 → 2**: Lineup model CLV ≥ baseline model CLV in A/B test.
- **2 → 3**: Umpire/weather features improve Brier by ≥0.01 OR provide +20 bps CLV.
- **3 → 4**: Two-tower Brier ≤ XGBoost Brier AND CLV ≥ XGBoost CLV in shadow mode.
- **4 → 5**: Bandit policy CLV > fixed Kelly by ≥20 bps in live deployment.

**Halt criteria**: If any phase shows negative CLV for >2 weeks or Brier > 0.25, revert to previous phase and investigate.

---

## Resource Allocation

| Phase | Estimated Effort (Hours) | Key Skills Required |
|-------|---------------------------|---------------------|
| MVP | 40–60 | Python, pandas, sklearn, API integration |
| 1.5 | 20–30 | Data wrangling, feature engineering |
| 2 | 30–40 | External data sources, quantile regression |
| 3 | 60–80 | Deep learning (TensorFlow/PyTorch), model tuning |
| 4 | 80–100 | Reinforcement learning, simulation, off-policy eval |
| 5+ | Variable | Domain exploration, blockchain (Polymarket), real-time systems |

---

## Risk Mitigation

- **Scope creep**: Stick to MVP success criteria; resist adding features before validation.
- **Over-engineering**: Use simplest solution that works (logistic often sufficient; don't jump to RL prematurely).
- **Data dependencies**: Verify provider reliability before building features (e.g., umpire data may be sparse; don't block MVP on it).
- **Model complexity**: Prefer interpretable models (logistic, XGBoost) over black-box until proven necessary (two-tower, RL).

---

## Long-Term Vision (Year 2+)

- **Scale to other props**: Expand to hits, runs, pitcher outs, batter hits (same framework).
- **Other sports**: Apply to NBA player props (points, rebounds, assists), NFL (yards, TDs).
- **Live betting**: Real-time models for in-game props (requires low-latency infra).
- **Syndicate**: Pool bankroll with other sharp bettors; share alpha; negotiate better limits with books.

---

## Summary

**MVP first**: Prove core concept (team-level features, baseline model, positive CLV) before adding complexity.

**Iterate fast**: Each phase = 2–8 weeks; validate success criteria; pivot if needed.

**Bias toward simplicity**: Use simplest model/feature that achieves target metrics; add complexity only when marginal gains justify effort.

**Measure everything**: CLV is primary metric; Brier is secondary; ROI is outcome (lagging, noisy).

**Stay disciplined**: Respect caps, kill-switches, and bankroll limits; do not chase losses or over-bet hot streaks.
