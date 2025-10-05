# Risk & Guards

This document catalogs all risks, monitoring systems, kill-switches, and compliance guardrails.

---

## 1. Market Microstructure Risks

### Slippage

- **Risk**: Odds move between decision and execution; get filled at worse price.
- **Mitigation**:
  - Fetch odds at T-30m (close to execution time).
  - Set max acceptable price change: if current odds > bet_odds × 1.02, skip bet.
  - Use limit orders (if API supports) instead of market orders.
- **Monitoring**: Log `price_at_decision` vs `price_at_execution`; alert if slippage > 2% on >20% of bets.

### Partial Fills

- **Risk**: Bet only partially filled (insufficient liquidity); effective stake < intended.
- **Mitigation**:
  - Require `min_liquidity` threshold (e.g., $1000 available) before placing bet.
  - Cap stake per bet to avoid market impact.
- **Monitoring**: Log fill amounts; if partial fills >10% of bets, reduce stake caps.

### Betting Limits

- **Risk**: Sportsbook limits winning players; reduce max stake or ban.
- **Mitigation**:
  - Diversify across multiple books.
  - Keep individual book exposure < 30% of total stakes.
  - Use "square" bet patterns (mix favorites/dogs, don't concentrate on one pitcher).
- **Monitoring**: Track limits per book; rotate books if limited.

### Max Spread

- **Risk**: High vig (spread) reduces EV; even correct model loses money.
- **Mitigation**:
  - Filter bets: `spread = (1/price_over + 1/price_under - 1) <= max_spread` (default 0.05 = 5%).
  - Prefer books with tighter spreads (DraftKings, FanDuel often <5%; offshore books can be 8%+).
- **Config**: `config.market.max_spread_cents = 5` (adjustable per book if multi-book).

---

## 2. Model Risks

### Model Drift

- **Risk**: Model trained on historical data; real-world distribution shifts (e.g., rule changes, pitcher injuries, new analytics adoption by teams).
- **Detection**:
  - **Weekly calibration check**: Compute Brier score on last 7 days of bets; compare to expected (train/test Brier ± tolerance).
  - **Trigger**: If rolling 7-day Brier > train Brier × 1.05 (5% degradation), flag for retrain.
- **Response**:
  - Retrain model on last 60 days of data.
  - Compare new model vs old on validation set; deploy if improved.
  - If Brier continues to degrade post-retrain, halt betting and investigate (possible structural shift).

### Overfitting

- **Risk**: Model fits noise in training data; poor generalization.
- **Detection**: Train Brier << Validation Brier (>10% gap).
- **Mitigation**:
  - Use regularization (L2 for logistic, max_depth/min_child_weight for XGBoost).
  - Early stopping on validation loss.
  - Test on strict time-based holdout (no data leakage).
- **Monitoring**: Track train/val/test Brier in model metadata; alert if val/test gap > 0.03.

### Feature Leakage

- **Risk**: Accidentally include future information (e.g., closing odds, actual Ks) in features.
- **Mitigation**:
  - **Time honesty**: Log `as_of` timestamp for every feature; audit in post-game analysis.
  - **Code review**: Require 2-person review of feature engineering code.
  - **Unit tests**: Assert no features contain data from after bet timestamp.
- **Detection**: If model Brier unrealistically low (<0.20) or hit rate >55%, audit for leakage.

### Model File Corruption

- **Risk**: Model file corrupted (disk error, incomplete write during retrain).
- **Detection**: Model load error at pipeline start.
- **Response**:
  - **Fallback**: Keep previous model version in `data/models/previous_model.pkl`; load if current fails.
  - **Alert**: Halt betting; send critical alert to operator.
  - **Manual fix**: Restore from backup or retrain.

---

## 3. Correlation & Concentration Risks

### Same-Game Exposure

- **Risk**: Betting on both starters in same game → outcomes correlated (weather, umpire, etc.).
- **Mitigation**:
  - **Cap**: If betting on multiple pitchers in same game, limit combined stake to 1.5× single-bet cap.
  - **Example**: If `per_bet_cap = $200`, max total stake for both pitchers in Game X = $300.
- **Config**: `config.betting.same_game_multiplier = 1.5`

### Same-Slate Exposure

- **Risk**: Betting on all games in single slate → correlated factors (e.g., all games in same weather system, league-wide umpire strike zone shift).
- **Mitigation**:
  - **Per-slate cap**: Total stakes across all bets today ≤ `per_slate_cap` (default $1500).
  - **Diversify**: Prefer spreading bets across multiple days if model identifies edges on consecutive days.
- **Config**: `config.betting.per_slate_cap_usd = 1500`

### Team/Pitcher Over-Concentration

- **Risk**: Repeatedly betting same pitcher or against same team → idiosyncratic risk (injury, hot streak end).
- **Monitoring**: Track exposure by pitcher_id and opponent_team_id over rolling 7 days.
- **Alert**: If >30% of bankroll staked on single pitcher in 7 days, flag for review.
- **Mitigation**: Manual review; consider skipping next bet on that pitcher even if EV positive.

### Alt-Line Correlation

- **Risk**: Betting K Over 6.5 and Over 7.5 for same pitcher → perfect correlation; doubling risk.
- **Mitigation**: **Per-market cap**: Max 1 bet per (pitcher, side) pair; no multiple alt-lines.
- **Implementation**: Filter bet selection to exclude duplicate (pitcher_id, side) tuples.

---

## 4. Kill-Switches (Automatic Halts)

### Daily Loss Limit

- **Trigger**: Cumulative loss today > `daily_loss_limit_pct` × bankroll (default 5%).
- **Action**: Halt all betting for remainder of day; log kill-switch event.
- **Alert**: Send critical alert (Slack/PagerDuty) to operator.
- **Manual override**: Operator can reset after review.
- **Config**: `config.risk.daily_loss_limit_pct = 5`

### CLV Degradation

- **Trigger**: Rolling 3-day average CLV < `-20 bps` (getting worse prices than closing).
- **Rationale**: Negative CLV → losing to market consensus → model edge questionable.
- **Action**: Halt betting; trigger model retrain; log event.
- **Alert**: Critical alert to operator.
- **Manual override**: Operator reviews CLV by bet type (e.g., maybe one book had bad prices; switch books).
- **Config**: `config.risk.stop_if_clv_below_bps = -20`, `stop_if_consecutive_clv_losses = 3`

### Drawdown Limit

- **Trigger**: Peak-to-trough drawdown > `drawdown_limit_pct` (default 10%) since deployment.
- **Action**: Halt betting; require operator review and manual restart.
- **Rationale**: Large drawdown may indicate model failure or bad luck streak; pause to investigate.
- **Config**: `config.risk.drawdown_limit_pct = 10`

### Model Load Failure

- **Trigger**: Model file fails to load (corruption, version mismatch, missing dependencies).
- **Action**: Halt pipeline; alert operator; do not place any bets.
- **Fallback**: Load previous model version if available; if fallback fails, halt completely.

### Feature Hash Mismatch

- **Trigger**: Feature vector schema in production differs from model training schema.
- **Detection**: `features_hash` computed in pipeline != `features_hash` in model metadata.
- **Action**: Halt betting; log error; alert operator.
- **Rationale**: Prevents silent failures from feature engineering changes (e.g., column reordering, missing features).

---

## 5. Data Quality & Availability Risks

### Provider Outage

- **Risk**: MLB Stats API, Statcast, or Odds provider unavailable (downtime, rate limit exhaustion).
- **Detection**: HTTP 5xx, timeouts, or 429 responses.
- **Mitigation**:
  - **Retry**: Exponential backoff (1s, 2s, 4s); max 3 retries.
  - **Fallback**: Use cached data if fresh (<6h for odds, <24h for pitcher stats).
  - **Skip**: If no fallback available, skip bet for that game (do not fabricate data).
- **Monitoring**: Track error rate per provider; alert if >10% of requests fail in 1h.

### Stale Cache

- **Risk**: Cached data outdated; using yesterday's stats for today's game.
- **Detection**: Check `as_of` timestamp in cache; if `today - as_of > threshold`, flag stale.
- **Mitigation**: Attempt on-demand fetch; if fails, skip bet or use long-term mean + flag uncertainty.
- **Config**: `config.cache.max_staleness_hours = 24` (pitcher stats), `6` (odds).

### Missing Lineups

- **Risk**: Lineup unavailable at T-30m (late scratch, pitcher change).
- **Mitigation**: Fallback to team baseline `team_k_vs_hand` (same as T-6h).
- **Impact**: Slightly less accurate features, but model should still work (team baseline is reasonable proxy).
- **Monitoring**: Log `lineup_confirmed` boolean in bet ticket; track accuracy with vs without lineup.

### Incorrect Data

- **Risk**: Provider returns wrong data (e.g., wrong pitcher ID, wrong K count).
- **Detection**: Sanity checks:
  - K/9 in reasonable range (2–15); if outside, flag.
  - Pitcher ID exists in MLB roster.
  - Odds prices > 1.0 (invalid if ≤1.0).
- **Response**: Log warning; skip bet if sanity check fails.
- **Post-hoc audit**: Cross-check actual Ks from multiple sources (MLB Stats API vs ESPN vs official box score).

---

## 6. Compliance & Terms-of-Service

### API Rate Limits

- **Requirement**: Respect all provider rate limits; do not scrape aggressively.
- **MLB Stats API**: ~100 req/min observed safe; implement exponential backoff on 429.
- **Statcast/pybaseball**: ~30 req/min; space out bulk queries.
- **Odds API**: Monthly quota (500 free, 10k paid); track usage; alert at 80%.
- **Enforcement**: Hard-code rate limit sleeps; use request throttling library (e.g., `ratelimit` decorator).

### No Unauthorized Scraping

- **Policy**: Only use official/public APIs or licensed data feeds; no scraping HTML/JavaScript-rendered sites.
- **Prohibited**:
  - Scraping sportsbook odds directly from websites (violates TOS; IP ban risk).
  - Scraping paywalled data (Baseball Prospectus, FanGraphs premium without subscription).
- **Allowed**:
  - MLB Stats API (public, free).
  - Pybaseball (wraps Baseball Savant public exports).
  - Odds API (licensed, paid).

### Logging & Audit Trail

- **Requirement**: Log all data fetches with source, timestamp, endpoint for compliance audit.
- **Fields**: `provider`, `endpoint`, `timestamp`, `status_code`, `response_size`, `cache_hit`
- **Retention**: 1 year for audit logs.
- **Purpose**: Prove data sourced legitimately if questioned by regulator or provider.

### Responsible Gambling

- **Self-imposed limits**: Do not exceed `bankroll` (track separately from personal funds).
- **No chasing losses**: If daily loss limit hit, halt (do not override to "win it back").
- **Transparency**: Log all bets, stakes, outcomes for personal review.

---

## 7. Monitoring & Alerting

### Metrics to Track (Prometheus + Grafana)

| Metric | Threshold | Alert |
|--------|-----------|-------|
| Rolling 7-day Brier | > 0.25 | Warning |
| Rolling 7-day CLV | < -20 bps | Critical |
| Daily ROI | < -5% | Warning |
| Drawdown from peak | > 10% | Critical |
| Provider error rate | > 10% (1h window) | Warning |
| Cache staleness | > 24h (pitcher), >6h (odds) | Warning |
| Model load failure | Any | Critical |
| Feature hash mismatch | Any | Critical |
| Quota usage (Odds API) | > 80% | Warning |

### Alerts Channels

- **Critical**: PagerDuty (immediate response required; betting halted).
- **Warning**: Slack (review within 1h; may continue betting).
- **Info**: Email daily summary.

### Daily Review Checklist

- [ ] Review daily report: ROI, CLV, Brier, hit rate.
- [ ] Check for alerts (Slack, PagerDuty).
- [ ] Verify all bets logged in `data/outputs/bets/`.
- [ ] Spot-check 2–3 bets: feature values reasonable, EV calc correct.
- [ ] Review provider error logs; investigate if >5% error rate.
- [ ] Check bankroll balance vs ledger; reconcile any discrepancies.

---

## 8. Incident Response Playbook

### Scenario: Negative CLV for 3 Days

**Steps**:

1. **Halt betting** (automatic kill-switch).
2. **Investigate**:
   - Check odds source: are we getting stale prices? (compare our fetch timestamp vs closing timestamp)
   - Check model: is Brier degrading? (rolling 7-day Brier vs baseline)
   - Check book: did one book start shading our bets? (segment CLV by book)
3. **Remediate**:
   - If stale prices: reduce odds cache TTL; fetch closer to bet time.
   - If model drift: retrain on recent data.
   - If book shading: switch to different book for that market.
4. **Restart**: After fix deployed, manually enable betting; monitor closely for 2 days.

### Scenario: Model Predicts Unrealistic Probabilities (e.g., p_over = 0.95)

**Steps**:

1. **Halt betting** (manual override).
2. **Investigate**:
   - Check feature values: any outliers? (e.g., k9 = 50 due to data error)
   - Check model calibration: plot predicted probs vs actual outcomes on recent data.
   - Check for feature leakage: audit `as_of` timestamps.
3. **Remediate**:
   - If data error: fix provider or add sanity checks.
   - If model miscalibrated: retrain with more data or adjust calibration method.
   - If leakage: fix feature pipeline; retrain from scratch.
4. **Test**: Validate on holdout set before redeploying.

### Scenario: Daily Loss Limit Hit

**Steps**:

1. **Betting halted** (automatic).
2. **Review**: Were losses due to bad luck (coin flips went against us) or model failure (predicted wrong)?
   - Check Brier score today: if ~0.23 (expected), likely variance.
   - Check CLV: if positive, we got good prices but unlucky outcomes.
3. **Decision**:
   - If variance: resume tomorrow (reset daily limit).
   - If model issue: investigate (see above scenarios).
4. **Adjust**: If repeated daily losses, reduce `per_bet_cap` or `kelly_lambda` to lower volatility.

---

## 9. Compliance Notes

### Legal Jurisdictions

- **User responsibility**: Ensure sports betting legal in your jurisdiction.
- **System design**: Neutral to jurisdiction; does not facilitate illegal activity.
- **Disclaimer**: This is a personal research/tracking tool; user places bets manually via licensed books.

### Data Licensing

- **MLB Stats API**: Free, public; no commercial restrictions for personal use.
- **Statcast/pybaseball**: Public Baseball Savant data; cite source.
- **Odds API**: Paid subscription required for commercial use; free tier for personal research (check TOS).

### No Market Manipulation

- **Policy**: Do not place bets to intentionally move lines (spoofing/layering).
- **Practice**: Stakes small relative to market (max $200/bet << typical market liquidity $10k+).

---

## Summary: Defense-in-Depth

| Layer | Guards |
|-------|--------|
| **Pre-bet** | EV threshold, spread filter, liquidity check, caps (per-bet/slate/same-game) |
| **Execution** | Price staleness check, slippage limit, partial fill handling |
| **Post-bet** | CLV tracking, Brier monitoring, daily loss limit |
| **Model** | Time honesty, feature hash audit, calibration checks, drift detection |
| **Data** | Sanity checks, retry logic, fallback to cache, provider error alerts |
| **Compliance** | Rate limits, no unauthorized scraping, audit logs, TOS adherence |
| **Kill-switches** | Daily loss limit, CLV degradation, drawdown cap, model load failure |

All thresholds configurable via [CONFIG_TEMPLATE.yaml](CONFIG_TEMPLATE.yaml).
