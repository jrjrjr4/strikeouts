# Evaluation

This document defines metrics, evaluation procedures, and experiment design for validating model performance and betting edge.

---

## Primary Metrics

### 1. CLV (Closing Line Value)

**Definition**: Difference between the price we got when placing the bet vs the closing price (final price before game start).

**Formula**:
```
bet_implied_prob = 1 / price_at_bet
closing_implied_prob = 1 / closing_price
clv_bps = (closing_implied_prob - bet_implied_prob) × 10000
```

**Example**:
- Bet Over 6.5 at 1.91 (52.4% implied)
- Closing price: 1.85 (54.1% implied)
- CLV = (0.541 - 0.524) × 10000 = **+170 bps**

**Interpretation**:
- **Positive CLV**: We got better odds than the closing consensus → strong validation of edge (market agrees we found value).
- **Negative CLV**: We got worse odds → may indicate stale data, poor timing, or model error.
- **Target**: Average CLV > 0 (ideally +50 to +100 bps over 100+ bets).

**Why CLV is critical**:
- **Leading indicator**: CLV correlates with long-term profitability more reliably than short-term ROI (which has high variance).
- **Sharp vs square**: Positive CLV distinguishes skilled bettors from lucky ones.
- **Model validation**: Even if we have losing week due to variance, positive CLV confirms model is directionally correct.

**Data source**: Log `price_at_bet` in bet ticket; fetch `closing_price` post-game from odds provider.

---

### 2. Brier Score

**Definition**: Mean squared error of probabilistic predictions.

**Formula**:
```
Brier = (1/N) × Σ(p_over - over_outcome)²
```
where `over_outcome ∈ {0, 1}` is actual result.

**Example**:
- Bet 1: p_over = 0.60, actual = 1 (Over hit) → squared error = (0.60 - 1.0)² = 0.16
- Bet 2: p_over = 0.55, actual = 0 (Under hit) → squared error = (0.55 - 0.0)² = 0.3025
- Brier = (0.16 + 0.3025) / 2 = **0.231**

**Benchmark**:
- **Random guess** (always predict 50%): Brier = 0.25
- **Well-calibrated model**: Brier < 0.24 (better than random)
- **Target MVP**: Brier < 0.23 on test set and production bets

**Decomposition**:
```
Brier = Calibration + Refinement - Uncertainty
```
- **Calibration**: How close predicted probs match observed frequencies (we want low).
- **Refinement**: Resolution/discrimination (higher is better; measures spread of predictions).
- **Uncertainty**: Inherent variance in outcomes (constant for given dataset).

**Usage**:
- **Model selection**: Compare logistic vs XGBoost by test Brier.
- **Drift detection**: Track rolling 7-day Brier on production bets; if > 0.25, trigger retrain.

---

### 3. Log-Loss (Binary Cross-Entropy)

**Definition**: Negative log-likelihood of predictions.

**Formula**:
```
LogLoss = -(1/N) × Σ[y × log(p) + (1-y) × log(1-p)]
```
where `y ∈ {0, 1}` is actual outcome, `p ∈ (0, 1)` is predicted probability.

**Relationship to Brier**: Both measure calibration + discrimination; log-loss penalizes confident wrong predictions more heavily.

**Benchmark**:
- **Random guess** (p=0.5): LogLoss ≈ 0.693
- **Target MVP**: LogLoss < 0.68

**Usage**: XGBoost objective function; early stopping criterion during training.

---

### 4. Calibration Curves

**Definition**: Plot of predicted probabilities (binned) vs observed outcome frequencies.

**Procedure**:
1. **Bin predictions**: Divide [0, 1] into 10 bins (e.g., [0.0–0.1), [0.1–0.2), ..., [0.9–1.0]).
2. **Compute** for each bin:
   - Mean predicted probability: `mean(p_over)` for all predictions in bin.
   - Observed frequency: `mean(over_outcome)` (fraction of actual Overs).
