# frozen_string_literal: true

require_relative "test_helper"

class TestStats < Minitest::Test
  def test_record_metric
    stats = Loadsmith::Stats.new
    stats.record_metric({ method: :get, path: "/api/test", status: 200, latency_ms: 50.0, error: nil })

    # Verify via finalize + save (checking internal state indirectly)
    stats.user_started
    stats.user_finished
    stats.finalize(1.0)

    # Should not raise
    assert_instance_of Loadsmith::Stats, stats
  end

  def test_user_counting
    stats = Loadsmith::Stats.new
    stats.user_started
    stats.user_started
    stats.user_finished

    stats.finalize(1.0)
    # Internal state: 2 started, 1 finished
    assert_instance_of Loadsmith::Stats, stats
  end

  def test_record_user_context
    config = Loadsmith::Configuration.new
    config.base_url = "http://localhost:9999"
    ctx = Loadsmith::Context.new(user_id: 1, config: config)

    # Simulate a metric being recorded in context
    ctx.instance_variable_get(:@metrics) << {
      method: :get, path: "/test", status: 200,
      latency_ms: 25.0, error: nil, screen: :home, time: Time.now
    }

    stats = Loadsmith::Stats.new
    stats.record_user(ctx)
    stats.finalize(1.0)

    assert_instance_of Loadsmith::Stats, stats
  end

  def test_save_to_file
    stats = Loadsmith::Stats.new
    stats.record_metric({ method: :get, path: "/api/test", status: 200, latency_ms: 30.0, error: nil, screen: :home, time: Time.now })
    stats.user_started
    stats.user_finished
    stats.finalize(1.0)

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        stats.save_to_file
        files = Dir.glob("loadsmith_results_*.json")
        assert_equal 1, files.size

        data = JSON.parse(File.read(files[0]))
        assert_equal 1, data["total_requests"]
        assert_equal 1, data["total_users"]
        assert data["endpoints"].is_a?(Array)
        assert data["raw_metrics"].is_a?(Array)
      end
    end
  end
end
