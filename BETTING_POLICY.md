# Betting Policy

This document defines the rules for bet selection, stake sizing, exposure limits, and audit requirements.

---

## 1. Expected Value (EV) Calculation

**Definition**: EV is the average profit/loss per dollar wagered, assuming our model probabilities are correct.

**Formula** (for decimal odds `O`):
```
EV = p_over × (O - 1) - (1 - p_over)
```

**Derivation**:
- **If Over hits** (probability `p_over`): profit = `stake × (O - 1)`, normalized to stake = profit per dollar = `O - 1`
- **If Under hits** (probability `1 - p_over`): loss = `-stake`, normalized = `-1`
- **Expected profit per dollar**: `p_over × (O - 1) + (1 - p_over) × (-1)`

**Example**:
- Model: `p_over = 0.58` (58% chance Over hits)
- Market odds: `O = 1.91` (implied prob = 1/1.91 = 52.4%)
- EV = `0.58 × (1.91 - 1) - (1 - 0.58)`
- EV = `0.58 × 0.91 - 0.42`
- EV = `0.5278 - 0.42 = 0.1078` → **+10.78%**

**Interpretation**:
- EV > 0: Profitable bet in long run (assuming model is calibrated).
- EV = 0: Break-even (no edge).
- EV < 0: Losing bet (do not place).

**Threshold**: Only bet if `EV >= ev_min` (default **0.03** = 3%).

**Rationale**: 3% threshold provides cushion for:
- Model miscalibration (~1–2% error).
- Slippage and fees (~0.5–1%).
- Variance buffer.

**Config**: `config.betting.ev_min = 0.03`

---

## 2. Fractional Kelly Criterion (Stake Sizing)

**Definition**: Optimal bet size that maximizes long-run logarithmic growth of bankroll, adjusted by fraction `λ` to reduce volatility.

**Formula**:
```
f = λ × ((O × p_over - 1) / (O - 1))
```
where:
- `f` = fraction of bankroll to wager
- `λ` = Kelly fraction (default 0.2 = 20% of full Kelly)
- `O` = decimal odds
- `p_over` = model probability

**Derivation** (full Kelly):
- **Edge**: `b = O - 1` (profit multiplier if win)
- **Win prob**: `p = p_over`
- **Full Kelly**: `f_full = (b × p - (1 - p)) / b = (p × O - 1) / (O - 1)`
- **Fractional Kelly**: `f = λ × f_full`

**Example** (continued from EV example):
- `p_over = 0.58`, `O = 1.91`, `λ = 0.2`
- Full Kelly: `f_full = (1.91 × 0.58 - 1) / (1.91 - 1) = (1.1078 - 1) / 0.91 = 0.1184` (11.84% of bankroll)
- Fractional Kelly: `f = 0.2 × 0.1184 = 0.02368` → **2.37% of bankroll**

**Clamp**: `f_clamped = max(0, min(f, kelly_max))`
- `kelly_max` default = **0.02** (2% of bankroll max per bet)
- Prevents over-betting on extreme outliers (e.g., model says 90% but odds 2.0 → full Kelly would suggest 40%+).

**Stake Calculation**:
```
stake_kelly = f_clamped × bankroll
```

**Config**:
- `config.betting.kelly_lambda = 0.2` (conservative; reduces volatility by 80% vs full Kelly)
- `config.betting.kelly_max = 0.02` (hard cap at 2% per bet)

**Rationale for Fractional Kelly**:
- **Full Kelly** maximizes growth but has **50% drawdown** risk in realistic scenarios (model miscalibration, fat tails).
- **λ = 0.2–0.25** reduces drawdown to ~10–15% while retaining 80%+ of growth rate.
- **λ = 0.5** ("half Kelly") is common in literature; we use λ=0.2 for extra safety in MVP (model unproven).

---

## 3. Bet Selection Filters

A bet must pass **all** filters to be placed:

### Filter 1: Minimum EV
```
ev >= config.betting.ev_min  (default 0.03)
```

### Filter 2: Positive Kelly Fraction
```
f > 0
```
(Redundant if EV > 0, but explicit check prevents edge cases.)

### Filter 3: Minimum Liquidity
```
available_liquidity >= config.market.min_liquidity  (default $1000)
```
- **Purpose**: Avoid moving market; reduce slippage and partial fill risk.
- **Source**: Some odds APIs provide liquidity; if unavailable, skip check (assume sufficient for $200 bets).

