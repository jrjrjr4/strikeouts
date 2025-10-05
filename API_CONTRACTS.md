# API Contracts

This document defines the Python interfaces (function signatures and return schemas) for all data providers. **No implementation code** is provided here—only contracts for future development.

---

## 1. MlbStatsProvider

**Purpose**: Official MLB data for schedules, probables, boxscores, and team splits.

### Interface

```python
from typing import List, Optional
from dataclasses import dataclass
from datetime import date, datetime

@dataclass
class Game:
    game_pk: int
    game_date: datetime
    home_team_id: int
    away_team_id: int
    park_id: int
    status: str  # "scheduled", "live", "final"

@dataclass
class ProbablePitcher:
    game_pk: int
    team_id: int
    pitcher_id: int
    pitcher_name: str
    throws: str  # "R" or "L"

@dataclass
class Boxscore:
    game_pk: int
    home_batting_order: List[int]  # Player IDs 1-9
    away_batting_order: List[int]
    home_pitcher_ks: Optional[int]  # Actual strikeouts (post-game)
    away_pitcher_ks: Optional[int]
    game_status: str  # "live", "final"

@dataclass
class TeamSplit:
    team_id: int
    vs_hand: str  # "L" or "R"
    k_rate: float  # K / PA
    pa: int
    date_range: str  # e.g., "2025-04-01 to 2025-04-14"

class MlbStatsProvider:
    def __init__(self, base_url: str, timeout_s: int = 8, retries: int = 3):
        """
        Initialize provider with configurable base URL and retry policy.
        """
        pass

    def get_schedule(self, date: date) -> List[Game]:
        """
        Fetch schedule for given date.

        Returns:
            List of Game objects with game_pk, teams, park, status.

        Raises:
            ProviderError: On HTTP errors, timeouts, or invalid response.
        """
        pass

    def get_probables(self, date: date) -> List[ProbablePitcher]:
        """
        Fetch probable starting pitchers for given date.

        Returns:
            List of ProbablePitcher objects.

        Raises:
            ProviderError: On HTTP errors or missing data.
        """
        pass

    def get_boxscore(self, game_pk: int) -> Optional[Boxscore]:
        """
        Fetch boxscore for given game (lineups and/or final stats).

        Returns:
            Boxscore object if available, None if game not started or data unavailable.

        Raises:
            ProviderError: On HTTP errors.
        """
        pass

    def get_team_batting_splits(self, team_id: int, vs_hand: str) -> Optional[TeamSplit]:
        """
        Fetch team batting statistics vs LHP or RHP.

        Args:
            team_id: MLB team ID (e.g., 147 = Yankees)
            vs_hand: "L" or "R"

        Returns:
            TeamSplit object with K%, PA, date range; None if unavailable.

        Raises:
            ProviderError: On HTTP errors.
        """
        pass
```

### JSON Schemas (Examples)

#### Game
```json
{
  "game_pk": 123456,
  "game_date": "2025-04-15T19:10:00Z",
  "home_team_id": 147,
  "away_team_id": 121,
  "park_id": 15,
  "status": "scheduled"
}
```

#### ProbablePitcher
```json
{
  "game_pk": 123456,
  "team_id": 147,
  "pitcher_id": 607644,
  "pitcher_name": "Jacob deGrom",
  "throws": "R"
}
```

#### Boxscore
```json
{
  "game_pk": 123456,
  "home_batting_order": [502110, 660271, 621043, 592450, 596142, 660162, 656775, 665487, 677649],
  "away_batting_order": [660670, 665742, 668804, 650402, 645302, 663611, 666182, 677800, 672695],
  "home_pitcher_ks": 8,
  "away_pitcher_ks": 5,
  "game_status": "final"
}
```

#### TeamSplit
```json
{
  "team_id": 147,
  "vs_hand": "R",
  "k_rate": 0.235,
  "pa": 1420,
  "date_range": "2025-04-01 to 2025-04-14"
}
```

---

## 2. StatcastProvider

**Purpose**: Statcast pitch-level data for pitcher rolling aggregates (K/9, CSW%, whiff%, etc.).

### Interface

