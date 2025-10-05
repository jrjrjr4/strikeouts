# Data Sources

This document catalogs all external data providers, endpoints, key fields, rate limits, and fallback logic.

---

## 1. MLB Stats API (statsapi.mlb.com)

**Purpose**: Official MLB data for schedules, teams, players, probables, boxscores, and team batting splits.

**Base URL**: Configurable via `config.providers.mlb_stats.base_url` (default: `https://statsapi.mlb.com/api/v1`).

**Authentication**: None (public API).

**Rate Limits**: Undocumented; observed ~100 req/min safe. Implement exponential backoff on 429/5xx.

### Endpoints & Key Fields

#### `get_schedule(date)`

- **Call**: `GET /schedule?sportId=1&date={YYYY-MM-DD}`
- **Returns**:
  ```json
  {
    "dates": [{
      "games": [{
        "gamePk": 123456,
        "gameDate": "2025-04-15T19:10:00Z",
        "teams": {
          "home": {"team": {"id": 147}},
          "away": {"team": {"id": 121}}
        },
        "venue": {"id": 15}
      }]
    }]
  }
  ```
- **Fields to capture**: `gamePk`, `homeTeamId`, `awayTeamId`, `parkId`, `gameDate`.

#### `get_probables(date)`

- **Call**: `GET /schedule?sportId=1&date={YYYY-MM-DD}&hydrate=probablePitcher`
- **Returns**: Same as schedule, plus nested `probablePitcher`:
  ```json
  {
    "teams": {
      "home": {
        "probablePitcher": {
          "id": 607644,
          "fullName": "Jacob deGrom",
          "pitchHand": {"code": "R"}
        }
      }
    }
  }
  ```
- **Fields to capture**: `pitcherId`, `pitcherName`, `throws` (R/L), `teamId`, `gamePk`.
- **Derive `daysRest`**: fetch pitcher's last appearance date from game logs; compute delta. Fallback: assume 4 if unknown.

#### `get_boxscore(gamePk)`

- **Call**: `GET /game/{gamePk}/boxscore`
- **Returns**:
  ```json
  {
    "teams": {
      "home": {
        "battingOrder": [607644, 501303, ...],
        "players": {
          "ID607644": {"person": {"id": 607644, "fullName": "..."}, "battingOrder": "100"}
        }
      }
    }
  }
  ```
- **Fields to capture**: `battingOrder` (list of player IDs in order 1–9), `batterIds`.
- **Availability**: confirmed ~30–60 min before first pitch; fallback to team baseline if unavailable.

#### `get_team_batting_splits(teamId, vs_hand)`

- **Call**: `GET /teams/{teamId}/stats?stats=vsLeftP,vsRightP&season=2025`
- **Returns**: Team splits JSON with `strikeouts`, `plateAppearances`, `atBats`, etc.
- **Fields to compute**: `k_rate = K / PA`, `pa` (for weighting), `date_range` (season-to-date or last N games).
- **Fallback**: if season stats sparse, use rolling last-10 games; if still missing, use league-average K% (~22%).

---

## 2. Statcast / Pitch-Level Data (via pybaseball or Baseball Savant exports)

**Purpose**: Granular pitch-level metrics for pitcher recent form and pitch mix.

**Source**: `pybaseball` Python library wrapping Baseball Savant public queries, or direct CSV exports.

**Rate Limits**: Baseball Savant requests ~30 req/min safe; cache aggressively. Respect 5s delay between bulk queries.

**Fallback**: if API blocked or rate-limited, use local cache; if cache stale, defer compute and flag in audit log.

### Data Retrieved

#### `get_pitcher_game_logs(pitcher_id, start_date, end_date)`

- **Call**: `pybaseball.statcast_pitcher(start_dt, end_dt, pitcher_id)`
- **Returns**: DataFrame with columns:
  - `game_date`, `game_pk`, `ip` (computed from outs_recorded), `k` (strikeouts), `pitches`, `swings`, `whiffs`, `called_strikes`, `in_zone`, `out_zone`, `chase`, `pitch_type`.
