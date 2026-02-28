# frozen_string_literal: true

require_relative "test_helper"

class TestDSL < Minitest::Test
  def setup
    Loadsmith.reset!
  end

  def test_config
    Loadsmith.config do
      self.base_url = "http://example.com"
      self.users = 50
      self.spawn_rate = 5
      self.workers = 2
      self.open_timeout = 3
      self.read_timeout = 10
    end

    cfg = Loadsmith.configuration
    assert_equal "http://example.com", cfg.base_url
    assert_equal 50, cfg.users
    assert_equal 5, cfg.spawn_rate
    assert_equal 2, cfg.workers
    assert_equal 3, cfg.open_timeout
    assert_equal 10, cfg.read_timeout
  end

  def test_screen_registration
    Loadsmith.screen(:home) { |ctx| }

    assert Loadsmith.screens.key?(:home)
    assert_respond_to Loadsmith.screens[:home], :call
  end

  def test_scenario_registration
    Loadsmith.screen(:home) { |ctx| }
    Loadsmith.scenario(:main) do
      visit :home
    end

    assert Loadsmith.scenarios.key?(:main)
    steps = Loadsmith.scenarios[:main]
    assert_equal 1, steps.size
    assert_equal :visit, steps[0][:type]
    assert_equal :home, steps[0][:screen]
  end

  def test_on_start_hook
    Loadsmith.on_start { |ctx| }
    assert_respond_to Loadsmith.on_start_hook, :call
  end

  def test_on_stop_hook
    Loadsmith.on_stop { |ctx| }
    assert_respond_to Loadsmith.on_stop_hook, :call
  end

  def test_reset_clears_everything
    Loadsmith.config { self.users = 999 }
    Loadsmith.screen(:x) { |ctx| }
    Loadsmith.scenario(:y) { visit :x }
    Loadsmith.on_start { |ctx| }
    Loadsmith.on_stop { |ctx| }

    Loadsmith.reset!

    assert_equal 100, Loadsmith.configuration.users
    assert_empty Loadsmith.screens
    assert_empty Loadsmith.scenarios
    assert_nil Loadsmith.on_start_hook
    assert_nil Loadsmith.on_stop_hook
  end

  def test_validate_missing_scenario
    assert_raises(Loadsmith::Error) do
      Loadsmith.send(:validate!, :nonexistent)
    end
  end

  def test_validate_missing_screen
    Loadsmith.scenario(:main) do
      visit :undefined_screen
    end

    err = assert_raises(Loadsmith::Error) do
      Loadsmith.send(:validate!, :main)
    end
    assert_match(/undefined_screen/, err.message)
  end

  def test_validate_passes_with_all_screens_defined
    Loadsmith.screen(:home) { |ctx| }
    Loadsmith.scenario(:main) { visit :home }

    # Should not raise
    Loadsmith.send(:validate!, :main)
  end

  def test_validate_checks_sub_scenario_screens
    Loadsmith.screen(:a) { |ctx| }
    Loadsmith.screen(:b) { |ctx| }
    Loadsmith.scenario(:sub) { visit :b }
    Loadsmith.scenario(:main) do
      choose do
        percent 50 do
          visit :a
        end
        percent 50, scenario: :sub
      end
    end

    # Should not raise — both :a and :b are defined
    Loadsmith.send(:validate!, :main)
  end
end