3. **Plot**: X-axis = mean predicted prob, Y-axis = observed freq.
4. **Ideal**: Points lie on diagonal (y = x); model is perfectly calibrated.

**Example**:
| Bin | Mean Predicted | Observed Freq | Count |
|-----|----------------|---------------|-------|
| 0.4–0.5 | 0.45 | 0.42 | 15 |
| 0.5–0.6 | 0.55 | 0.58 | 42 |
| 0.6–0.7 | 0.65 | 0.63 | 28 |

**Interpretation**:
- Points above diagonal → model underconfident (predicts 55%, actually 58%).
- Points below diagonal → model overconfident (predicts 65%, actually 58%).

**Expected Calibration Error (ECE)**:
```
ECE = Σ |mean_pred - mean_obs| × (bin_count / total)
```
**Target**: ECE < 0.03 (predictions match reality within 3%).

**Visualization**: Generate calibration plot weekly; save to `data/outputs/reports/calibration_{week}.png`.

---

## Secondary Metrics

### 5. ROI (Return on Investment)

**Definition**: Total profit divided by total stakes.

**Formula**:
```
ROI = total_profit / total_stakes
```

**Example**:
- 100 bets, $200 each → total stakes = $20,000
- 52 wins at avg odds 1.91 → profit = 52 × $200 × 0.91 - 48 × $200 = $9,464 - $9,600 = **-$136**
- ROI = -136 / 20,000 = **-0.68%**

**Variance**: ROI has high variance in small samples (N < 100); use **Wilson confidence intervals**.

**Wilson 95% CI** (for win rate `p` over `N` bets):
```
CI = p ± 1.96 × sqrt(p × (1 - p) / N)
```

**Interpretation**:
- **Short-term** (N=10): ROI can swing ±20% due to luck.
- **Medium-term** (N=100): ROI variance ~±6%; need ≥2% edge to be confident.
- **Long-term** (N=1000+): Variance ~±2%; 1% edge detectable.

**Target**: ROI > 1% over 100+ bets (3+ months of operation).

---

### 6. Hit Rate (Win Percentage)

**Definition**: Fraction of bets that won.

**Formula**:
```
hit_rate = wins / total_bets
```

**Benchmark**:
- **Break-even**: At typical odds 1.91, need ~52.4% hit rate to break even (accounting for vig).
- **Profitable**: 53–55% hit rate at 1.91 odds → 1–5% ROI.

**Caution**: Hit rate alone is misleading (can have 60% hit rate but negative ROI if betting heavy favorites at bad prices). Always pair with CLV and ROI.

**Target**: 52–54% hit rate on bets with avg odds ~1.90.

---

### 7. Max Drawdown

**Definition**: Largest peak-to-trough decline in bankroll.

**Formula**:
```
drawdown = (peak_balance - current_balance) / peak_balance
```

**Example**:
- Start: $10,000
- Peak (Day 15): $11,200
- Trough (Day 22): $10,500
- Drawdown = (11,200 - 10,500) / 11,200 = **6.25%**

**Usage**: Risk management; if drawdown > 10%, trigger review (see RISK_AND_GUARDS.md).

**Target**: Max drawdown < 10% over first 3 months (with proper Kelly sizing).

---

### 8. Sharpe Ratio

**Definition**: Risk-adjusted return (excess return per unit of volatility).

**Formula**:
```
Sharpe = (mean_daily_return - risk_free_rate) / std(daily_returns)
```

**Interpretation**:
- Sharpe > 1.0 → excellent risk-adjusted performance.
- Sharpe 0.5–1.0 → good.
- Sharpe < 0.5 → marginal; high volatility relative to returns.

**Limitation**: Assumes normal distribution of returns (betting returns often fat-tailed); use Sortino ratio as alternative (penalizes downside vol only).

**Target**: Sharpe > 0.8 over 100+ bets.

---

### 9. Sortino Ratio

**Definition**: Like Sharpe, but only penalizes downside volatility.