### Filter 4: Maximum Spread
```
spread = (1/price_over + 1/price_under - 1) <= config.market.max_spread_cents / 100
```
- **Default**: `max_spread_cents = 5` → spread ≤ 0.05 (5% vig).
- **Rationale**: High vig erodes edge; even 3% EV becomes breakeven after 5% vig + slippage.

### Filter 5: Minimum Odds
```
price_over >= 1.4
```
- **Purpose**: Avoid very high-juice favorites (e.g., -500 = 1.2 decimal); small model error → large loss.
- **Threshold**: 1.4 decimal ≈ -250 American ≈ 71% implied prob (reasonable range).

### Filter 6: No Duplicate Markets
```
(pitcher_id, side) not in already_bet_today
```
- **Purpose**: Prevent betting multiple alt-lines for same pitcher (e.g., Over 6.5 and Over 7.5 → perfect correlation).
- **Implementation**: Track `(pitcher_id, "over")` tuples; skip if duplicate.

---

## 4. Exposure Caps

Even if a bet passes all filters, cap the stake to manage risk:

### Cap 1: Per-Bet Cap
```
stake = min(stake_kelly, per_bet_cap)
```
- **Default**: `per_bet_cap = $200`
- **Purpose**: Limit single-bet variance; diversify across multiple bets.

### Cap 2: Per-Slate Cap
```
total_stakes_today + stake <= per_slate_cap
```
- **Default**: `per_slate_cap = $1500`
- **Purpose**: Limit daily exposure; correlated outcomes across same-day games (weather, umpire trends, lineup leaks).
- **Implementation**: Track cumulative stakes; stop betting when cap reached (even if more +EV opportunities exist).

### Cap 3: Same-Game Correlation Cap
```
If betting on multiple pitchers in same game:
  combined_stake <= per_bet_cap × same_game_multiplier
```
- **Default**: `same_game_multiplier = 1.5`
- **Example**: If `per_bet_cap = $200`, max combined stake for both starters in Game X = $300.
- **Purpose**: Outcomes correlated via umpire, weather, lineup changes; limit joint exposure.

### Cap 4: Bankroll Fraction (Implied by Kelly)
```
stake <= bankroll × kelly_max
```
- **Default**: `kelly_max = 0.02` → max 2% of bankroll per bet.
- **Already enforced** in Kelly clamp; explicit check here for safety.

**Final Stake**:
```python
stake = min(
    stake_kelly,
    per_bet_cap,
    per_slate_cap - total_stakes_today,
    bankroll × kelly_max
)
# If same-game correlation: further reduce
if same_game:
    stake = min(stake, per_bet_cap × same_game_multiplier - same_game_stakes_so_far)
```

---

## 5. Worked Example

**Setup**:
- Bankroll: $10,000
- Model: `p_over = 0.58`
- Market: Over 6.5 strikeouts at `price_over = 1.91`
- Config: `ev_min = 0.03`, `kelly_lambda = 0.2`, `kelly_max = 0.02`, `per_bet_cap = 200`, `per_slate_cap = 1500`
- Today's stakes so far: $600

**Step 1: Compute EV**
```
EV = 0.58 × (1.91 - 1) - (1 - 0.58)
   = 0.58 × 0.91 - 0.42
   = 0.5278 - 0.42
   = 0.1078  (10.78%)
```
✅ **Pass Filter 1**: EV = 10.78% ≥ 3%

**Step 2: Kelly Fraction**
```
f_full = (1.91 × 0.58 - 1) / (1.91 - 1)
       = (1.1078 - 1) / 0.91
       = 0.1184  (11.84%)
f = 0.2 × 0.1184 = 0.02368
f_clamped = min(0.02368, 0.02) = 0.02  (clamped at kelly_max)
```
✅ **Pass Filter 2**: f = 2% > 0

**Step 3: Check Filters 3–5**
- Liquidity: assume $2000 available ≥ $1000 ✅
- Spread: `1/1.91 + 1/1.95 - 1 = 0.524 + 0.513 - 1 = 0.037` (3.7%) ≤ 5% ✅
- Min odds: 1.91 ≥ 1.4 ✅
- No duplicate: pitcher not already bet today ✅

**Step 4: Compute Stake**
```
stake_kelly = 0.02 × 10000 = $200
stake = min(
    200,              # Kelly stake
    200,              # per_bet_cap
    1500 - 600,       # per_slate_cap remaining = $900
    10000 × 0.02      # bankroll × kelly_max = $200
) = $200
```

**Final**: Place bet of **$200** on Over 6.5 at 1.91.

