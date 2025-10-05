# Model Specification

## Problem Formulation

**Task**: Binary classification of `P(K_actual ≥ line | features, line)` for pitcher strikeout Over/Under props.

**Key challenge**: The line varies per game; model must condition on `line_decimal` as a feature.

**Output**: Calibrated probability `p_over ∈ [0, 1]` used for EV calculation and bet selection.

---

## Data Splits (Time-Honest)

**Principle**: Strictly time-based splits to prevent look-ahead bias; no shuffling.

### Training Window

- **Rolling monthly train**: Use games from `[T-60 days, T-7 days]` to predict games in week `[T-6 days, T]`.
- **Validation**: Hold out `[T-6 days, T]` for early stopping and calibration tuning.
- **Test**: Next week `[T+1, T+7]` for final evaluation before deployment.

### Retrain Cadence

- **Initial**: Train on historical data (e.g., 2023–2024 seasons).
- **Production**: Retrain weekly using last 60 days; compare calibration metrics (Brier, log-loss) to previous model; deploy if improved or similar (avoid degradation).
- **Trigger retrain**: If Brier score on rolling 7-day window increases > 5% vs expected, trigger immediate retrain.

### Label Construction

- **Target**: `over = 1 if k_actual >= line_decimal else 0`
- **Challenge**: Historical odds lines may be incomplete. **Synthetic line generation** (if needed):
  - Fit quantile regression (e.g., 50th percentile) on pitcher/opponent features → predicted median Ks.
  - Round to nearest 0.5 (typical line increment).
  - Flag synthetic labels in training data; prioritize real historical lines; test model on real-line holdout only.
- **Recommendation**: Collect 2+ months of real historical odds before MVP deployment to avoid synthetic labels.

---

## Baseline Models

### Model 1: Logistic Regression (L2 regularized)

- **Algorithm**: `sklearn.linear_model.LogisticRegressionCV` with 5-fold CV for regularization strength `C`.
- **Features**: All numeric features standardized; binary flags as-is.
- **Hyperparameters**:
  - `C`: grid search `[0.01, 0.1, 1.0, 10.0]`.
  - `class_weight='balanced'` to handle slight class imbalance (lines set near 50% by books).
- **Calibration**: Apply Platt scaling (`sklearn.calibration.CalibratedClassifierCV` with `method='sigmoid'`) on validation set.
- **Pros**: Interpretable coefficients; fast; robust baseline.
- **Cons**: Assumes linear relationships; may underfit nonlinear interactions.

### Model 2: Gradient Boosted Trees (XGBoost)

- **Algorithm**: `xgboost.XGBClassifier`
- **Features**: Same as logistic; no need to standardize (tree-based).
- **Hyperparameters** (modest grid to avoid overfitting):
  - `max_depth`: [3, 4, 5]
  - `n_estimators`: [100, 200, 300]
  - `learning_rate`: [0.05, 0.1]
  - `min_child_weight`: [3, 5]
  - `subsample`: 0.8
  - `colsample_bytree`: 0.8
  - `scale_pos_weight`: computed from class imbalance
- **Early stopping**: Monitor validation log-loss; stop if no improvement in 20 rounds.
- **Calibration**: Apply isotonic regression (`method='isotonic'`) on validation set (isotonic often works better for tree models).
- **Pros**: Captures nonlinear interactions; strong performance.
- **Cons**: Less interpretable; risk of overfitting on small data.

### Model Selection

- **Compare**: Logistic vs XGBoost on test set via:
  - **Brier score** (lower better; target < 0.24).
  - **Log-loss** (lower better).
  - **Calibration curve** (plot predicted prob bins vs observed freq; should align with y=x).
  - **AUC-ROC** (secondary; we care about calibration more than ranking).
- **Deploy**: Use whichever generalizes better; prefer logistic if tied (interpretability).

---

## Advanced Models (Phase 2–3)

### Two-Tower (Siamese) Architecture

**Motivation**: Explicitly model pitcher–opponent matchup interactions.

**Architecture**:

```
Pitcher Tower                   Opponent/Context Tower
─────────────────              ────────────────────────
[k9, csw, whiff, ...]    →     [team_k_vs_hand, ...]    →
  ↓ Dense(64, ReLU)              ↓ Dense(64, ReLU)
  ↓ Dense(32, ReLU)              ↓ Dense(32, ReLU)
  ↓ pitcher_embed (16)           ↓ opponent_embed (16)
  └───────────┬──────────────────┘
              ↓
        Concatenate [pitcher_embed, opponent_embed, line, market_features]
              ↓ Dense(32, ReLU)
              ↓ Dense(1, sigmoid) → p_over
```

- **Input**: Separate feature groups for pitcher and opponent.
- **Training**: Binary cross-entropy loss; Adam optimizer; batch size 64; early stopping on validation Brier.
- **Calibration**: Post-hoc Platt or isotonic on validation set.
- **Benefits**: Learns non-additive matchup effects (e.g., high-whiff pitcher vs low-chase team).
- **Timeline**: Phase 3 (after 6+ months of data and baseline validation).

### Score Distribution Models (Optional)

**Motivation**: Predict full distribution `P(K = k)` instead of binary outcome; allows pricing multiple lines simultaneously.

**Approaches**:

1. **Poisson regression**: `P(K = k | λ)` where `λ = exp(Xβ)`.
   - Simple; assumes constant rate; tends to underfit (MLB Ks overdispersed).
2. **Negative Binomial**: Adds dispersion parameter; better fit.
3. **Mixture models**: Combine Poisson/NegBin for different pitcher types (starters vs relievers).

