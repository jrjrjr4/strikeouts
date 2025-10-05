# Glossary

Definitions of key terms, metrics, and concepts used throughout the project.

---

## Baseball & Pitching Metrics

### CSW (Called Strike + Whiff) %
**Definition**: Percentage of pitches that result in either a called strike or a swinging strike (whiff).

**Formula**: `CSW% = (called_strikes + whiffs) / total_pitches`

**Typical range**: 28–34% (league average ~30%).

**Why it matters**: CSW is a stable process metric that predicts strikeouts better than raw K counts. Less affected by defense, park, or opponent quality than K/9. High CSW% indicates elite pitch quality (location + movement).

---

### Whiff %
**Definition**: Percentage of swings that result in a miss (swinging strike).

**Formula**: `Whiff% = whiffs / swings`

**Typical range**: 22–28% (elite: >30%).

**Why it matters**: Direct measure of swing-and-miss ability. Pitchers with high whiff% generate more strikeouts and weaker contact. Correlates with fastball velocity, breaking ball movement, and deception.

---

### Chase %
**Definition**: Percentage of pitches outside the strike zone that batters swing at.

**Formula**: `Chase% = chases / out_of_zone_pitches`

**Typical range**: 26–32% (league average ~28%).

**Why it matters**: Pitchers who induce chases generate more whiffs and favorable counts. Context-dependent: some lineups chase more (free-swingers) or less (disciplined).

---

### Zone %
**Definition**: Percentage of pitches thrown in the strike zone.

**Formula**: `Zone% = in_zone_pitches / total_pitches`

**Typical range**: 42–50% (league average ~46%).

**Why it matters**: Proxy for command. Higher zone% → more called strikes but potentially fewer chases. Interaction with opponent discipline: aggressive hitters punish high zone%; patient hitters exploit low zone%.

---

### K/9 (Strikeouts per 9 Innings)
**Definition**: Strikeout rate normalized per nine innings.

**Formula**: `K/9 = 9 × K / IP`

**Typical range**: 7–10 (elite: >11).

**Why it matters**: Standard strikeout metric. Useful for comparing pitchers with different workloads. Note: CSW% is more predictive, but K/9 is simpler and widely understood.

---

### Pitch Mix
**Definition**: Distribution of pitch types thrown (fastball, slider, changeup, curve, etc.).

**Example**: 58% fastball, 25% slider, 10% changeup, 7% curve.

**Why it matters**: Diversity affects platoon splits and opponent scouting. High slider usage correlates with higher K rates (especially vs same-handed batters). Fastball-heavy pitchers may have lower K upside but better longevity.

---

### Days Rest
**Definition**: Number of days since pitcher's last appearance.

**Formula**: `game_date - last_appearance_date`

**Typical range**: 3–5 days (standard rotation); 0–2 (reliever or short rest); 7+ (injury return or long rest).

**Why it matters**: Rest affects velocity and stamina. Extreme short rest (<3) or long rest (>7) can reduce performance. Standard 4-day rest is baseline.

---

## Opponent & Lineup Metrics

### Team K% vs Hand
**Definition**: Team's strikeout rate (K / PA) when facing left-handed or right-handed pitchers.

**Example**: Yankees vs RHP: 23.5% (1420 PA).

**Why it matters**: Teams vary widely in strikeout tendency (range ~18–26%). Primary opponent context for MVP (team-level baseline).

---

### Lineup-Weighted K% vs Hand
**Definition**: Weighted average of batter K% vs pitcher hand, weighted by expected plate appearances by batting order position.

**Formula**: `Σ(batter_k_vs_hand[i] × expected_pa_weight[i])` for i=1–9.

**Expected PA weights**: [4.8, 4.7, 4.6, 4.5, 4.4, 4.3, 4.1, 3.9, 3.7] (1st hitter sees most PAs, 9th sees fewest).

**Why it matters**: Lineup composition matters significantly. Facing top of order (low K%, patient) vs bottom (high K%, weak contact) changes expected Ks by 1–2 strikeouts.

---

