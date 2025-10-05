# System Design

## Architecture Overview

```
┌──────────────────┐
│  Data Providers  │
│ ─────────────────│
│ MLB Stats API    │──┐
│ Statcast/pybase  │  │
│ Odds API         │  │
└──────────────────┘  │
                      ▼
              ┌───────────────┐
              │ Feature Cache │ (JSON/Parquet)
              └───────┬───────┘
                      │
                      ▼
            ┌──────────────────┐
            │ Feature Builders │
            │ ─────────────────│
            │ Pitcher Form     │
            │ Opponent Stats   │
            │ Context/Market   │
            └────────┬─────────┘
                     │
                     ▼
               ┌───────────┐
               │   Model   │ (XGBoost + calibration)
               └─────┬─────┘
                     │
                     ▼
              ┌──────────────┐
              │  Selection   │ (EV calc, Kelly, filters)
              └──────┬───────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Logging & Eval  │ (Bets, CLV, results)
            └─────────────────┘
```

## Pipelines

### Nightly Pipeline (00:30 local)

**Purpose**: Precompute rolling pitcher aggregates and team splits; refresh caches before next day's slate.

**Steps**:

1. **Fetch recent Statcast data** (last 7 days) via `StatcastProvider.get_pitcher_game_logs()`
   - Compute rolling windows (N=5 default) for each active pitcher: K/9, CSW%, whiff%, chase%, zone%, pitch mix.
   - Write to `cache/pitcher_windows/{pitcher_id}_{end_date}.json`.
2. **Refresh team batting splits** via `MlbStatsProvider.get_team_batting_splits(team_id, vs_hand)`
   - Store K% vs LHP/RHP for all 30 teams.
   - Write to `cache/team_splits/{team_id}_{vs_hand}_{as_of_date}.json`.
3. **Audit logs**: count rows fetched, missing pitchers, API errors.
4. **Retention**: delete caches older than 60 days.

**SLO**: Complete in < 15 minutes; retry transient failures with exponential backoff (max 3 attempts).

---

### Game-Day Pipeline

**Purpose**: Build features at multiple checkpoints as lineups/odds evolve; score and select bets.

#### T-6h: Initial Watchlist

1. **Fetch schedule & probables**: `get_schedule(date)`, `get_probables(date)`
   - Extract `gamePk`, `pitcherId`, `teamId`, `throws`, `daysRest`.
2. **Fetch odds**: `OddsProvider.get_pitcher_k_lines(date)`
   - Markets: Over/Under line_decimal, price_over_decimal, price_under_decimal, book, timestamp.
3. **Build preliminary features**:
   - Pitcher form (from nightly cache; fallback to on-demand fetch if pitcher not cached).
   - Team baseline K% vs hand (from nightly cache).
   - Park factor (static lookup), home/away flag.
   - Market features: line, prices, optional book dispersion.
4. **Score**: `model.predict_proba(features)` → P(Over).
5. **Watchlist**: filter candidates where EV ≥ threshold - 1% (wider net for monitoring).

#### T-90m: Optional Lineup Projection (Phase 1.5)

1. **Fetch projected lineups** (if available from provider).
2. **Rebuild features** with lineup-weighted batter K% vs hand.
3. **Re-score** and update watchlist.

**Note**: MVP skips this step; team baseline used instead.

#### T-30m: Final Decision

1. **Fetch confirmed lineups** via `get_boxscore(gamePk)` (if game approaching).
2. **Fetch latest odds** (refresh prices).
3. **Finalize features**:
   - Use confirmed lineup if available; else team baseline.
   - Update market prices.
4. **Score** final P(Over).
5. **Bet selection**:
   - Compute EV = p_over × (O - 1) - (1 - p_over).
   - Filter: EV ≥ 0.03, spread ≤ max, liquidity ≥ min.
   - Compute Kelly fraction: f = λ × ((O × p_over - 1) / (O - 1)), clamp to [0, f_max].
   - Apply caps: per-bet, per-market, per-slate, correlation checks.