**Formula**:
```
Sortino = (mean_daily_return - risk_free_rate) / std(negative_daily_returns)
```

**Usage**: Better for asymmetric return distributions (betting often has more small wins, fewer large losses).

**Target**: Sortino > 1.0.

---

## Evaluation Procedures

### Weekly Review

**Cadence**: Every Monday, review prior week's bets.

**Steps**:

1. **Load data**: Read `data/outputs/results/{last_7_days}.jsonl`
2. **Compute metrics**:
   - Total bets, stakes, profit, ROI
   - Average CLV (in bps)
   - Hit rate with Wilson 95% CI
   - Brier score
   - Calibration curve (10 bins)
3. **Generate report**: `data/outputs/reports/weekly_{week}.json` + PNG calibration plot
4. **Compare to baseline**:
   - Is CLV > 0? (primary validation)
   - Is Brier < 0.24? (model working)
   - Is ROI > -2%? (allow for short-term variance, but flag if consistently negative)
5. **Alert**: If any metric out of range, trigger investigation.

**Example Report**:
```json
{
  "week": "2025-W15",
  "date_range": ["2025-04-07", "2025-04-13"],
  "bets": 42,
  "total_stakes": 5040.00,
  "total_profit": 215.20,
  "roi_pct": 4.27,
  "hit_rate": 0.524,
  "hit_rate_95ci": [0.37, 0.67],
  "clv_avg_bps": 92,
  "clv_median_bps": 78,
  "brier": 0.221,
  "log_loss": 0.652,
  "ece": 0.024,
  "model_version": "v1.2.3",
  "notes": "Strong week; CLV +92 bps validates edge. Brier slightly better than test (0.221 vs 0.230)."
}
```

---

### Monthly Deep Dive

**Cadence**: First Monday of each month.

**Steps**:

1. **Aggregate metrics** (rolling 30 days):
   - Cumulative ROI with 95% CI
   - Sharpe and Sortino ratios
   - Max drawdown
   - CLV distribution histogram
2. **Segment analysis**:
   - ROI by pitcher hand (LHP vs RHP)
   - ROI by line bucket (low lines <5.5, mid 5.5–7.5, high >7.5)
   - ROI by book (if multi-book)
   - ROI with vs without confirmed lineup (Phase 1.5+)
3. **Model diagnostics**:
   - Feature importance (top 10 features from XGBoost)
   - Calibration curve (monthly aggregate)
   - Residual analysis (large errors; investigate outliers)
4. **Retrain decision**:
   - If Brier degraded >5% vs baseline → retrain.
   - If CLV negative for >2 weeks → investigate and possibly retrain.
5. **Update roadmap**: Based on findings, prioritize next features (e.g., if lineup bets significantly outperform, accelerate Phase 1.5).

---

## Experiment Design (A/B Testing)

### Use Case: Test New Feature (e.g., Lineup-Weighted Opponent K%)

**Hypothesis**: Adding lineup-weighted features improves Brier and CLV vs team baseline.

**Design**:

1. **Control group**: Existing model (team baseline only).
2. **Treatment group**: New model with lineup features.
3. **Randomization**: For each game, randomly assign to control (50%) or treatment (50%) using hash of `game_pk` (ensures reproducibility).
4. **Metrics**:
   - Primary: CLV (comparing treatment vs control).
   - Secondary: Brier, ROI.
5. **Sample size**: Run for 100 bets per group (minimum; ~2–3 weeks if betting 15 games/day).
6. **Analysis**:
   - Compare mean CLV: `t-test(treatment_clv, control_clv)`
   - Compare Brier: `t-test(treatment_brier, control_brier)`
   - If treatment CLV > control CLV by ≥20 bps AND statistically significant (p < 0.05), deploy treatment to 100%.

**Pre-registration**: Document hypothesis and metrics before experiment starts to avoid p-hacking.

---

### Use Case: Test Kelly Fraction (λ = 0.2 vs λ = 0.3)