**Expected Profit**:
```
expected_profit = stake × EV = 200 × 0.1078 = $21.56
```

**Possible Outcomes**:
- **If Over hits** (58% chance): profit = `200 × (1.91 - 1) = $182`
- **If Under hits** (42% chance): loss = `-$200`
- **Long-run average** (over many similar bets): profit ≈ `$21.56` per bet.

---

## 6. Audit Fields (Logged with Every Bet)

**Purpose**: Trace decision process; enable post-hoc analysis and compliance.

**Required fields** in bet ticket (`data/outputs/bets/{date}.jsonl`):

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
  "ev": 0.1078,
  "kelly_frac": 0.02,
  "kelly_frac_unclamped": 0.02368,
  "stake": 200.00,
  "bankroll_at_bet": 10000.00,
  "book": "draftkings",
  "model_version": "v1.2.3",
  "features_hash": "a3f2b1c9d8e7f6a5b4c3d2e1",
  "data_timestamps": {
    "pitcher_form_as_of": "2025-04-14T00:45:00Z",
    "team_split_as_of": "2025-04-14T00:40:00Z",
    "odds_fetched_at": "2025-04-15T18:25:00Z",
    "lineup_confirmed": true
  },
  "caps_applied": {
    "per_bet_cap": 200,
    "per_slate_cap": 1500,
    "slate_stakes_before": 600,
    "kelly_stake": 200,
    "final_stake": 200,
    "reason": "no_cap_binding"
  },
  "filters_passed": {
    "min_ev": true,
    "positive_kelly": true,
    "min_liquidity": true,
    "max_spread": true,
    "min_odds": true,
    "no_duplicate": true
  }
}
```

**Rationale**:

- **`bet_id`**: Unique identifier (date + game_pk + pitcher_id + line).
- **`timestamp`**: Exact bet placement time (UTC).
- **`model_version`**: Track which model made prediction (for A/B tests, rollbacks).
- **`features_hash`**: SHA256 of feature vector; detect schema drift.
- **`data_timestamps`**: Prove time honesty (all data as-of ≤ timestamp).
- **`caps_applied`**: Document which cap was binding (e.g., slate cap reduced stake from $237 → $200).
- **`filters_passed`**: Audit trail (confirm all filters passed).

**Storage**: Append-only JSONL (one line per bet); enables streaming analysis.

---

## 7. Correlation Handling

### Same-Game Exposure

**Scenario**: Betting on both starting pitchers in Game X (e.g., deGrom Over 6.5, opponent starter Over 5.5).

**Correlation**: Both bets affected by same umpire, weather, lineup changes, game pace.

**Rule**:
```
If len(pitchers_in_game) > 1:
    max_combined_stake = per_bet_cap × same_game_multiplier