6. **Log bet ticket**: timestamp, odds, price, stake, model version, features hash, data timestamps.
7. **Execute** (manual or API integration depending on book support).

#### Post-Game

1. **Fetch closing odds** (final prices before lock).
2. **Compute CLV**: (closing_implied_prob - bet_implied_prob) in basis points.
3. **Ingest actual strikeouts** from boxscore.
4. **Write result row**: game_pk, pitcher_id, line, k_actual, over_outcome, clv, roi.

---

## Caching Plan

**Cache directory structure**:

```
data/cache/
├── pitcher_windows/
│   └── {pitcher_id}_{end_date}.json
├── team_splits/
│   └── {team_id}_{vs_hand}_{as_of_date}.json
├── schedules/
│   └── {date}.json
├── probables/
│   └── {date}.json
├── odds_snapshots/
│   └── {date}_{timestamp}.parquet
└── boxscores/
    └── {game_pk}.json
```

**Cache keys**:

- **Pitcher windows**: `pitcher_id` + `end_date` (e.g., `607644_2025-04-15.json`).
- **Team splits**: `team_id` + `vs_hand` + `as_of_date`.
- **Odds snapshots**: `date` + `timestamp` (allow multiple fetches per day).

**Retention**: 60 days for granular caches; indefinite for aggregated results/logs.

**Versioning**: include schema version in JSON (`{"schema_version": 1, "data": {...}}`).

---

## Failure Modes & Retries

| Failure | Detection | Response |
|---------|-----------|----------|
| Provider timeout | HTTP 5xx or socket timeout | Exponential backoff (1s, 2s, 4s); max 3 retries; log failure. |
| Rate limit (429) | HTTP 429 | Sleep per `Retry-After` header; fallback 60s; max 2 retries. |
| Partial data (e.g., missing pitcher in cache) | Feature builder detects null | On-demand fetch with shorter window (N=3); if still missing, use long-term mean from historical DB; flag in audit log. |
| Odds missing for game | Empty response from odds provider | Skip bet for that game; do not fabricate odds. |
| Model file corrupted | Load error at startup | Halt pipeline; alert; require manual model restore. |
| Boxscore unavailable post-game | API returns 404 | Retry hourly for 6h; if still missing, mark result as "data_missing" and exclude from training. |

**Backoff formula**: `delay = min(base × 2^attempt, max_delay)` (base=1s, max=30s).

---

## Time Honesty

**Critical principle**: Only use data that was *actually available* at decision time to avoid look-ahead bias.

**Guardrails**:

1. **Feature timestamps**: every feature records `as_of` timestamp; must be ≤ bet timestamp.
2. **Odds snapshots**: log fetch timestamp; use most recent snapshot before bet.
3. **Lineup lock**: if lineup used, verify it was confirmed ≥ T-30m before first pitch; else fall back to team baseline.
4. **Train/test splits**: strictly time-based (no shuffling); training window ends before validation window starts.
5. **Closing odds**: only fetch *after* game lock; never use in features.

**Audit**: every bet log includes `feature_hash` and `data_timestamps` JSON to trace feature provenance.

---

## Runtime Constraints

- **Nightly pipeline**: max 15 minutes.
- **Game-day T-6h**: max 5 minutes for full slate.
- **Game-day T-30m**: max 2 minutes (time-sensitive).
- **Post-game**: no SLO (best-effort within 2h of game end).

**Concurrency**: parallelize provider calls within each checkpoint (e.g., fetch all odds concurrently); use connection pooling.

**Logging**: structured JSON logs (timestamp, pipeline_stage, game_pk, duration_ms, status, error).

---

## Deployment Notes (Future)

- **Orchestration**: cron jobs or Airflow DAGs for nightly/game-day pipelines.
- **Monitoring**: Prometheus metrics (cache hit rate, provider latency, bet count, CLV); Grafana dashboards.
- **Alerts**: Slack/PagerDuty on kill-switch triggers, failed pipeline runs, or model drift.