**Hypothesis**: Higher Kelly fraction (λ=0.3) increases ROI but also volatility.

**Design**:

1. **Control**: λ = 0.2 (current default).
2. **Treatment**: λ = 0.3.
3. **Randomization**: Alternate weeks (Week 1: control, Week 2: treatment, etc.) to avoid intra-week correlation.
4. **Metrics**:
   - Primary: Sharpe ratio.
   - Secondary: ROI, max drawdown.
5. **Sample size**: 4 weeks per group (8 weeks total).
6. **Analysis**:
   - Compare Sharpe and drawdown.
   - If treatment Sharpe > control AND drawdown ≤ control × 1.2, adopt λ=0.3.

---

## Model Comparison (Baseline vs Advanced)

**Scenario**: XGBoost vs Two-Tower Neural Net (Phase 3)

**Procedure**:

1. **Train both models** on same training set (last 60 days).
2. **Validate** on same holdout (next 7 days).
3. **Compare**:
   - Test Brier, log-loss, ECE.
   - Calibration curves (visual inspection).
   - Feature importance (XGBoost) vs attention weights (neural net).
4. **Shadow deployment**: Run both models in production for 2 weeks; log predictions from both; compare CLV and Brier on live bets.
5. **Decision**: Deploy model with better CLV and similar/better Brier.

---

## Production Monitoring Dashboard

**Tool**: Grafana + Prometheus (or Streamlit for simpler setup)

**Panels**:

1. **Rolling 7-day metrics**:
   - CLV (line chart over time)
   - Brier (line chart)
   - ROI with 95% CI (bar chart)
   - Hit rate (line chart)
2. **Cumulative metrics**:
   - Total profit (line chart since deployment)
   - Bankroll balance (line chart)
   - Max drawdown (area chart)
3. **Per-bet scatter**:
   - X-axis: predicted p_over
   - Y-axis: actual outcome (jittered 0/1)
   - Color: CLV (green = positive, red = negative)
4. **Calibration curve** (updated weekly):
   - 10-bin plot with confidence intervals
5. **Alerts status**:
   - Green/red indicators for kill-switches (daily loss limit, CLV threshold, Brier drift)

**Access**: Web UI; operator checks daily.

---

## Avoiding P-Hacking & Data Snooping

### Pre-Registration

- **Before deploying MVP**: Document target metrics (Brier < 0.24, CLV > 0, ROI > 1%) and sample size (100 bets minimum).
- **Before experiments**: Write hypothesis and primary metric in experiment log.

### Holdout Discipline

- **Test set**: Only evaluate once per model version (no peeking and retraining).
- **Production bets**: Treat as ultimate test set; do not retrain based on single bad week (wait for sustained drift signal).

### Multiple Comparisons

- **If testing N features**: Use Bonferroni correction (α = 0.05 / N) or cross-validation with single train/test split.
- **Sequential testing**: If running experiments weekly, adjust alpha for multiple looks (use O'Brien-Fleming or Pocock boundaries).

---

## Summary: Evaluation Checklist

**Daily**:
- [ ] Check CLV for today's bets (spot-check 2–3).
- [ ] Verify bets logged correctly in `data/outputs/bets/`.

**Weekly**:
- [ ] Compute 7-day CLV, Brier, ROI, hit rate.
- [ ] Generate calibration curve.
- [ ] Review alerts; investigate if any metric out of range.

**Monthly**:
- [ ] Aggregate 30-day metrics (ROI, Sharpe, drawdown).
- [ ] Segment analysis (by line, hand, book).
- [ ] Retrain decision (based on Brier drift).
- [ ] Update roadmap based on findings.

**Per Experiment**:
- [ ] Pre-register hypothesis and metrics.
- [ ] Collect minimum sample size (100 bets/group).
- [ ] Analyze with proper statistical tests.
- [ ] Document results in experiment log.

All metrics tracked in `data/outputs/reports/` and visualized in Grafana dashboard.