### Park Factor (K)
**Definition**: Adjustment for ballpark effects on strikeout rates.

**Formula**: `park_k_factor = (Ks at park) / (Ks at neutral park)` (computed from historical data).

**Typical range**: 0.96–1.03 (small effects).

**Why it matters**: Some parks have altitude (Coors Field ~0.96, harder to generate swings-and-misses at altitude) or backgrounds (Dodger Stadium ~1.02, batter sightlines). Effect is small (~2–5%) but free signal.

---

## Betting Metrics

### EV (Expected Value)
**Definition**: Average profit per dollar wagered, assuming model probabilities are correct.

**Formula** (decimal odds `O`): `EV = p_over × (O - 1) - (1 - p_over)`

**Example**: Model says 58% chance Over hits; odds 1.91 → EV = 0.58 × 0.91 - 0.42 = **+10.78%**.

**Interpretation**:
- EV > 0: Profitable bet in long run.
- EV = 0: Break-even.
- EV < 0: Losing bet (do not place).

**Why it matters**: EV is the core decision criterion. Only bet when EV ≥ threshold (default 3%) to account for model error and vig.

---

### CLV (Closing Line Value)
**Definition**: Difference between the price we got when placing the bet vs the closing price (final market consensus).

**Formula**: `clv_bps = (closing_implied_prob - bet_implied_prob) × 10000`

**Example**: Bet at 1.91 (52.4% implied), closed at 1.85 (54.1% implied) → CLV = **+170 bps**.

**Interpretation**:
- **Positive CLV**: We got better odds than market consensus → validates edge.
- **Negative CLV**: We got worse odds → may indicate stale data, poor timing, or model error.

**Why it matters**: CLV is the **gold standard** for evaluating betting skill. Positive CLV over 100+ bets is strong evidence of genuine edge (not just luck). More predictive of long-term profit than short-term ROI.

---

### Kelly Criterion
**Definition**: Optimal bet sizing formula that maximizes long-run logarithmic growth of bankroll.

**Full Kelly formula**: `f = (O × p - 1) / (O - 1)`
where `O` = decimal odds, `p` = win probability, `f` = fraction of bankroll to wager.

**Fractional Kelly**: `f_frac = λ × f_full` (default `λ = 0.2` = 20% of full Kelly).

**Why fractional**: Full Kelly maximizes growth but has high volatility (50% drawdown risk with model error). Fractional Kelly (λ = 0.2–0.25) retains 80%+ of growth rate while reducing drawdown to ~10–15%.

**Example**: Full Kelly says bet 11.84% of bankroll; fractional Kelly (λ=0.2) → bet **2.37%**.

---

### ROI (Return on Investment)
**Definition**: Total profit divided by total stakes.

**Formula**: `ROI = total_profit / total_stakes`

**Example**: $20,000 staked, $400 profit → ROI = **2.0%**.

**Variance**: High variance in small samples (N < 100). Use Wilson confidence intervals to account for uncertainty.

**Target**: ROI > 1% over 100+ bets (3+ months).

**Caution**: ROI is outcome-based (includes luck). CLV is process-based (skill). Prefer CLV for model validation; ROI for profit tracking.

---

### Brier Score
**Definition**: Mean squared error of probabilistic predictions.

**Formula**: `Brier = (1/N) × Σ(p_predicted - outcome_actual)²`

**Benchmark**: Random guess (always predict 50%) → Brier = 0.25.

**Target**: Brier < 0.24 (better than random); < 0.23 (good); < 0.20 (excellent).

**Why it matters**: Measures calibration + discrimination. Lower Brier → better probability estimates → higher EV bets. Critical for model selection and drift detection.

---

### Log-Loss (Binary Cross-Entropy)
**Definition**: Negative log-likelihood of predictions.

**Formula**: `LogLoss = -(1/N) × Σ[y × log(p) + (1-y) × log(1-p)]`

**Benchmark**: Random guess → LogLoss ≈ 0.693.

**Target**: LogLoss < 0.68.

**Why it matters**: Similar to Brier but penalizes confident wrong predictions more heavily. Used as XGBoost objective function and early stopping criterion.

