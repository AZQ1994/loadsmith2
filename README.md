# Loadsmith

A screen-transition-based load testing framework for Ruby. Define user flows as screen navigations, and Loadsmith measures per-API performance with real-time stats.

- **Screen-based scenarios** — model what users actually do (visit screens), not raw API calls
- **Per-API metrics** — latency percentiles (p50/p95/p99), RPS, error rates per endpoint
- **Ractor support** — parallel execution with Ractor workers on Ruby 4.0+, Thread fallback on 3.2+
- **Access classes** — reusable, class-based API definitions with before/after hooks
- **Zero dependencies** — stdlib only (Net::HTTP, JSON, WEBrick)

## Quick Start

```ruby
require "loadsmith"

Loadsmith.config do
  self.base_url   = "http://localhost:3000"
  self.users      = 100
  self.spawn_rate = 10
  self.workers    = 4
end

Loadsmith.screen :home do |ctx|
  ctx.get "/api/home"
end

Loadsmith.scenario :main do
  visit :home
end

Loadsmith.run :main
```

## Concepts

### Screens

A screen represents a page or view the user sees. Each screen can make one or more API requests:

```ruby
Loadsmith.screen :card_list do |ctx|
  res = ctx.get "/api/cards"
  ctx.store[:cards] = res["cards"] if res.success?
end
```

`ctx` provides HTTP methods (`get`, `post`, `put`, `patch`, `delete`) and a `store` hash for passing data between screens.

### Scenarios

Scenarios define screen transition flows using a simple DSL:

```ruby
Loadsmith.scenario :main do
  visit :home
  think 1..3          # random wait 1-3s (simulates user reading)

  choose do           # weighted random branching
    percent 70 do
      visit :card_list
      think 1..2
      visit :card_detail
    end
    percent 30, scenario: :gacha_flow   # reference another scenario
  end
end
```

### Access Classes

For reusable API definitions, subclass `Loadsmith::Access`. Each class defines an endpoint, each instance is one request:

```ruby
class Login < Loadsmith::Access
  post "/api/auth/login"

  def request_json
    { user_id: "user_#{ctx.user_id}" }
  end

  def after(res)
    ctx.default_headers["Authorization"] = "Bearer #{res['token']}" if res.success?
  end
end

class CardList < Loadsmith::Access
  get "/api/cards"

  def after(res)
    ctx.store[:cards] = res["cards"] if res.success?
  end
end

# Use in screens:
Loadsmith.screen :card_list do |ctx|
  CardList.call(ctx)
end

# Or in lifecycle hooks:
Loadsmith.on_start do |ctx|
  Login.call(ctx)
end
```

**Override points:**

| Method | Purpose |
|--------|---------|
| `before` | Pre-request setup |
| `after(response)` | Post-request processing |
| `request_json` | JSON request body |
| `request_body` | Raw request body |
| `request_params` | Query parameters |
| `request_headers` | Additional headers |
| `build_path` | Dynamic path construction |

### Response

All HTTP methods return a `Loadsmith::Response` with convenience accessors:

```ruby
res = ctx.get "/api/cards"
res.ok?       # true if network succeeded (no timeout/connection error)
res.success?  # true if HTTP 2xx
res.status    # HTTP status code (Integer)
res.json      # auto-parsed JSON (memoized, {} on error)
res["cards"]  # shortcut for res.json["cards"]
res.body      # raw response body
res.error     # error class name on network failure
```

### Lifecycle Hooks

```ruby
Loadsmith.on_start do |ctx|
  # Runs once per user before the scenario (login, setup, etc.)
  Login.call(ctx)
end

Loadsmith.on_stop do |ctx|
  # Runs once per user after the scenario (logout, cleanup, etc.)
  Logout.call(ctx)
end
```

### Metrics Grouping

Use `name:` to aggregate dynamic paths under one metric key:

```ruby
# Without name: /api/cards/detail?id=1, /api/cards/detail?id=42 appear as separate entries
# With name: all grouped under /api/cards/detail
ctx.get "/api/cards/detail?id=#{id}", name: "/api/cards/detail"

# Or with Access class:
class CardDetail < Loadsmith::Access
  get "/api/cards/detail"
  name "/api/cards/detail"
end
```

## Configuration

```ruby
Loadsmith.config do
  self.base_url     = "http://localhost:3000"  # Target server
  self.users        = 100                      # Total virtual users
  self.spawn_rate   = 10                       # Users spawned per second
  self.workers      = 4                        # Ractor/Thread pool size
  self.open_timeout = 5                        # Connection timeout (seconds)
  self.read_timeout = 30                       # Read timeout (seconds)
end
```

## Output

### Real-time Terminal

```
Loadsmith - 00:15 elapsed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RPS: 42 | Users: 20 active, 30/100 done | Errors: 0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Endpoint                        Count  Avg(ms)  P95(ms)  P99(ms)  Err
GET    /api/cards                  18       85      120      130    0
POST   /api/gacha/draw              8      170      250      260    0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Final Summary

Per-endpoint breakdown with p50/p95/p99 latencies, printed after the test completes.

### JSON File

Results are automatically saved to `loadsmith_results_YYYYMMDD_HHMMSS.json` with full endpoint summaries and raw metrics.

## Runner Selection

Loadsmith auto-selects the best runner:

| Ruby Version | Runner | Parallelism |
|-------------|--------|-------------|
| 4.0+ | `RactorRunner` | True parallel Ractors |
| 3.2+ | `ThreadRunner` | Thread pool (GVL-bound) |

## Running the Example

```bash
# Terminal 1: Start the test server
ruby bin/test_server

# Terminal 2: Run the load test
ruby example/sample_test.rb
```

## Project Structure

```
lib/
  loadsmith.rb              # DSL entry point, configuration
  loadsmith/
    access.rb               # Access base class for API definitions
    response.rb             # Response wrapper
    scenario.rb             # Scenario builder & executor
    context.rb              # Per-user HTTP context
    runner.rb               # RactorRunner / ThreadRunner
    stats.rb                # Metrics collection & reporting
```

## License

MIT
