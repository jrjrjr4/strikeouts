# Feature Specification

Every feature below includes: **name**, **type**, **formula**, **window/source**, **fallback**, and **motivation**.

---

## Pitcher Form Features (Recent Performance)

### k9

- **Type**: float
- **Formula**: `9 × K / IP`
- **Window**: Last N=5 starts (configurable; default 5)
- **Source**: Statcast pitcher game logs aggregated nightly
- **Fallback**: If < 5 starts, use N=3; if < 3, use season-long mean; if new pitcher, use league average (~8.5) and flag `new_pitcher=1`
- **Motivation**: Core measure of strikeout rate per 9 innings; strong predictor of future Ks

### csw_pct

- **Type**: float (0–1)
- **Formula**: `(called_strikes + whiffs) / total_pitches`
- **Window**: Mean over last N=5 starts
- **Source**: Statcast pitch-level data
- **Fallback**: Same hierarchical fallback as k9 (N=3 → season → league ~0.30)
- **Motivation**: CSW (Called Strike + Whiff) is a stable process metric; less noisy than K/9; predictive of swing-and-miss

### whiff_pct

- **Type**: float (0–1)
- **Formula**: `whiffs / swings`
- **Window**: Mean over last N=5 starts
- **Source**: Statcast
- **Fallback**: N=3 → season → league ~0.24
- **Motivation**: Direct swing-and-miss skill; correlates with Ks

### chase_pct

- **Type**: float (0–1)
- **Formula**: `chases / out_of_zone_pitches`
- **Window**: Mean over last N=5 starts
- **Source**: Statcast
- **Fallback**: N=3 → season → league ~0.28
- **Motivation**: Pitchers who induce chases generate more whiffs and weak contact; context-dependent (some lineups chase more)

### zone_pct

- **Type**: float (0–1)
- **Formula**: `in_zone_pitches / total_pitches`
- **Window**: Mean over last N=5 starts
- **Source**: Statcast
- **Fallback**: N=3 → season → league ~0.46
- **Motivation**: Command proxy; higher zone% → more called strikes, but can reduce chases; interaction with opponent discipline

### fastball_pct, slider_pct, changeup_pct, curve_pct

- **Type**: float (0–1) each; sum ≈ 1.0
- **Formula**: Pitch type usage rates (group FF/SI/FC as fastball; SL as slider; CH/FS as changeup; CU/KC as curve)
- **Window**: Mean over last N=5 starts
- **Source**: Statcast pitch-type classification
- **Fallback**: N=3 → season → league typical mix (60% fastball, 20% slider, 10% changeup, 10% curve)
- **Motivation**: Pitch mix diversity affects platoon splits and opponent scouting; some mixes (e.g., high slider%) correlate with higher K rates

### delta_csw_3

- **Type**: float (-0.2 to +0.2 typical range)
- **Formula**: `mean(csw_pct last 3 starts) - mean(csw_pct starts 4–6)`
- **Window**: Requires 6 starts; if unavailable, set to 0
- **Source**: Statcast
- **Fallback**: 0 (no trend signal)
- **Motivation**: Short-term trend; captures "hot hand" or declining command; noisy but additive signal

### days_rest

- **Type**: int (0–10+)
- **Formula**: `game_date - pitcher_last_appearance_date`
- **Source**: Probables API + game log lookup
- **Fallback**: If unknown, assume 4 (typical rotation slot)
- **Motivation**: Rest affects velocity/stamina; extreme short rest (<3 days, reliever) or long rest (>7 days, injury return) can impact performance

---

## Opponent Features (Team-Level for MVP; Lineup-Weighted in Phase 1.5)

### team_k_vs_hand

- **Type**: float (0–1)
- **Formula**: `team_strikeouts / team_plate_appearances` vs LHP or RHP (depending on pitcher hand)
- **Window**: Season-to-date or rolling last-10 games (configurable)
- **Source**: MLB Stats API team splits
- **Fallback**: If team split unavailable, use team overall K%; if that missing, use league average (~0.22)
- **Motivation**: Primary opponent context; teams vary widely (range ~0.18–0.26); strong predictor

### team_pa_estimate

- **Type**: float (~35–42 per game)
- **Formula**: Team's average PAs per game this season
- **Source**: MLB Stats API team stats
- **Fallback**: League average ~38 PAs/game
- **Motivation**: Scaling factor for expected strikeouts; high-offense teams see more PAs → more opportunities for Ks

### lineup_weighted_k_vs_hand (Phase 1.5)

- **Type**: float (0–1)
- **Formula**: `Σ(batter_k_vs_hand[i] × expected_pa_weight[i])` for i=1–9 (batting order)
- **Window**: Season-to-date batter splits
- **Source**: Confirmed lineup from boxscore + batter splits from MLB Stats API
- **Fallback**: Use `team_k_vs_hand` if lineup unavailable (T-6h, T-90m) or batter split missing
- **Motivation**: Lineup composition matters; facing 1–5 hitters (low K%) vs 6–9 (high K%) significantly changes expected Ks; expected PA weights by order (1st ~4.8, 2nd ~4.7, ..., 9th ~3.7) account for order effect
- **Expected PA weights** (Markov chain approximation): `[4.8, 4.7, 4.6, 4.5, 4.4, 4.3, 4.1, 3.9, 3.7]` (sum ≈ 39)
- **Not implemented in MVP**; deferred to Phase 1.5