---

### Calibration
**Definition**: How well predicted probabilities match observed frequencies.

**Measurement**: Plot predicted prob bins vs actual outcome rates; ideal calibration → points lie on y=x diagonal.

**Metric**: ECE (Expected Calibration Error) = average absolute difference between predicted and observed per bin.

**Target**: ECE < 0.03 (within 3%).

**Why it matters**: Betting requires well-calibrated probabilities (not just good ranking). Poor calibration → EV estimates wrong → lose money even if model discriminates well.

---

### Spread (Vig / Juice)
**Definition**: Sportsbook profit margin; difference between implied probabilities of both sides.

**Formula**: `spread = (1/price_over + 1/price_under) - 1`

**Example**: Over 1.91, Under 1.95 → spread = (0.524 + 0.513) - 1 = **3.7%**.

**Typical range**: 3–8% (sharper books 3–5%; softer books 5–8%).

**Why it matters**: High vig erodes edge. Filter bets by max spread (default ≤5%) to avoid unprofitable markets.

---

### Slippage
**Definition**: Adverse price movement between decision and execution.

**Example**: Plan to bet at 1.91; by execution time, price drops to 1.87 → slippage = **-0.04** (worse odds).

**Mitigation**: Fetch odds close to execution time (T-30m); set slippage tolerance (default ≤2%).

---

### Partial Fill
**Definition**: Bet only partially executed due to insufficient liquidity.

**Example**: Want to bet $200; only $120 filled → partial fill.

**Mitigation**: Require minimum liquidity (default $1000 available) before placing bet; cap stakes to avoid market impact.

---

## Machine Learning & Modeling

### Platt Scaling
**Definition**: Calibration method that fits logistic regression on model outputs.

**Formula**: `P_calibrated = sigmoid(a × P_raw + b)` where `a, b` learned on validation set.

**When to use**: Logistic regression models, some tree models.

---

### Isotonic Regression
**Definition**: Non-parametric calibration method that learns monotonic mapping from raw probabilities to calibrated probabilities.

**When to use**: Tree-based models (XGBoost, LightGBM); more flexible than Platt but requires more validation data.

---

### Two-Tower (Siamese) Model
**Definition**: Neural network architecture with separate towers (subnetworks) for different input groups (e.g., pitcher features, opponent features), whose embeddings are concatenated and fed to final layers.

**Why it matters**: Explicitly models interactions between pitcher and opponent; can learn non-additive matchup effects.

**Timeline**: Phase 3 (requires more data and infrastructure).

---

### Contextual Bandit
**Definition**: Online learning framework for sequential decision-making where each action (bet size, timing) receives immediate reward (CLV, ROI).

**Algorithms**: Thompson Sampling (Bayesian), LinUCB (frequentist).

**Why it matters**: Learns optimal bet sizing and timing dynamically; adapts to changing market conditions.

**Timeline**: Phase 4 (requires ≥500 historical bets and simulator).

---

### Reinforcement Learning (RL)
**Definition**: Framework for learning optimal policies through trial-and-error interaction with environment.

**Use case**: Sequential betting (when to bet as odds shift during day); in-game live betting.

**Challenges**: Requires rich state/action space, simulator, and extensive logs.

**Timeline**: Phase 4+ (advanced; only after bandit validation).

---

## Risk & Compliance

### Drawdown
**Definition**: Largest peak-to-trough decline in bankroll.

**Formula**: `drawdown = (peak_balance - current_balance) / peak_balance`

**Example**: Peak $11,200 → trough $10,500 → drawdown = **6.25%**.

**Target**: Max drawdown < 10% with fractional Kelly sizing.

**Kill-switch**: Halt betting if drawdown > 10% (triggers manual review).

---

### Kill-Switch
**Definition**: Automatic halt to betting triggered by risk threshold breach.

**Triggers**:
- Daily loss > 5% of bankroll.
- CLV < -20 bps for 3 consecutive days.
- Drawdown > 10%.
- Model load failure or feature hash mismatch.