```

**Default**: `same_game_multiplier = 1.5` → max $300 combined for both pitchers.

**Implementation**:
1. Track `game_pk → [bet1, bet2]` mapping.
2. Before placing bet2 in same game, compute `stake1 + stake2 ≤ 300`.
3. If violated, reduce `stake2` or skip bet2.

### Alt-Line Correlation

**Scenario**: Betting deGrom Over 6.5 and Over 7.5 (two lines for same pitcher).

**Correlation**: Perfect (if hits 7.5, automatically hits 6.5).

**Rule**: **Forbidden**. Only one bet per `(pitcher_id, side)` tuple.

**Implementation**: Track `(pitcher_id, "over")` set; skip duplicates.

---

## 8. Bet Timing & Execution

### When to Bet

**Primary window**: **T-30m** (30 min before first pitch).

**Rationale**:
- Lineups confirmed (if using lineup features).
- Odds relatively stable (less slippage than T-6h).
- Sufficient time to place bet before lock.

**Fallback**: If odds significantly better at T-6h (e.g., EV = 8% at T-6h vs 3% at T-30m), consider betting early; log `bet_timing = "early"` in ticket.

### Order Execution

**Manual** (MVP):
1. System outputs bet tickets to CLI or web UI.
2. Operator manually places bets via book website/app.
3. Operator logs actual fill price and stake (may differ from planned due to slippage).

**Automated** (Phase 2+):
1. Integrate book APIs (DraftKings, FanDuel if available).
2. Place limit orders at `price_decimal` or better.
3. Log confirmation response (fill price, stake, order ID).

### Slippage Handling

**Limit**: If current price > planned price × 1.02 (2% worse), skip bet.

**Example**: Plan to bet at 1.91; if current price drops to 1.87 (implied 53.5% vs 52.4%), recalculate EV:
```
EV_new = 0.58 × (1.87 - 1) - 0.42 = 0.5046 - 0.42 = 0.0846 (8.46%)
```
Still > 3% threshold → place bet at 1.87; log `slippage = -0.04` (price moved against us).

If new EV < 3% or price > 1.91 × 1.02 = 1.95, skip bet.

---

## 9. Bankroll Management

### Initial Bankroll

**Recommendation**: Set aside dedicated betting bankroll separate from personal funds.

**Minimum**: $5,000 (allows 25–50 bets at $100–$200 stakes before needing to reassess).

**Optimal**: $10,000+ (reduces volatility; allows 2% stakes = $200/bet).

### Updating Bankroll

**Method 1: Fixed bankroll** (conservative; MVP default):
- Set `bankroll = $10,000` at start.
- Do **not** adjust for wins/losses during season.
- **Rationale**: Prevents over-betting after hot streak (gambler's fallacy); maintains discipline.
- **Recalculate**: At end of season (or after 500 bets), reset bankroll to `initial + cumulative_profit`.

**Method 2: Dynamic bankroll** (Phase 2):
- Update `bankroll = current_balance` daily.
- **Pros**: Stakes grow with bankroll (compound growth).
- **Cons**: Stakes shrink after losses (reduces opportunity to "bet back" if model has edge).
- **Hybrid**: Update monthly instead of daily (smooths variance).

**Config**: `config.betting.bankroll_mode = "fixed"` (MVP) or `"dynamic"` (Phase 2).

---

## 10. Daily Loss Limit (Kill-Switch)

**Rule**: If cumulative loss today > `daily_loss_limit_pct × bankroll`, halt betting.

**Default**: `daily_loss_limit_pct = 5%` → max loss = $500 on $10k bankroll.

**Implementation**:
```python
if total_profit_today < -1 * (bankroll * daily_loss_limit_pct):
    halt_betting()
    log_kill_switch("daily_loss_limit")
    alert_operator()
```

**Rationale**: Protects against catastrophic days (model failure, bad luck streak, data error); forces cooldown and review.

**Override**: Manual only (operator must investigate before resuming).

---

## 11. Weekly Reconciliation

**Every Monday**:

1. **Sum stakes**: Total wagered last 7 days.
2. **Sum profit**: Total profit/loss last 7 days.
3. **Compute ROI**: `profit / stakes`.
4. **Compare to expected**: If ROI < -5% and CLV < 0, trigger investigation (see RISK_AND_GUARDS.md).
5. **Adjust bankroll** (if using dynamic mode): `bankroll_new = bankroll_old + profit_last_week`.

---

## 12. Config Summary

**Defaults** (in `CONFIG_TEMPLATE.yaml`):

```yaml
betting:
  ev_min: 0.03               # Min EV (3%)
  kelly_lambda: 0.2          # Fractional Kelly (20% of full)
  kelly_max: 0.02            # Max stake per bet (2% of bankroll)
  per_bet_cap_usd: 200       # Absolute max stake per bet
  per_slate_cap_usd: 1500    # Max total stakes per day
  same_game_multiplier: 1.5  # Max combined stake for same-game bets
  bankroll_mode: "fixed"     # "fixed" or "dynamic"
  bankroll_usd: 10000        # Initial bankroll (or current if dynamic)

market:
  min_liquidity: 1000        # Min available liquidity (if known)
  max_spread_cents: 5        # Max vig (5%)
  min_odds_decimal: 1.4      # Min acceptable odds
  slippage_tolerance: 0.02   # Max price change (2%)

risk:
  daily_loss_limit_pct: 5    # Max daily loss (5% of bankroll)
```

**Tuning**: Adjust `kelly_lambda` (0.15–0.25) and `ev_min` (2%–5%) based on model calibration and risk tolerance.

---

## Summary: Bet Placement Workflow

1. **Compute EV** for each opportunity.
2. **Filter**: EV ≥ 3%, spread ≤ 5%, odds ≥ 1.4, liquidity OK, no duplicate.
3. **Size**: `stake = kelly_lambda × kelly_full`, clamped to [0, 2% bankroll].
4. **Cap**: Apply per-bet ($200), per-slate ($1500), same-game (1.5×) limits.
5. **Log**: Write bet ticket with all audit fields.
6. **Execute**: Place bet (manual or API); log actual fill.
7. **Monitor**: Track CLV, ROI, Brier; halt if daily loss > 5% or CLV < -20 bps for 3 days.

All decisions logged for transparency and continuous improvement.