---

## Context Features

### home_away_flag

- **Type**: binary (0=away, 1=home)
- **Formula**: `1 if pitcher_team_id == home_team_id else 0`
- **Source**: Probables + schedule
- **Fallback**: N/A (always available)
- **Motivation**: Home teams have slight advantage (~52% win rate); may correlate with pitcher comfort, but effect on Ks is weak; include for completeness

### park_k_factor

- **Type**: float (0.95–1.05)
- **Formula**: Static lookup table by `park_id`
- **Source**: Historical park factors (e.g., Coors Field ~0.96, Dodger Stadium ~1.02)
- **Fallback**: 1.0 (neutral) if park unknown
- **Motivation**: Some parks have altitude (Coors), dimensions, or backgrounds affecting swing-and-miss; small effect (~2–5%) but free signal
- **TBD**: Update table annually; source from FanGraphs park factors or compute from historical data

### ump_k_factor (Phase 2)

- **Type**: float (0.95–1.05)
- **Formula**: `umpire_k_per_game / league_avg_k_per_game`
- **Source**: Umpire assignment + historical umpire stats
- **Fallback**: 1.0 (neutral)
- **Motivation**: Umpires vary in strike zone size/consistency; ~3–5% effect on K rates
- **Not implemented in MVP**

### weather_run_env_factor (Phase 2)

- **Type**: float (0.95–1.05)
- **Formula**: TBD (regression on temp, humidity, wind → run environment → inverse correlation with Ks)
- **Source**: Weather API + park lat/lon
- **Fallback**: 1.0 (neutral)
- **Motivation**: Hot/dry/wind-out → more offense → pitchers exit earlier → fewer total Ks; cold/wind-in → pitcher-friendly
- **Not implemented in MVP**

---

## Market Features

### line_decimal

- **Type**: float (4.5–8.5 typical; 0.5 increments)
- **Formula**: Strikeout O/U line from odds provider
- **Source**: Odds API
- **Fallback**: Skip bet if line missing (do not synthesize)
- **Motivation**: Critical input; model predicts P(K ≥ line | features); line varies by matchup

### price_over_decimal

- **Type**: float (1.4–2.5 typical; decimal odds)
- **Formula**: Best available Over price across books (or single book if not line-shopping)
- **Source**: Odds API
- **Fallback**: Skip bet if missing
- **Motivation**: Used in EV calc; also feature for model (market prices embed information)

### price_under_decimal

- **Type**: float (1.4–2.5 typical)
- **Formula**: Best available Under price
- **Source**: Odds API
- **Fallback**: Skip bet if missing
- **Motivation**: Sanity check (Over + Under implied probs should sum >1 due to vig); optional feature for market efficiency signal

### book_dispersion (optional)

- **Type**: float (0–0.05 typical; stdev of implied probabilities across books)
- **Formula**: `stdev([1/price_over_book1, 1/price_over_book2, ...])`
- **Source**: Multi-book odds
- **Fallback**: 0 if single book
- **Motivation**: High dispersion → market uncertainty → potential edge; low dispersion → consensus
- **Optional for MVP**; include if multi-book data available

---

## Target Label (Training Only)

### over

- **Type**: binary (0=Under, 1=Over)
- **Formula**: `1 if k_actual >= line_decimal else 0`
- **Source**: Boxscore actual strikeouts + historical odds line
- **Fallback**: If historical odds unavailable for training sample, synthesize line via quantile regression on pitcher/opponent features (document synthetic target generation in MODEL_SPEC)
- **Motivation**: Supervised learning target; note line varies per game, so model must condition on line

---

## Feature Transformations & Encoding

- **Numeric features**: Standardize (z-score) using training set mean/std; store scaler with model artifact
- **Binary flags**: {0, 1} as-is
- **Categorical** (if added later, e.g., pitcher_id for embedding): one-hot or target encoding
- **Missing indicators**: Add `*_missing` binary flag for features with fallback (e.g., `lineup_weighted_k_missing=1` if team baseline used)

---

## Feature Importance & Selection

- **Baseline model**: Start with all features; inspect XGBoost feature importances (gain, cover, frequency)
- **Expected top features** (based on domain knowledge):
  1. `line_decimal` (directly defines threshold)
  2. `team_k_vs_hand` or `lineup_weighted_k_vs_hand` (opponent context)
  3. `k9`, `csw_pct`, `whiff_pct` (pitcher skill)
  4. `days_rest` (form proxy)
  5. `price_over_decimal` (market signal)
- **Prune features**: Remove if importance < 1% and ablation test shows no calibration degradation
- **Interaction terms**: Consider `k9 × team_k_vs_hand` (matchup synergy) in Phase 2

---

## Audit & Versioning

- **Feature hash**: SHA256 of feature names + transformations; log with every prediction to trace provenance
- **Schema version**: Increment when adding/removing features; store in model metadata
- **Data timestamps**: Log `as_of` timestamp for each feature source (e.g., `pitcher_form_as_of`, `odds_fetched_at`) to ensure time honesty