```python
import pandas as pd
from dataclasses import dataclass
from datetime import date

@dataclass
class PitcherSummary:
    pitcher_id: int
    end_date: date
    window_n: int  # Number of starts used
    k9: float
    csw_pct: float
    whiff_pct: float
    chase_pct: float
    zone_pct: float
    fastball_pct: float
    slider_pct: float
    changeup_pct: float
    curve_pct: float
    delta_csw_3: float  # Trend signal
    as_of: datetime  # Timestamp when computed

class StatcastProvider:
    def __init__(self, use_pybaseball: bool = True, timeout_s: int = 20, retries: int = 2):
        """
        Initialize provider (e.g., pybaseball wrapper or direct Baseball Savant queries).
        """
        pass

    def get_pitcher_game_logs(
        self,
        pitcher_id: int,
        start_date: date,
        end_date: date
    ) -> pd.DataFrame:
        """
        Fetch pitch-level data for pitcher in date range.

        Returns:
            DataFrame with columns:
                - game_date: date
                - game_pk: int
                - ip: float (innings pitched)
                - k: int (strikeouts)
                - pitches: int
                - called_strikes: int
                - whiffs: int
                - swings: int
                - in_zone: int
                - out_zone: int
                - chases: int
                - pitch_type: str (FF, SL, CH, CU, etc.)

        Raises:
            ProviderError: On API errors, rate limits, or data unavailable.
        """
        pass

    def summarize_recent(self, pitcher_id: int, N: int = 5) -> PitcherSummary:
        """
        Compute rolling aggregate over last N starts.

        Args:
            pitcher_id: MLB pitcher ID
            N: Number of recent starts (default 5)

        Returns:
            PitcherSummary with computed metrics (K/9, CSW%, pitch mix, etc.)

        Raises:
            ProviderError: On fetch errors.
            InsufficientDataError: If < N starts available (fallback to N=3 or season mean).
        """
        pass
```

### DataFrame Schema (get_pitcher_game_logs)

| Column | Type | Description |
|--------|------|-------------|
| game_date | date | Date of game |
| game_pk | int | MLB game ID |
| ip | float | Innings pitched (outs / 3) |
| k | int | Strikeouts |
| pitches | int | Total pitches thrown |
| called_strikes | int | Called strikes |
| whiffs | int | Swinging strikes |
| swings | int | Total swings |
| in_zone | int | Pitches in strike zone |
| out_zone | int | Pitches out of zone |
| chases | int | Swings at out-of-zone pitches |
| pitch_type | str | Dominant pitch type (aggregated per game) |

### PitcherSummary JSON

```json
{
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
  "as_of": "2025-04-15T00:45:00Z"
}
```

---

## 3. OddsProvider

**Purpose**: Live strikeout Over/Under lines and prices from sportsbooks.

### Interface

```python
import pandas as pd
from datetime import date, datetime

class OddsProvider:
    def __init__(self, base_url: str, api_key_env: str, timeout_s: int = 8, retries: int = 3):
        """
        Initialize odds provider (e.g., TheOddsAPI).

        Args:
            base_url: API base URL (configurable)
            api_key_env: Environment variable name for API key
            timeout_s: Request timeout
            retries: Max retries on transient errors
        """
        pass

    def get_pitcher_k_lines(self, date: date) -> pd.DataFrame:
        """
        Fetch all pitcher strikeout O/U markets for given date.

        Returns:
            DataFrame with columns:
                - game_pk: int
                - pitcher_id: int
                - pitcher_name: str
                - line_decimal: float (e.g., 6.5)
                - price_over_decimal: float (e.g., 1.91)
                - price_under_decimal: float (e.g., 1.95)
                - book: str (e.g., "draftkings")
                - fetched_at: datetime (UTC timestamp)

        Raises:
            ProviderError: On HTTP errors, rate limits, or quota exhaustion.
        """
        pass
```

### DataFrame Schema (get_pitcher_k_lines)

| Column | Type | Description |
|--------|------|-------------|
| game_pk | int | MLB game ID |
| pitcher_id | int | Pitcher ID |
| pitcher_name | str | Pitcher name (for logging) |
| line_decimal | float | Strikeout threshold (e.g., 6.5) |
| price_over_decimal | float | Decimal odds for Over (e.g., 1.91) |
| price_under_decimal | float | Decimal odds for Under (e.g., 1.95) |
| book | str | Sportsbook name |
| fetched_at | datetime | Timestamp when odds fetched (UTC) |

