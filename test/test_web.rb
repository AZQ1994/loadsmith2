# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/loadsmith/web"
require "net/http"
require "json"

class TestWeb < Minitest::Test
  def setup
    Loadsmith.reset!
    Loadsmith.config do
      self.base_url = "http://localhost:9999"
      self.users = 2
      self.spawn_rate = 10
      self.workers = 2
    end
    Loadsmith.screen(:home) { |ctx| }
    Loadsmith.scenario(:main) { visit :home }
  end

  def test_status_returns_scenarios_and_config
    with_server do |port|
      res = get(port, "/api/status")
      data = JSON.parse(res.body)

      assert_equal "idle", data["state"]
      assert_includes data["scenarios"], "main"
      assert_equal "http://localhost:9999", data["config"]["base_url"]
      assert_equal 2, data["config"]["users"]
    end
  end

  def test_start_returns_running_state
    with_server do |port|
      res = post(port, "/api/start", { scenario: "main" })
      data = JSON.parse(res.body)

      assert_equal "running", data["state"]
      assert_equal "main", data["scenario"]
    end
  end

  def test_start_rejects_unknown_scenario
    with_server do |port|
      res = post(port, "/api/start", { scenario: "nonexistent" })
      assert_equal "400", res.code

      data = JSON.parse(res.body)
      assert_match(/nonexistent/, data["error"])
    end
  end

  def test_start_rejects_duplicate
    with_server do |port|
      post(port, "/api/start", { scenario: "main" })
      res = post(port, "/api/start", { scenario: "main" })
      assert_equal "409", res.code
    end
  end

  def test_stop_when_not_running
    with_server do |port|
      res = post(port, "/api/stop", {})
      assert_equal "409", res.code
    end
  end

  def test_dashboard_returns_html
    with_server do |port|
      res = get(port, "/")
      assert_equal "200", res.code
      assert_match(/text\/html/, res["Content-Type"])
      assert_match(/Loadsmith/, res.body)
      assert_match(/chart\.js/, res.body)
    end
  end

  def test_stream_snapshot_idle
    server = build_server(0)
    snapshot = server.stream_snapshot

    assert_equal "idle", snapshot[:state]
    assert_equal 0, snapshot[:rps]
    assert_equal 0, snapshot[:active_users]
    assert_equal [], snapshot[:endpoints]
  end

  def test_stats_snapshot
    stats = Loadsmith::Stats.new
    stats.record_metric({ method: :get, path: "/api/test", status: 200, latency_ms: 50.0, error: nil })
    stats.record_metric({ method: :post, path: "/api/create", status: 201, latency_ms: 80.0, error: nil })
    stats.user_started
    stats.user_finished

    snapshot = stats.snapshot(elapsed: 10, active_users: 3, total_users: 5)

    assert_equal 2, snapshot[:rps]
    assert_equal 0, snapshot[:error_count]
    assert_equal 2, snapshot[:total_requests]
    assert_equal 10, snapshot[:elapsed]
    assert_equal 3, snapshot[:active_users]
    assert_equal 5, snapshot[:total_users]
    assert_equal 1, snapshot[:finished_users]
    assert_equal 2, snapshot[:endpoints].size

    # cumulative_endpoints always shows all-time data
    assert_equal 2, snapshot[:cumulative_endpoints].size

    # interval_metrics should be cleared after snapshot
    snapshot2 = stats.snapshot(elapsed: 11, active_users: 3, total_users: 5)
    assert_equal 0, snapshot2[:rps]
    assert_equal 0, snapshot2[:endpoints].size
    assert_equal 2, snapshot2[:total_requests]
    # cumulative still has data
    assert_equal 2, snapshot2[:cumulative_endpoints].size
  end

  def test_stats_snapshot_with_errors
    stats = Loadsmith::Stats.new
    stats.record_metric({ method: :get, path: "/fail", status: 500, latency_ms: 10.0, error: nil })
    stats.record_metric({ method: :get, path: "/err", status: nil, latency_ms: nil, error: "Timeout" })

    snapshot = stats.snapshot(elapsed: 1, active_users: 1, total_users: 1)

    assert_equal 2, snapshot[:error_count]
    assert_equal 2, snapshot[:total_errors]
  end

  def test_stats_snapshot_cumulative_endpoint_format
    stats = Loadsmith::Stats.new
    stats.record_metric({ method: :get, path: "/api/items", status: 200, latency_ms: 25.0, error: nil })
    stats.record_metric({ method: :get, path: "/api/items", status: 200, latency_ms: 75.0, error: nil })

    snapshot = stats.snapshot(elapsed: 1, active_users: 1, total_users: 1)
    ep = snapshot[:cumulative_endpoints].first

    assert_equal 2, ep[:count]
    assert_equal 50.0, ep[:avg]
    assert_equal 25.0, ep[:min]
    assert_equal 75.0, ep[:max]
    assert_equal 0, ep[:errors]
    assert_match(/GET/, ep[:name])
  end

  def test_stats_snapshot_endpoint_format
    stats = Loadsmith::Stats.new
    stats.record_metric({ method: :get, path: "/api/items", status: 200, latency_ms: 25.0, error: nil })

    snapshot = stats.snapshot(elapsed: 1, active_users: 1, total_users: 1)
    ep = snapshot[:endpoints].first

    assert_equal 1, ep[:count]
    assert_equal 25.0, ep[:avg]
    assert_equal 25.0, ep[:p95]
    assert_equal 25.0, ep[:p99]
    assert_equal 0, ep[:errors]
    assert_match(/GET/, ep[:name])
    assert_match(/\/api\/items/, ep[:name])
  end

  private

  def build_server(port)
    Loadsmith::Web::Server.new(
      screens: Loadsmith.screens,
      scenarios: Loadsmith.scenarios,
      config: Loadsmith.configuration,
      port: port
    )
  end

  def with_server
    port = rand(10_000..60_000)
    server = build_server(port)

    thread = Thread.new { server.start }
    sleep 0.5 # Wait for server to bind

    yield port
  ensure
    server.instance_variable_get(:@server)&.shutdown
    thread&.join(3)
  end

  def get(port, path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{port}#{path}"))
  end

  def post(port, path, data)
    uri = URI("http://127.0.0.1:#{port}#{path}")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = JSON.generate(data)
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  end
end