- **Aggregate per game**:
  - `csw_pct = (called_strikes + whiffs) / pitches`
  - `whiff_pct = whiffs / swings`
  - `chase_pct = chases / out_zone_pitches`
  - `zone_pct = in_zone / pitches`
  - `pitch_mix_pct` (group by pitch_type: FF/SI/FC = fastball; SL/CU/KC = breaking; CH/FS = offspeed).

#### `summarize_recent(pitcher_id, N=5)`

- **Compute**:
  - Last N starts (default 5): mean and median of `k9`, `csw_pct`, `whiff_pct`, `chase_pct`, `zone_pct`.
  - Pitch mix percentages: `fastball_pct`, `slider_pct`, `changeup_pct`, `curve_pct`.
  - Trend: `delta_csw_3 = mean(csw last 3 starts) - mean(csw starts 4–6)`.
- **Fallback**:
  - If < N starts available, use N=3 or N=1; if zero, use pitcher's season-long mean from DB; if new pitcher, use league average (flag in features).

### Cache Strategy

- **Key**: `pitcher_id` + `end_date` (e.g., `607644_2025-04-15.json`).
- **Retention**: 60 days; refresh nightly for active pitchers (probable in next 7 days).
- **Format**: JSON with schema version and computed aggregates (not raw pitch data to save space).

---

## 3. Odds Provider (e.g., The Odds API or similar)

**Purpose**: Live strikeout Over/Under lines and prices from multiple sportsbooks.

**Base URL**: Configurable via `config.providers.odds.base_url`.

**Authentication**: API key via env variable `ODDS_API_KEY`.

**Rate Limits**: Typical 500 requests/month on free tier; paid tiers 10k+/month. Enforce per-day quota and alert at 80% usage.

### Endpoint

#### `get_pitcher_k_lines(date)`

- **Call**: `GET /v4/sports/baseball_mlb/events?apiKey={key}&date={YYYY-MM-DD}&markets=pitcher_strikeouts`
- **Returns**:
  ```json
  {
    "events": [{
      "id": "abc123_gamePk",
      "commence_time": "2025-04-15T19:10:00Z",
      "bookmakers": [{
        "key": "draftkings",
        "markets": [{
          "key": "pitcher_strikeouts_over_under",
          "last_update": "2025-04-15T18:45:00Z",
          "outcomes": [
            {"name": "Jacob deGrom", "pitcher_id": 607644, "line": 6.5, "price_decimal": 1.91, "side": "over"},
            {"name": "Jacob deGrom", "pitcher_id": 607644, "line": 6.5, "price_decimal": 1.95, "side": "under"}
          ]
        }]
      }]
    }]
  }
  ```
- **Fields to capture**: `game_pk`, `pitcher_id`, `line_decimal`, `price_over_decimal`, `price_under_decimal`, `book`, `fetched_at` (timestamp).
- **Multi-book handling**: store all books; compute `book_dispersion` (stdev of implied probs) as optional feature; select best price per side when placing bet.

### Rate Limit Handling

- **Strategy**: batch fetch entire day's slate in single call; cache snapshot; refresh at T-6h, T-2h, T-30m.
- **Backoff**: on 429, sleep 60s; on 5xx, exponential backoff (max 3 retries).
- **Mock mode**: if API quota exhausted, load static CSV with historical odds distributions for testing (flag all bets as "mock").

### Missing Data

- If odds unavailable for a game/pitcher: skip bet (do not synthesize odds).
- If only one side quoted: skip (cannot compute EV without both sides).

---

## 4. Umpire Data (Phase 2 – Stub)

**Purpose**: Umpire strikeout tendency adjustments.

**Source**: TBD (potential: `pybaseball` umpire scorecards, or Baseball Savant umpire CSW stats).

