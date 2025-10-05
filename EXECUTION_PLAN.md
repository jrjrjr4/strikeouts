# Execution Plan

This document provides the end-to-end runbook for operating the strikeout props system: nightly ETL, game-day workflows, and post-game reconciliation.

---

## Overview

The system runs two main pipelines:

1. **Nightly ETL** (00:30 local): Fetch and cache historical data, compute rolling aggregates.
2. **Game-Day Loop**: Multiple checkpoints (T-6h, T-30m, post-game) to fetch odds, build features, score, select bets, and log results.

All times are relative to first pitch of earliest game in slate.

---

## Nightly Pipeline (00:30 Local)

**Trigger**: Cron job at 00:30 (after prior day's games complete).

**Purpose**: Precompute pitcher rolling windows and team splits; refresh caches for next day's slate.

### Steps

#### 1. Fetch Recent Statcast Data

- **Action**: Call `StatcastProvider.get_pitcher_game_logs(pitcher_id, start_date=today-7, end_date=today-1)` for all active pitchers.
- **Active pitchers**: Query MLB Stats API for probables in next 7 days; also include any pitcher with appearance in last 7 days (to backfill).
- **Compute**:
  - For each pitcher, aggregate last N=5 starts (configurable):
    - `k9 = 9 × K / IP`
    - `csw_pct = (called_strikes + whiffs) / pitches`
    - `whiff_pct = whiffs / swings`
    - `chase_pct = chases / out_zone_pitches`
    - `zone_pct = in_zone / pitches`
    - Pitch mix percentages: `fastball_pct`, `slider_pct`, `changeup_pct`, `curve_pct`
    - `delta_csw_3 = mean(csw last 3) - mean(csw prior 3)` (if ≥6 starts available)
- **Cache**: Write to `data/cache/pitcher_windows/{pitcher_id}_{end_date}.json`
  ```json
  {
    "schema_version": 1,
    "pitcher_id": 607644,
    "end_date": "2025-04-14",
    "window_n": 5,
    "k9": 11.2,
    "csw_pct": 0.32,
    "whiff_pct": 0.28,
    "chase_pct": 0.31,
    "zone_pct": 0.47,
    "fastball_pct": 0.58,
    "slider_pct": 0.25,
    "changeup_pct": 0.10,
    "curve_pct": 0.07,
    "delta_csw_3": 0.02,
    "starts_used": 5,
    "as_of": "2025-04-15T00:45:00Z"
  }
  ```
- **Concurrency**: Parallelize across pitchers (thread pool or async); respect Statcast rate limit (~30 req/min).
- **Retry**: Exponential backoff on timeouts; max 3 retries per pitcher.
- **Fallback**: If fetch fails, retain previous cached window; log warning.

#### 2. Refresh Team Batting Splits

- **Action**: Call `MlbStatsProvider.get_team_batting_splits(team_id, vs_hand)` for all 30 teams × 2 hands (60 calls).
- **Compute**: `k_rate = K / PA` for team vs LHP and vs RHP (season-to-date or rolling last-10 games per config).
- **Cache**: Write to `data/cache/team_splits/{team_id}_{vs_hand}_{as_of_date}.json`
  ```json
  {
    "schema_version": 1,
    "team_id": 147,
    "vs_hand": "R",
    "k_rate": 0.235,
    "pa": 1420,
    "as_of_date": "2025-04-14",
    "window": "season_to_date"
  }
  ```
- **Concurrency**: Parallel requests.
- **Retry**: Backoff on 429/5xx.

#### 3. Audit Logs

- **Log summary**:
  ```json
  {
    "pipeline": "nightly_etl",
    "date": "2025-04-15",
    "start_time": "2025-04-15T00:30:00Z",
    "end_time": "2025-04-15T00:42:00Z",
    "duration_min": 12,
    "pitchers_fetched": 85,
    "pitchers_failed": 2,
    "teams_fetched": 60,
    "teams_failed": 0,
    "cache_writes": 145,
    "errors": ["Timeout for pitcher_id=608566"]
  }
  ```
- **Write to**: `data/outputs/logs/nightly_etl_{date}.json`

#### 4. Cache Retention

- **Delete caches older than 60 days**: `rm data/cache/*/*/*_{date < today-60}.json`
- **Archive aggregated logs**: Move monthly logs to `data/outputs/archive/`

### SLOs

- **Max runtime**: 15 minutes
- **Success rate**: ≥95% of pitchers fetched
- **Cache freshness**: All active pitchers have window as-of yesterday

### Monitoring

- **Alert**: If runtime >20 min or success rate <90%, send Slack alert.
- **Metrics**: Log total API calls, cache hit rate, error counts to Prometheus.

---

## Game-Day Loop

### T-6h: Initial Watchlist

**Trigger**: 6 hours before earliest first pitch (typically 13:00 local for 19:00 games).

**Purpose**: Fetch schedule, probables, initial odds; build preliminary features; create watchlist.

#### Steps

1. **Fetch Schedule & Probables**
   - **Call**: `MlbStatsProvider.get_schedule(date)`, `get_probables(date)`
   - **Extract**: `gamePk`, `pitcherId`, `teamId`, `throws`, `homeTeamId`, `awayTeamId`, `parkId`, `gameDate`
   - **Derive**: `days_rest` (from last appearance; fallback 4 if unknown), `home_away_flag`
   - **Cache**: `data/cache/schedules/{date}.json`, `data/cache/probables/{date}.json`

2. **Fetch Odds**
   - **Call**: `OddsProvider.get_pitcher_k_lines(date)`
   - **Extract**: `game_pk`, `pitcher_id`, `line_decimal`, `price_over_decimal`, `price_under_decimal`, `book`, `fetched_at`
   - **Multi-book**: If available, store all books; compute `book_dispersion = stdev(implied_probs)`
   - **Cache**: `data/cache/odds_snapshots/{date}_T-6h.parquet`

3. **Build Preliminary Features**
   - **Load pitcher form**: Read `data/cache/pitcher_windows/{pitcher_id}_{yesterday}.json`
     - If missing, trigger on-demand fetch with N=3 window; if still missing, use season mean; flag `pitcher_form_missing=1`
   - **Load team splits**: Read `data/cache/team_splits/{opponent_team_id}_{vs_pitcher_hand}_{yesterday}.json`
     - Extract `team_k_vs_hand`, `team_pa_estimate`
     - If missing, use team overall K% or league average (0.22); flag `team_split_missing=1`
   - **Context features**: `home_away_flag`, `park_k_factor` (static lookup), `days_rest`
   - **Market features**: `line_decimal`, `price_over_decimal`, `price_under_decimal`, optional `book_dispersion`
   - **Assemble feature vector**: standardize numeric features (using scaler from model artifact)

4. **Score**
   - **Load model**: `data/models/current_model.pkl` (XGBoost + calibrator)
   - **Predict**: `p_over = model.predict_proba(features)[:, 1]`
   - **Compute EV**: `ev = p_over × (price_over_decimal - 1) - (1 - p_over)`

5. **Create Watchlist**
   - **Filter**: `ev >= threshold - 0.01` (wider net; threshold default 0.03)
   - **Store**: `data/outputs/watchlist_{date}_T-6h.json`
     ```json
     [
       {
         "game_pk": 123456,
         "pitcher_id": 607644,
         "pitcher_name": "Jacob deGrom",
         "line": 6.5,
         "price_over": 1.91,
         "p_over": 0.58,
         "ev": 0.047,
         "kelly_frac": 0.012,
         "features_hash": "a3f2b1c...",
         "checkpoint": "T-6h"
       }
     ]
     ```

6. **Log**
   - Write checkpoint log: `data/outputs/logs/gameday_{date}_T-6h.json`

#### SLO

- **Max runtime**: 5 minutes for full slate (15 games × 2 probables = 30 pitchers)

---

### T-90m: Optional Lineup Projection (Phase 1.5)

**Trigger**: 90 minutes before first pitch.

**Purpose**: Fetch projected lineups (if available); rebuild features with lineup-weighted opponent stats; re-score.

#### Steps

1. **Fetch Projected Lineups** (provider-dependent; may not be reliable)
   - **Call**: `MlbStatsProvider.get_boxscore(gamePk)` or third-party lineup provider
   - **Extract**: `battingOrder` (list of player IDs 1–9), `batterIds`
   - **Availability**: Often unreliable until T-30m; skip if unavailable

2. **Rebuild Features**
   - **Compute** `lineup_weighted_k_vs_hand`:
     ```
     Σ(batter_k_vs_hand[i] × expected_pa_weight[i]) for i=1–9
     expected_pa_weights = [4.8, 4.7, 4.6, 4.5, 4.4, 4.3, 4.1, 3.9, 3.7]
     ```
   - **Fallback**: If batter split missing, use team average; if lineup unavailable, use team baseline (same as T-6h)

3. **Re-score** and update watchlist

**Note**: **Not implemented in MVP**; team baseline used at all checkpoints. Lineup integration deferred to Phase 1.5.

---

### T-30m: Final Decision

**Trigger**: 30 minutes before each game's first pitch (staggered for doubleheaders).

**Purpose**: Fetch confirmed lineups, latest odds; finalize features; score; select bets; log tickets.

#### Steps

1. **Fetch Confirmed Lineups**
   - **Call**: `MlbStatsProvider.get_boxscore(gamePk)`
   - **Availability**: Usually confirmed by T-30m (sometimes earlier)
   - **Extract**: `battingOrder`, `batterIds`
   - **Fallback**: If unavailable, use team baseline (same as T-6h)

2. **Fetch Latest Odds**
   - **Call**: `OddsProvider.get_pitcher_k_lines(date)`
   - **Purpose**: Refresh prices (may have moved since T-6h)
   - **Cache**: `data/cache/odds_snapshots/{date}_T-30m.parquet`

3. **Finalize Features**
   - **Use confirmed lineup** (if available) to compute `lineup_weighted_k_vs_hand`
   - **Update market features** with latest prices
   - **Refresh** pitcher form if new game log available (rare at T-30m; typically use nightly cache)

4. **Score**
   - **Predict**: `p_over = model.predict_proba(features)[:, 1]`
   - **Compute EV**: `ev = p_over × (price_over - 1) - (1 - p_over)`

5. **Bet Selection**
   - **Filters**:
     1. `ev >= config.betting.ev_min` (default 0.03)
     2. `spread = (1/price_over + 1/price_under - 1) <= config.market.max_spread_cents / 100` (default 0.05)
     3. Liquidity ≥ `config.market.min_liquidity` (if available from provider)
     4. `price_over >= 1.4` (min decimal odds; avoid very high-juice bets)
   - **Kelly Sizing**:
     ```
     f = kelly_lambda × ((price_over × p_over - 1) / (price_over - 1))
     f_clamped = max(0, min(f, kelly_max))
     stake = f_clamped × bankroll
     stake_final = min(stake, per_bet_cap, remaining_slate_budget)
     ```
     - Defaults: `kelly_lambda=0.2`, `kelly_max=0.02`, `per_bet_cap=200`, `per_slate_cap=1500`
   - **Exposure Caps**:
     - **Per-bet**: `stake <= per_bet_cap`
     - **Per-market**: Max 1 bet per (pitcher, line) pair (no Over + alt-line Over)
     - **Per-slate**: Total stakes across all games today ≤ `per_slate_cap`
     - **Correlation**: If betting on multiple pitchers in same game (e.g., both starters), cap combined stake to 1.5× single-bet cap
   - **Final bet list**: Rank by EV; select top N respecting caps

6. **Log Bet Tickets**
   - **Write to**: `data/outputs/bets/{date}.jsonl` (one line per bet)
     ```json
     {
       "bet_id": "2025-04-15_123456_607644_6.5",
       "timestamp": "2025-04-15T18:30:00Z",
       "date": "2025-04-15",
       "game_pk": 123456,
       "pitcher_id": 607644,
       "pitcher_name": "Jacob deGrom",
       "line": 6.5,
       "side": "over",
       "price_decimal": 1.91,
       "p_over": 0.58,
       "ev": 0.047,
       "kelly_frac": 0.012,
       "stake": 120.00,
       "book": "draftkings",
       "model_version": "v1.2.3",
       "features_hash": "a3f2b1c...",
       "data_timestamps": {
         "pitcher_form_as_of": "2025-04-14T00:45:00Z",
         "team_split_as_of": "2025-04-14T00:40:00Z",
         "odds_fetched_at": "2025-04-15T18:25:00Z",
         "lineup_confirmed": true
       },
       "caps_applied": {
         "per_bet_cap": 200,
         "kelly_stake": 150,
         "final_stake": 120,
         "reason": "slate_cap_remaining=120"
       }
     }
     ```
   - **Audit**: Include `features_hash` (SHA256 of feature names + values) and `data_timestamps` for provenance

7. **Execute Bets** (Manual or API)
   - **Manual**: Display bet tickets in CLI or web UI; user places bets via book interface.
   - **API** (future): Integrate with book APIs (if supported) to auto-place; log confirmations.

#### SLO

- **Max runtime**: 2 minutes per slate (time-sensitive; games starting soon)

---

### Post-Game: Reconciliation

**Trigger**: 2 hours after game end (allow time for stats finalization).

**Purpose**: Fetch closing odds, actual strikeouts; compute CLV and ROI; write results.

#### Steps

1. **Fetch Closing Odds**
   - **Call**: `OddsProvider.get_pitcher_k_lines(date)` (final snapshot before lock)
   - **Timing**: Fetch at game start time + 5 min (after lines closed)
   - **Extract**: `closing_price_over`, `closing_price_under`, `book`, `timestamp`
   - **Cache**: `data/cache/closing_odds/{date}.parquet`

2. **Compute CLV (Closing Line Value)**
   - **Formula**:
     ```
     bet_implied_prob = 1 / price_at_bet
     closing_implied_prob = 1 / closing_price
     clv_bps = (closing_implied_prob - bet_implied_prob) × 10000
     ```
   - **Example**: Bet at 1.91 (52.4% implied), closed at 1.85 (54.1% implied) → CLV = +170 bps (good)
   - **Interpretation**: Positive CLV → got better price than market consensus; strong validation signal

3. **Ingest Actual Strikeouts**
   - **Call**: `MlbStatsProvider.get_boxscore(gamePk)` (final stats)
   - **Extract**: `pitcher_strikeouts` (k_actual)
   - **Compute**: `over_outcome = 1 if k_actual >= line else 0`
   - **Handle early exits**: If pitcher injured/ejected early, k_actual is official total; no adjustment (variance of betting)

4. **Compute ROI**
   - **Profit/Loss**:
     ```
     if over_outcome == 1:
       profit = stake × (price_decimal - 1)
     else:
       profit = -stake
     roi = profit / stake
     ```

5. **Write Result Row**
   - **Append to**: `data/outputs/results/{date}.jsonl`
     ```json
     {
       "bet_id": "2025-04-15_123456_607644_6.5",
       "date": "2025-04-15",
       "game_pk": 123456,
       "pitcher_id": 607644,
       "line": 6.5,
       "side": "over",
       "price_at_bet": 1.91,
       "stake": 120.00,
       "p_over": 0.58,
       "k_actual": 8,
       "over_outcome": 1,
       "profit": 109.20,
       "roi": 0.91,
       "closing_price": 1.85,
       "clv_bps": 170,
       "timestamp": "2025-04-15T23:30:00Z"
     }
     ```

6. **Training Data Update**
   - **Append to**: `data/training/labeled_samples.parquet` (features + over_outcome)
   - **Purpose**: Accumulate training data for weekly retraining

#### SLO

- **Best effort**: Complete within 2h of game end; retry if boxscore unavailable (may take longer for late games)

---

## Daily Summary & Monitoring

**Trigger**: End of day (01:00 local, after nightly ETL).

**Generate**:

- **Daily report**: `data/outputs/reports/daily_{date}.json`
  ```json
  {
    "date": "2025-04-15",
    "games": 12,
    "bets_placed": 8,
    "total_stake": 960.00,
    "total_profit": 145.60,
    "roi_pct": 15.2,
    "clv_avg_bps": 85,
    "hit_rate": 0.625,
    "brier_score": 0.22,
    "model_version": "v1.2.3",
    "alerts": []
  }
  ```

**Monitoring Dashboards** (Grafana/Prometheus):

- **Metrics**:
  - Bets placed per day
  - Average EV, CLV, ROI
  - Hit rate (rolling 7-day, 30-day)
  - Brier score (rolling 7-day)
  - Provider latencies (p50, p95)
  - Cache hit rates
  - Error counts by provider

**Alerts**:

- CLV < -20 bps for 3 consecutive days
- Brier score > 0.25 for 7-day window
- Daily loss > 5% of bankroll
- Provider error rate > 10%

---

## Kill-Switch Triggers (see RISK_AND_GUARDS.md)

**Automatic halt** if:

1. Drawdown > 5% of bankroll in single day
2. CLV < -20 bps for 3 consecutive betting days
3. Model load failure or feature hash mismatch

**Manual override**: Operator can disable betting via `config.betting.enabled=false`

---

## Example Timeline (Typical Game Day)

| Time | Event | Duration |
|------|-------|----------|
| 00:30 | Nightly ETL starts | 12 min |
| 13:00 | T-6h checkpoint (19:00 first pitch) | 4 min |
| 17:30 | T-30m checkpoint (staggered per game) | 2 min |
| 17:35 | Bets placed (manual or API) | 5 min |
| 19:00 | First pitch | – |
| 22:00 | Game ends | – |
| 00:00 | Post-game reconciliation | 10 min |
| 01:00 | Daily summary generated | 2 min |

---

## Deployment Orchestration (Future)

- **Cron jobs**: Simple MVP approach; schedule nightly ETL, T-6h, T-30m scripts.
- **Airflow DAGs**: Production orchestration; handle retries, alerts, dependencies.
- **Docker containers**: Package pipeline code; deploy on cloud VM or local server.
- **CI/CD**: GitHub Actions to test pipeline on historical data before deploying new model versions.