### Example DataFrame (as JSON)

```json
[
  {
    "game_pk": 123456,
    "pitcher_id": 607644,
    "pitcher_name": "Jacob deGrom",
    "line_decimal": 6.5,
    "price_over_decimal": 1.91,
    "price_under_decimal": 1.95,
    "book": "draftkings",
    "fetched_at": "2025-04-15T18:25:00Z"
  },
  {
    "game_pk": 123456,
    "pitcher_id": 607644,
    "pitcher_name": "Jacob deGrom",
    "line_decimal": 6.5,
    "price_over_decimal": 1.88,
    "price_under_decimal": 1.98,
    "book": "fanduel",
    "fetched_at": "2025-04-15T18:25:00Z"
  }
]
```

---

## 4. BatterSplitsProvider (Phase 1.5)

**Purpose**: Batter-level K% vs LHP/RHP for lineup weighting.

### Interface

```python
from typing import Optional
from dataclasses import dataclass

@dataclass
class BatterSplit:
    batter_id: int
    batter_name: str
    vs_hand: str  # "L" or "R"
    k_rate: float  # K / PA
    pa: int
    date_range: str

class BatterSplitsProvider:
    def __init__(self, base_url: str, timeout_s: int = 8, retries: int = 3):
        pass

    def get_batter_split(self, batter_id: int, vs_hand: str) -> Optional[BatterSplit]:
        """
        Fetch batter K% vs LHP or RHP.

        Args:
            batter_id: MLB batter ID
            vs_hand: "L" or "R"

        Returns:
            BatterSplit object; None if insufficient data.

        Raises:
            ProviderError: On HTTP errors.
        """
        pass
```

### BatterSplit JSON

```json
{
  "batter_id": 660271,
  "batter_name": "Juan Soto",
  "vs_hand": "R",
  "k_rate": 0.18,
  "pa": 542,
  "date_range": "2025-04-01 to 2025-04-14"
}
```

---

## 5. UmpireProvider (Phase 2)

**Purpose**: Umpire K% tendencies for context adjustment.

### Interface

```python
from typing import Optional
from dataclasses import dataclass

@dataclass
class UmpireStats:
    umpire_name: str
    k_per_game: float  # Avg Ks per game with this umpire
    games_worked: int
    season: int

class UmpireProvider:
    def __init__(self, base_url: str, timeout_s: int = 8):
        pass

    def get_umpire_assignment(self, game_pk: int) -> Optional[str]:
        """
        Fetch home plate umpire name for given game.

        Returns:
            Umpire name; None if not yet assigned.
        """
        pass

    def get_umpire_stats(self, umpire_name: str, season: int) -> Optional[UmpireStats]:
        """
        Fetch historical umpire K tendency.

        Returns:
            UmpireStats; None if insufficient data.
        """
        pass
```

---

## 6. WeatherProvider (Phase 2)

**Purpose**: Stadium weather for run environment adjustments.

### Interface

```python
from typing import Optional
from dataclasses import dataclass

@dataclass
class Weather:
    park_id: int
    temp_f: float
    humidity_pct: float
    wind_speed_mph: float
    wind_direction: str  # "out_to_lf", "in_from_cf", etc.
    timestamp: datetime

class WeatherProvider:
    def __init__(self, api_key_env: str, timeout_s: int = 8):
        pass

    def get_weather(self, park_id: int, game_time: datetime) -> Optional[Weather]:
        """
        Fetch weather forecast for stadium at game time.

        Args:
            park_id: MLB park ID
            game_time: Scheduled first pitch time

        Returns:
            Weather object; None if unavailable.
        """
        pass
```

---

## 7. PolymarketProvider (Phase 5+)

**Purpose**: Decentralized prediction market odds for arbitrage/hedging.

### Interface

```python
import pandas as pd
from datetime import date

class PolymarketProvider:
    def __init__(self, api_key_env: str, timeout_s: int = 8):
        pass

    def get_pitcher_k_markets(self, date: date) -> pd.DataFrame:
        """
        Fetch Polymarket binary outcome tokens for pitcher strikeouts.

        Returns:
            DataFrame with columns:
                - market_id: str
                - pitcher_name: str
                - line: float (e.g., 6.5)
                - yes_price: float (buy YES token = Over)
                - no_price: float (buy NO token = Under)
                - liquidity: float (total pool size)
                - resolution_source: str (e.g., "UMA Oracle")
                - fetched_at: datetime
        """
        pass
```