**Fields to compute**:

- `ump_k_factor` = (umpire K% per game) / (league avg K% per game).
- Typical range: 0.95–1.05.

**Integration**:

- Fetch umpire assignment from MLB Stats API (`GET /game/{gamePk}/linescore` includes umpire names post-assignment, usually T-3h).
- Join to historical umpire stats table.
- Fallback: neutral factor = 1.0 if umpire unknown or insufficient history.

**Not implemented in MVP**.

---

## 5. Weather Data (Phase 2 – Stub)

**Purpose**: Temperature, humidity, wind effects on run environment (indirect K correlation).

**Source**: TBD (options: OpenWeatherMap API for stadium lat/lon; MLB park weather; paid provider like Weather Underground).

**Fields to compute**:

- `weather_run_env_factor` = f(temp, humidity, wind_speed, wind_direction).
- Hotter/drier/wind-out → more offense → potentially fewer Ks (pitcher exits earlier); cold/wind-in → pitchers-friendly.

**Integration**:

- Fetch at T-3h; join to park_id.
- Fallback: neutral factor = 1.0.

**Not implemented in MVP**.

---

## 6. Polymarket (Optional, Phase 5+)

**Purpose**: Decentralized prediction market for MLB props; potential arbitrage or hedge opportunities.

**API**: Polymarket CLOB API (https://docs.polymarket.com).

**Markets**: "Will [Pitcher] record Over X.5 strikeouts?" binary outcome tokens.

**Key Differences from Sportsbooks**:

- **Resolution risk**: relies on UMA oracle; disputes possible (low frequency but non-zero).
- **Liquidity**: typically lower than major sportsbooks; wider spreads.
- **Use cases**:
  - Rule-based edges (e.g., market misprices lineup news).
  - Hedge sportsbook positions if spread favorable.
  - Arbitrage across venues.

**Integration Plan** (separate module):

- Fetch Polymarket odds alongside sportsbook odds.
- Compute cross-venue EV; flag arb opportunities (require min spread after fees).
- Risk guards: cap Polymarket exposure separately; monitor resolution delays.

**Not implemented in MVP**.

---

## Summary Table

| Provider | Purpose | Rate Limit | Cache TTL | Fallback |
|----------|---------|------------|-----------|----------|
| MLB Stats API | Schedule, probables, boxscore, team splits | ~100/min | 24h (schedule), 1h (probables) | N/A (required) |
| Statcast/pybaseball | Pitcher game logs, rolling aggregates | ~30/min | 24h (nightly refresh) | Local cache; long-term mean |
| Odds API | Strikeout O/U lines & prices | 500/month (free) | 2h during game-day | Skip bet if missing |
| Umpire (Phase 2) | Umpire K tendency | TBD | Season-long | Neutral factor = 1.0 |
| Weather (Phase 2) | Temp, wind, humidity | TBD | 3h | Neutral factor = 1.0 |
| Polymarket (Phase 5+) | Alt venue, arb | TBD | Real-time | Optional; skip if unavailable |

---

## Configuration

All endpoints, keys, and limits configurable via [CONFIG_TEMPLATE.yaml](CONFIG_TEMPLATE.yaml):

```yaml
providers:
  mlb_stats:
    base_url: "https://statsapi.mlb.com/api/v1"
    timeout_s: 8
    retries: 3
  statcast:
    use_pybaseball: true
    timeout_s: 20
    retries: 2
  odds:
    base_url: "https://api.theoddsapi.com"
    api_key_env: "ODDS_API_KEY"
    timeout_s: 8
    retries: 3
    quota_monthly: 500
```

---

## Audit & Monitoring

- **Log every provider call**: endpoint, timestamp, duration_ms, status_code, cache_hit.
- **Daily summary**: total calls per provider, cache hit rate, errors, quota usage.
- **Alerts**: quota > 80%, consecutive failures > 3, cache staleness > threshold.
