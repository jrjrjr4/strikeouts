-- MLB Pitcher Strikeout Props - Database Schema (DDL Stub)
-- Target: SQLite or PostgreSQL
-- Purpose: Define tables for caching, features, bets, and results
-- NOTE: This is a stub for planning; no data included.

-- =============================================================================
-- Reference Tables
-- =============================================================================

CREATE TABLE IF NOT EXISTS players (
    player_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    throws TEXT CHECK(throws IN ('L', 'R')),  -- Pitchers: handedness
    bats TEXT CHECK(bats IN ('L', 'R', 'S')),  -- Batters: handedness (S = switch)
    position TEXT,  -- "P", "1B", "OF", etc.
    active BOOLEAN DEFAULT TRUE,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS teams (
    team_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    abbreviation TEXT,  -- e.g., "NYY", "LAD"
    league TEXT CHECK(league IN ('AL', 'NL')),
    division TEXT,  -- "East", "Central", "West"
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS parks (
    park_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    home_team_id INTEGER REFERENCES teams(team_id),
    park_k_factor REAL DEFAULT 1.0,  -- Static K adjustment (0.95-1.05)
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- Games & Schedules
-- =============================================================================

CREATE TABLE IF NOT EXISTS games (
    game_pk INTEGER PRIMARY KEY,
    game_date DATE NOT NULL,
    game_time TIMESTAMP NOT NULL,
    home_team_id INTEGER NOT NULL REFERENCES teams(team_id),
    away_team_id INTEGER NOT NULL REFERENCES teams(team_id),
    park_id INTEGER NOT NULL REFERENCES parks(park_id),
    status TEXT CHECK(status IN ('scheduled', 'live', 'final', 'postponed')),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_game_date (game_date)
);

-- =============================================================================
-- Pitcher Rolling Windows (Statcast Aggregates)
-- =============================================================================

CREATE TABLE IF NOT EXISTS pitcher_windows (
    pitcher_id INTEGER NOT NULL REFERENCES players(player_id),
    end_date DATE NOT NULL,  -- Last date in rolling window
    window_n INTEGER NOT NULL,  -- Number of starts used (e.g., 5)
    k9 REAL,  -- Strikeouts per 9 innings
    csw_pct REAL CHECK(csw_pct >= 0 AND csw_pct <= 1),  -- Called strike + whiff %
    whiff_pct REAL CHECK(whiff_pct >= 0 AND whiff_pct <= 1),
    chase_pct REAL CHECK(chase_pct >= 0 AND chase_pct <= 1),
    zone_pct REAL CHECK(zone_pct >= 0 AND zone_pct <= 1),
    fastball_pct REAL CHECK(fastball_pct >= 0 AND fastball_pct <= 1),
    slider_pct REAL CHECK(slider_pct >= 0 AND slider_pct <= 1),
    changeup_pct REAL CHECK(changeup_pct >= 0 AND changeup_pct <= 1),
    curve_pct REAL CHECK(curve_pct >= 0 AND curve_pct <= 1),
    delta_csw_3 REAL,  -- Trend: mean(last 3) - mean(prior 3)
    starts_used INTEGER,  -- Actual number of starts (may be < window_n if sparse)
    as_of TIMESTAMP NOT NULL,  -- When computed
    PRIMARY KEY (pitcher_id, end_date),
    INDEX idx_pitcher_end_date (pitcher_id, end_date)
);

-- =============================================================================
-- Team Batting Splits (K% vs LHP/RHP)
-- =============================================================================

CREATE TABLE IF NOT EXISTS team_splits (
    team_id INTEGER NOT NULL REFERENCES teams(team_id),
    vs_hand TEXT NOT NULL CHECK(vs_hand IN ('L', 'R')),  -- vs LHP or RHP
    k_rate REAL NOT NULL CHECK(k_rate >= 0 AND k_rate <= 1),  -- K / PA
    pa INTEGER NOT NULL,  -- Plate appearances (sample size)
    as_of_date DATE NOT NULL,  -- Data current as-of this date
    window TEXT,  -- e.g., "season_to_date", "last_10_games"
    PRIMARY KEY (team_id, vs_hand, as_of_date),
    INDEX idx_team_vs_hand_date (team_id, vs_hand, as_of_date)
);

-- =============================================================================
-- Batter Splits (Phase 1.5; K% vs LHP/RHP)
-- =============================================================================

CREATE TABLE IF NOT EXISTS batter_splits (
    batter_id INTEGER NOT NULL REFERENCES players(player_id),
    vs_hand TEXT NOT NULL CHECK(vs_hand IN ('L', 'R')),
    k_rate REAL CHECK(k_rate >= 0 AND k_rate <= 1),
    pa INTEGER,
    as_of_date DATE NOT NULL,
    window TEXT,
    PRIMARY KEY (batter_id, vs_hand, as_of_date),
    INDEX idx_batter_vs_hand_date (batter_id, vs_hand, as_of_date)
);

-- =============================================================================
-- Odds Snapshots (Strikeout O/U Lines)
-- =============================================================================

CREATE TABLE IF NOT EXISTS odds (
    game_pk INTEGER NOT NULL REFERENCES games(game_pk),
    pitcher_id INTEGER NOT NULL REFERENCES players(player_id),
    line REAL NOT NULL,  -- e.g., 6.5
    price_over REAL NOT NULL CHECK(price_over > 1.0),  -- Decimal odds
    price_under REAL NOT NULL CHECK(price_under > 1.0),
    book TEXT NOT NULL,  -- "draftkings", "fanduel", etc.
    fetched_at TIMESTAMP NOT NULL,  -- When odds fetched (UTC)
    PRIMARY KEY (game_pk, pitcher_id, line, book, fetched_at),
    INDEX idx_game_pitcher_line (game_pk, pitcher_id, line),
    INDEX idx_fetched_at (fetched_at)
);

-- =============================================================================
-- Features (Assembled Feature Vectors for Scoring)
-- =============================================================================

CREATE TABLE IF NOT EXISTS features (
    date DATE NOT NULL,
    game_pk INTEGER NOT NULL REFERENCES games(game_pk),
    pitcher_id INTEGER NOT NULL REFERENCES players(player_id),
    line REAL NOT NULL,

    -- Pitcher form features
    f_k9 REAL,
    f_csw_pct REAL,
    f_whiff_pct REAL,
    f_chase_pct REAL,
    f_zone_pct REAL,
    f_fastball_pct REAL,
    f_slider_pct REAL,
    f_changeup_pct REAL,
    f_curve_pct REAL,
    f_delta_csw_3 REAL,
    f_days_rest INTEGER,

    -- Opponent features
    f_team_k_vs_hand REAL,  -- Team-level (MVP)
    f_lineup_weighted_k_vs_hand REAL,  -- Lineup-level (Phase 1.5)
    f_team_pa_estimate REAL,

    -- Context features
    f_home_away INTEGER CHECK(f_home_away IN (0, 1)),  -- 0=away, 1=home
    f_park_k_factor REAL,
    f_ump_k_factor REAL,  -- Phase 2; 1.0 if not available
    f_weather_run_env_factor REAL,  -- Phase 2; 1.0 if not available

    -- Market features
    f_price_over REAL,
    f_price_under REAL,
    f_book_dispersion REAL,  -- Optional; stdev of implied probs across books

    -- Metadata
    lineup_confirmed BOOLEAN DEFAULT FALSE,
    pitcher_form_missing BOOLEAN DEFAULT FALSE,
    team_split_missing BOOLEAN DEFAULT FALSE,
    features_hash TEXT NOT NULL,  -- SHA256 of feature vector
    as_of TIMESTAMP NOT NULL,  -- When features computed

    PRIMARY KEY (date, game_pk, pitcher_id, line),
    INDEX idx_date_game (date, game_pk)
);

-- =============================================================================
-- Bets (Placed Bets with Stakes, EV, Kelly Fraction)
-- =============================================================================

CREATE TABLE IF NOT EXISTS bets (
    bet_id TEXT PRIMARY KEY,  -- "{date}_{game_pk}_{pitcher_id}_{line}"
    date DATE NOT NULL,
    game_pk INTEGER NOT NULL REFERENCES games(game_pk),
    pitcher_id INTEGER NOT NULL REFERENCES players(player_id),
    pitcher_name TEXT NOT NULL,  -- For logging
    line REAL NOT NULL,
    side TEXT NOT NULL CHECK(side IN ('over', 'under')),
    price_at_bet REAL NOT NULL CHECK(price_at_bet > 1.0),  -- Decimal odds
    p_over REAL NOT NULL CHECK(p_over >= 0 AND p_over <= 1),  -- Model probability
    ev REAL NOT NULL,  -- Expected value
    kelly_frac REAL NOT NULL CHECK(kelly_frac >= 0),  -- Fractional Kelly
    kelly_frac_unclamped REAL,  -- Before clamp (for analysis)
    stake REAL NOT NULL CHECK(stake > 0),  -- Actual stake placed
    bankroll_at_bet REAL NOT NULL,  -- Bankroll when bet placed
    book TEXT NOT NULL,
    model_version TEXT NOT NULL,  -- e.g., "v1.2.3"
    features_hash TEXT NOT NULL,  -- SHA256 of features used
    timestamp TIMESTAMP NOT NULL,  -- When bet placed (UTC)

    -- Caps metadata (JSON or separate table in production)
    caps_applied TEXT,  -- JSON: {"per_bet_cap": 200, "final_stake": 200, "reason": "no_cap_binding"}

    -- Data provenance (JSON)
    data_timestamps TEXT,  -- JSON: {"pitcher_form_as_of": "...", "odds_fetched_at": "..."}

    INDEX idx_date (date),
    INDEX idx_game_pitcher (game_pk, pitcher_id),
    INDEX idx_timestamp (timestamp)
);

-- =============================================================================
-- Closing Lines (Final Odds Before Game Lock)
-- =============================================================================

CREATE TABLE IF NOT EXISTS closing_lines (
    date DATE NOT NULL,
    game_pk INTEGER NOT NULL REFERENCES games(game_pk),
    pitcher_id INTEGER NOT NULL REFERENCES players(player_id),
    line REAL NOT NULL,
    closing_price_over REAL CHECK(closing_price_over > 1.0),
    closing_price_under REAL CHECK(closing_price_under > 1.0),
    book TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL,  -- When closing odds fetched (game start + 5min)
    PRIMARY KEY (date, game_pk, pitcher_id, line, book),
    INDEX idx_date_game_pitcher (date, game_pk, pitcher_id)
);

-- =============================================================================
-- Results (Actual Outcomes)
-- =============================================================================

CREATE TABLE IF NOT EXISTS results (
    date DATE NOT NULL,
    game_pk INTEGER NOT NULL REFERENCES games(game_pk),
    pitcher_id INTEGER NOT NULL REFERENCES players(player_id),
    k_actual INTEGER,  -- Actual strikeouts (NULL if game postponed/data unavailable)
    ip REAL,  -- Innings pitched
    game_status TEXT,  -- "final", "postponed", "data_missing"
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (date, game_pk, pitcher_id),
    INDEX idx_date (date)
);

-- =============================================================================
-- Bet Results (Join Bets + Closing Lines + Results)
-- =============================================================================
-- Note: This can be a VIEW in production (computed on-the-fly)

CREATE TABLE IF NOT EXISTS bet_results (
    bet_id TEXT PRIMARY KEY REFERENCES bets(bet_id),
    date DATE NOT NULL,
    game_pk INTEGER NOT NULL,
    pitcher_id INTEGER NOT NULL,
    line REAL NOT NULL,
    side TEXT NOT NULL,
    price_at_bet REAL NOT NULL,
    stake REAL NOT NULL,
    p_over REAL NOT NULL,
    k_actual INTEGER,  -- Actual strikeouts
    over_outcome INTEGER CHECK(over_outcome IN (0, 1)),  -- 1 if Over hit, 0 if Under
    profit REAL,  -- stake × (odds - 1) if win, else -stake
    roi REAL,  -- profit / stake
    closing_price REAL,  -- Closing odds for our side (Over or Under)
    clv_bps REAL,  -- Closing line value in basis points
    timestamp TIMESTAMP NOT NULL,  -- When result recorded
    INDEX idx_date (date),
    INDEX idx_bet_id (bet_id)
);

-- =============================================================================
-- Training Data (Features + Labels for Model Retraining)
-- =============================================================================
-- Note: In production, may store as Parquet files instead of SQL table

CREATE TABLE IF NOT EXISTS training_samples (
    sample_id INTEGER PRIMARY KEY AUTOINCREMENT,
    date DATE NOT NULL,
    game_pk INTEGER NOT NULL,
    pitcher_id INTEGER NOT NULL,
    line REAL NOT NULL,

    -- All features (same as features table)
    f_k9 REAL,
    f_csw_pct REAL,
    f_whiff_pct REAL,
    f_chase_pct REAL,
    f_zone_pct REAL,
    f_fastball_pct REAL,
    f_slider_pct REAL,
    f_changeup_pct REAL,
    f_curve_pct REAL,
    f_delta_csw_3 REAL,
    f_days_rest INTEGER,
    f_team_k_vs_hand REAL,
    f_lineup_weighted_k_vs_hand REAL,
    f_team_pa_estimate REAL,
    f_home_away INTEGER,
    f_park_k_factor REAL,
    f_ump_k_factor REAL,
    f_weather_run_env_factor REAL,
    f_price_over REAL,
    f_price_under REAL,
    f_book_dispersion REAL,

    -- Label
    over INTEGER NOT NULL CHECK(over IN (0, 1)),  -- 1 if k_actual >= line, else 0

    -- Metadata
    k_actual INTEGER,
    as_of TIMESTAMP NOT NULL,  -- When sample created
    INDEX idx_date (date)
);

-- =============================================================================
-- Umpire Stats (Phase 2)
-- =============================================================================

CREATE TABLE IF NOT EXISTS umpire_stats (
    umpire_name TEXT NOT NULL,
    season INTEGER NOT NULL,
    k_per_game REAL,  -- Avg Ks per game with this umpire
    games_worked INTEGER,
    ump_k_factor REAL,  -- k_per_game / league_avg_k_per_game
    PRIMARY KEY (umpire_name, season)
);

CREATE TABLE IF NOT EXISTS game_umpires (
    game_pk INTEGER NOT NULL REFERENCES games(game_pk),
    umpire_name TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (game_pk)
);

-- =============================================================================
-- Weather (Phase 2)
-- =============================================================================

CREATE TABLE IF NOT EXISTS weather (
    park_id INTEGER NOT NULL REFERENCES parks(park_id),
    game_time TIMESTAMP NOT NULL,
    temp_f REAL,
    humidity_pct REAL,
    wind_speed_mph REAL,
    wind_direction TEXT,  -- "out_to_lf", "in_from_cf", etc.
    weather_run_env_factor REAL,  -- Computed factor (0.95-1.05)
    fetched_at TIMESTAMP NOT NULL,
    PRIMARY KEY (park_id, game_time)
);

-- =============================================================================
-- Audit Logs (Provider Calls, Pipeline Runs, Errors)
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit_logs (
    log_id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    pipeline TEXT,  -- "nightly_etl", "gameday_t-6h", etc.
    provider TEXT,  -- "mlb_stats", "statcast", "odds", etc.
    endpoint TEXT,  -- "/schedule", "/pitcher_game_logs", etc.
    status_code INTEGER,  -- HTTP status or 0 for success
    duration_ms INTEGER,  -- Request duration
    cache_hit BOOLEAN,
    error_message TEXT,
    INDEX idx_timestamp (timestamp),
    INDEX idx_pipeline (pipeline)
);

-- =============================================================================
-- Config Snapshots (Track Config Changes Over Time)
-- =============================================================================

CREATE TABLE IF NOT EXISTS config_snapshots (
    config_id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    config_yaml TEXT NOT NULL,  -- Full YAML config as text
    hash TEXT NOT NULL,  -- SHA256 of config for quick comparison
    INDEX idx_timestamp (timestamp)
);

-- =============================================================================
-- Indexes for Common Queries
-- =============================================================================

-- Query: "Get all bets for a given date"
CREATE INDEX IF NOT EXISTS idx_bets_date ON bets(date);

-- Query: "Get all results for a given pitcher"
CREATE INDEX IF NOT EXISTS idx_results_pitcher ON results(pitcher_id);

-- Query: "Get features for scoring at T-30m"
CREATE INDEX IF NOT EXISTS idx_features_date_game ON features(date, game_pk);

-- Query: "Get closing lines for CLV calculation"
CREATE INDEX IF NOT EXISTS idx_closing_date_pitcher ON closing_lines(date, pitcher_id);

-- =============================================================================
-- Views (Computed Queries for Common Use Cases)
-- =============================================================================

-- View: Daily bet summary (total stakes, profit, ROI, CLV)
CREATE VIEW IF NOT EXISTS daily_summary AS
SELECT
    date,
    COUNT(*) AS bets_placed,
    SUM(stake) AS total_stakes,
    SUM(profit) AS total_profit,
    AVG(roi) AS avg_roi,
    AVG(clv_bps) AS avg_clv_bps,
    SUM(CASE WHEN over_outcome = 1 THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS hit_rate
FROM bet_results
GROUP BY date
ORDER BY date DESC;

-- View: Model performance metrics (rolling 7-day Brier, log-loss)
-- Note: Brier/log-loss computed in application code, not SQL

-- =============================================================================
-- Notes
-- =============================================================================

-- 1. Use TIMESTAMP for all time fields (UTC); convert to local in application.
-- 2. Use REAL for probabilities, rates, factors; constrain to [0, 1] where applicable.
-- 3. Use CHECK constraints to enforce data integrity (e.g., odds > 1.0, sides IN ('over', 'under')).
-- 4. Add indexes on all foreign keys and common query patterns.
-- 5. For large datasets (>1M rows), consider partitioning by date (PostgreSQL) or sharding.
-- 6. Backup strategy: daily snapshots of bets, results, and training_samples tables.
-- 7. Retention: Keep raw odds snapshots for 60 days; aggregate to closing_lines for long-term.