---

## Error Handling

### Custom Exceptions

```python
class ProviderError(Exception):
    """Base exception for all provider errors."""
    pass

class RateLimitError(ProviderError):
    """Raised on HTTP 429 (rate limit exceeded)."""
    pass

class InsufficientDataError(ProviderError):
    """Raised when requested data unavailable (e.g., < N starts for pitcher)."""
    pass

class QuotaExhaustedError(ProviderError):
    """Raised when API quota exhausted (e.g., odds provider monthly limit)."""
    pass
```

### Retry Logic (Pseudocode)

```python
def fetch_with_retry(url, retries=3, backoff_base=1):
    for attempt in range(retries):
        try:
            response = http.get(url, timeout=timeout_s)
            if response.status_code == 200:
                return response.json()
            elif response.status_code == 429:
                sleep_time = response.headers.get('Retry-After', 60)
                time.sleep(sleep_time)
            elif response.status_code >= 500:
                time.sleep(backoff_base * 2 ** attempt)
            else:
                raise ProviderError(f"HTTP {response.status_code}")
        except Timeout:
            if attempt == retries - 1:
                raise ProviderError("Timeout after retries")
            time.sleep(backoff_base * 2 ** attempt)
    raise ProviderError("Max retries exceeded")
```

---

## Caching Layer (Optional Interface)

**Purpose**: Abstract caching to allow swapping backends (JSON files, Redis, etc.).

```python
from typing import Any, Optional
from datetime import datetime

class CacheProvider:
    def get(self, key: str) -> Optional[Any]:
        """Retrieve cached value by key; None if not found or stale."""
        pass

    def set(self, key: str, value: Any, ttl_seconds: int):
        """Store value with TTL (time-to-live)."""
        pass

    def delete(self, key: str):
        """Remove key from cache."""
        pass

    def clear_stale(self, older_than: datetime):
        """Delete all cache entries older than given timestamp."""
        pass
```

---

## Configuration Integration

All providers should accept config from `CONFIG_TEMPLATE.yaml`:

```python
import yaml

def load_config(path="config.yaml"):
    with open(path) as f:
        return yaml.safe_load(f)

config = load_config()
mlb_provider = MlbStatsProvider(
    base_url=config['providers']['mlb_stats']['base_url'],
    timeout_s=config['providers']['mlb_stats']['timeout_s'],
    retries=config['providers']['mlb_stats']['retries']
)
```

---

## Testing Contracts (Unit Test Stubs)

```python
import pytest
from unittest.mock import Mock

def test_mlb_stats_get_schedule():
    provider = MlbStatsProvider(base_url="https://mock-api.example.com")
    games = provider.get_schedule(date(2025, 4, 15))
    assert len(games) > 0
    assert games[0].game_pk > 0

def test_statcast_summarize_recent():
    provider = StatcastProvider()
    summary = provider.summarize_recent(pitcher_id=607644, N=5)
    assert 0.0 <= summary.csw_pct <= 1.0
    assert summary.window_n == 5

def test_odds_provider_rate_limit():
    provider = OddsProvider(base_url="https://mock-api.example.com", api_key_env="TEST_KEY")
    with pytest.raises(RateLimitError):
        # Mock HTTP 429 response
        provider.get_pitcher_k_lines(date(2025, 4, 15))
```

---

## Summary

This document defines **interfaces only**—no implementation. Key principles:

1. **Typed returns**: Use dataclasses and pandas DataFrames with documented schemas.
2. **Error handling**: Raise specific exceptions (ProviderError, RateLimitError, etc.); implement retry logic.
3. **Configurability**: Accept base URLs, timeouts, retries from config (no hardcoded values).
4. **Testability**: Design for mocking; write unit tests before implementation.
5. **Time honesty**: Every data structure includes `as_of` or `fetched_at` timestamp.

Implement these contracts in `src/providers/` per [DESIGN.md](DESIGN.md) architecture.