**Output**: Sample from fitted distribution to compute `P(K ≥ line)` for any line.

**Calibration**: Check empirical CDFs vs predicted on holdout.

**Timeline**: Phase 3–4 (requires larger dataset and validation that distributional approach improves multi-line bets).

---

## Calibration

**Critical**: Betting requires well-calibrated probabilities (not just good ranking).

### Methods

1. **Platt Scaling** (`method='sigmoid'`): Fits logistic regression `P_calib = sigmoid(a × P_raw + b)` on validation set.
   - Works well for logistic and some tree models.
2. **Isotonic Regression** (`method='isotonic'`): Non-parametric; learns monotonic mapping `P_calib = f(P_raw)`.
   - More flexible; works well for tree models; requires more validation data.

### Validation

- **Calibration curves**: Bin predictions (10 bins, equal width or equal frequency); plot mean predicted prob vs observed frequency.
- **Expected Calibration Error (ECE)**: `Σ |mean_pred - mean_obs| × bin_count / total` across bins; target < 0.03.
- **Brier decomposition**: Brier = calibration + refinement + uncertainty; low calibration component confirms good calibration.

### Decision

- **Baseline**: Use Platt for logistic, isotonic for XGBoost.
- **Validation**: Tune on validation set; test on holdout; choose method with lowest Brier + best calibration curve.

---

## Uncertainty Quantification

**Motivation**: High-uncertainty predictions should receive lower stakes (risk management).

### Approaches

1. **Prediction Intervals via Bootstrap**:
   - Train ensemble of K=10 models on bootstrap samples.
   - For each prediction, compute mean and std dev of `p_over` across ensemble.
   - Flag predictions with `std(p_over) > 0.05` as high-uncertainty; cap stake.
2. **Conformal Prediction** (advanced):
   - Compute prediction sets with guaranteed coverage (e.g., 90%).
   - If interval width large → uncertain → reduce stake.

### Integration

- **Stake adjustment**: `stake_adjusted = stake × max(0.5, 1 - 2 × std(p_over))`
- **Filter**: Skip bets where `std(p_over) > 0.08` (too uncertain).

**Timeline**: MVP uses point estimates; add uncertainty in Phase 2.

---

## Feature Hygiene & Leakage Prevention

1. **Time honesty**: Only features available as-of bet time; log `as_of` timestamps; audit in post-game analysis.
2. **No target leakage**: Never include `k_actual`, closing odds, or game outcomes in features.
3. **No data snooping**: Hyperparameter tuning on validation only; test set touched once for final eval.
4. **Standardization**: Fit scaler on training set only; apply same transform to validation/test/production.
5. **Missing value handling**: Document fallback logic (see FEATURE_SPEC); add `*_missing` flags; do not impute with future data.

---

## Hyperparameter Tuning

### Strategy

- **Grid search** for small parameter spaces (logistic `C`, XGBoost depth/lr).
- **Random search** if larger space (neural nets).
- **Metric**: Validation Brier score (primary) or log-loss (secondary).
- **Early stopping**: Prevent overfitting; monitor validation loss.

### Reproducibility

- **Random seeds**: Fix numpy/sklearn/xgboost seeds for reproducibility.
- **Logging**: Track all hyperparams, CV scores, and final test metrics in MLflow or JSON log.

---

## Model Versioning & Deployment

### Artifacts to Save

- **Model file**: Pickled sklearn/xgboost model + calibrator.
- **Scaler**: Standardization parameters (mean/std per feature).
- **Metadata**: Training date range, feature list, feature hash, hyperparameters, test Brier/log-loss.

### Loading in Production

- **Validation**: Load model; check feature hash matches current pipeline; if mismatch, halt and alert.
- **Fallback**: Keep previous model version; if new model load fails, use previous.

### A/B Testing

- **Shadow mode**: Run new model alongside old; log predictions from both; compare CLV and Brier over 1 week before switching.

---

## Performance Targets (Test Set)

| Metric | Target | Rationale |
|--------|--------|-----------|
| Brier Score | < 0.24 | Better than coin flip (0.25); well-calibrated |
| Log-Loss | < 0.68 | Equivalent to Brier for binary; lower = better confidence |
| Calibration ECE | < 0.03 | Predicted probs match observed freqs within 3% |
| AUC-ROC | > 0.58 | Modest discrimination (market is efficient); not primary metric |
| Hit Rate | ~50–53% | On bets with EV > 3%; slight edge expected |

---

## Failure Modes & Diagnostics

| Issue | Detection | Response |
|-------|-----------|----------|
| Overfitting | Validation Brier << Test Brier | Reduce model complexity; more regularization; larger validation set |
| Underfitting | Train/Val/Test Brier all high | Add features; reduce regularization; try nonlinear model |
| Poor calibration | ECE > 0.05; calibration curve deviates | Retune calibration method; check for distribution shift |
| Model drift | Rolling 7-day Brier increases | Trigger retrain; investigate feature distribution changes |
| Label noise | High variance in same-feature games | Collect more data; check for data quality issues (e.g., wrong K counts) |

---

## Research Extensions (Phase 4+)

- **Contextual Bandits**: Model EV as reward; learn bet-sizing policy via Thompson sampling or LinUCB (requires simulator or historical betting logs).
- **Reinforcement Learning**: Sequential decision-making (e.g., when to bet during the day as odds shift); requires rich state/action logs and simulator.
- **Multi-task Learning**: Joint model for Ks, hits, runs; share representations (two-tower backbone).

**Note**: Advanced RL deferred until >1000 historical bets logged and simulation framework built.