**Purpose**: Prevent catastrophic losses; force review and investigation.

---

### TOS (Terms of Service)
**Definition**: Legal agreement with data providers and sportsbooks governing acceptable use.

**Compliance**:
- Respect API rate limits.
- No scraping outside published endpoints.
- No automated betting (unless book API supports it and TOS permits).
- No market manipulation (spoofing, layering).

---

### Time Honesty
**Definition**: Principle that only data available at decision time can be used in features (no look-ahead bias).

**Implementation**: Every feature includes `as_of` timestamp; validate `as_of ≤ bet_timestamp` in audit.

**Why it matters**: Prevents overfitting on historical data by accidentally including future information (e.g., closing odds, actual outcomes).

---

## Other Terms

### Decimal Odds
**Definition**: Odds format showing total payout per dollar wagered (including stake).

**Example**: 1.91 decimal → bet $100, win $191 total ($91 profit).

**Conversion to American**: 1.91 decimal ≈ -110 American.

**Conversion to implied probability**: `implied_prob = 1 / decimal_odds` (e.g., 1/1.91 = 52.4%).

---

### Implied Probability
**Definition**: Break-even win rate required to profit at given odds.

**Formula**: `implied_prob = 1 / decimal_odds`

**Example**: Odds 1.91 → implied prob = **52.4%** (need to win >52.4% of bets to profit).

---

### Line Shopping
**Definition**: Comparing odds across multiple sportsbooks to find best available price.

**Example**: DraftKings offers Over 1.91; FanDuel offers 1.95 → bet at FanDuel (better value).

**Why it matters**: Extra 2–5% in odds translates to higher EV and CLV.

---

### Polymarket
**Definition**: Decentralized prediction market (blockchain-based) where users trade binary outcome tokens.

**Difference from sportsbooks**: Peer-to-peer (no house); resolution via oracle (UMA); potential for disputes; lower liquidity.

**Use case**: Arbitrage, hedging, rule edges.

**Timeline**: Phase 5+ (optional module; separate risk profile).

---

### Sharpe Ratio
**Definition**: Risk-adjusted return metric.

**Formula**: `Sharpe = (mean_return - risk_free_rate) / std(returns)`

**Interpretation**: Sharpe > 1.0 = excellent; 0.5–1.0 = good; < 0.5 = marginal.

**Limitation**: Assumes normal distribution (betting returns often fat-tailed); prefer Sortino ratio.

---

### Sortino Ratio
**Definition**: Like Sharpe, but only penalizes downside volatility (ignores upside).

**Formula**: `Sortino = (mean_return - risk_free_rate) / std(negative_returns)`

**Why better for betting**: Asymmetric return distributions (many small wins, few large losses).

---

### Wilson Confidence Interval
**Definition**: Statistical method for computing confidence interval around win rate (adjusts for small sample size).

**Formula** (approximate): `CI = p ± 1.96 × sqrt(p × (1-p) / N)`

**Example**: 52% win rate over 100 bets → 95% CI ≈ [42%, 62%].

**Why it matters**: Accounts for variance; prevents overconfidence from small samples.

---

## Abbreviations

- **BP**: Basis points (1 bp = 0.01% = 0.0001)
- **EV**: Expected value
- **CLV**: Closing line value
- **ROI**: Return on investment
- **K**: Strikeout
- **IP**: Innings pitched
- **PA**: Plate appearance
- **O/U**: Over/Under
- **RHP/LHP**: Right-handed pitcher / Left-handed pitcher
- **TTL**: Time-to-live (cache duration)
- **API**: Application programming interface
- **ETL**: Extract, transform, load (data pipeline)
- **CI**: Confidence interval
- **ECE**: Expected calibration error
- **SLO**: Service level objective
- **TBD**: To be determined

---

## References

- **Statcast glossary**: https://www.mlb.com/glossary/statcast
- **FanGraphs sabermetrics library**: https://library.fangraphs.com
- **Kelly Criterion**: https://en.wikipedia.org/wiki/Kelly_criterion
- **Brier score**: https://en.wikipedia.org/wiki/Brier_score
