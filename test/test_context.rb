# frozen_string_literal: true

require_relative "test_helper"

class TestContext < Minitest::Test
  def setup
    @config = Loadsmith::Configuration.new
    @config.base_url = "http://localhost:9999"
    @ctx = Loadsmith::Context.new(user_id: 1, config: @config)
  end

  def test_initial_state
    assert_equal 1, @ctx.user_id
    assert_equal({}, @ctx.store)
    assert_equal [], @ctx.metrics
    assert_equal [], @ctx.errors
    refute @ctx.aborted?
    assert_equal({ "Content-Type" => "application/json" }, @ctx.default_headers)
  end

  def test_abort
    refute @ctx.aborted?
    @ctx.abort!
    assert @ctx.aborted?
  end

  def test_store_persistence
    @ctx.store[:key] = "value"
    assert_equal "value", @ctx.store[:key]
  end

  def test_default_headers_mutable
    @ctx.default_headers["Authorization"] = "Bearer token123"
    assert_equal "Bearer token123", @ctx.default_headers["Authorization"]
  end

  def test_get_returns_response_on_connection_error
    res = @ctx.get("/api/test")

    assert_instance_of Loadsmith::Response, res
    refute res.ok?
    assert_nil res.status
    assert res.error
  end

  def test_post_returns_response_on_connection_error
    res = @ctx.post("/api/test", json: { key: "value" })

    assert_instance_of Loadsmith::Response, res
    refute res.ok?
  end

  def test_metrics_recorded_on_error
    @ctx.get("/api/test")

    assert_equal 1, @ctx.metrics.size
    metric = @ctx.metrics[0]
    assert_equal :get, metric[:method]
    assert_equal "/api/test", metric[:path]
    assert_nil metric[:status]
    assert metric[:error]
  end

  def test_name_parameter_for_metrics
    @ctx.get("/api/cards/detail?id=42", name: "/api/cards/detail")

    metric = @ctx.metrics[0]
    assert_equal "/api/cards/detail", metric[:path]
  end

  def test_record_scenario_error
    @ctx.record_scenario_error(:home, "something broke")

    assert_equal 1, @ctx.errors.size
    assert_equal :home, @ctx.errors[0][:screen]
    assert_equal "something broke", @ctx.errors[0][:message]
  end

  def test_close_is_safe_when_not_connected
    # Should not raise
    @ctx.close
  end

  def test_current_screen_tracking
    assert_nil @ctx.current_screen
    @ctx.current_screen = :home
    assert_equal :home, @ctx.current_screen
  end
end
