# frozen_string_literal: true

require_relative "test_helper"

class TestScenarioBuilder < Minitest::Test
  def test_visit_step
    builder = Loadsmith::Scenario::Builder.new
    builder.visit(:home)

    assert_equal [{ type: :visit, screen: :home }], builder.steps
  end

  def test_think_with_range
    builder = Loadsmith::Scenario::Builder.new
    builder.think(1..3)

    assert_equal :think, builder.steps[0][:type]
    assert_equal 1..3, builder.steps[0][:range]
  end

  def test_think_with_number
    builder = Loadsmith::Scenario::Builder.new
    builder.think(2)

    assert_equal :think, builder.steps[0][:type]
    assert_equal 2..2, builder.steps[0][:range]
  end

  def test_think_with_invalid_arg
    builder = Loadsmith::Scenario::Builder.new
    assert_raises(ArgumentError) { builder.think("bad") }
  end

  def test_choose_with_blocks
    builder = Loadsmith::Scenario::Builder.new
    builder.choose do
      percent 70 do
        visit :cards
      end
      percent 30 do
        visit :missions
      end
    end

    step = builder.steps[0]
    assert_equal :choose, step[:type]
    assert_equal 2, step[:options].size
    assert_equal 70, step[:options][0][:weight]
    assert_equal 30, step[:options][1][:weight]
    assert_equal :cards, step[:options][0][:steps][0][:screen]
    assert_equal :missions, step[:options][1][:steps][0][:screen]
  end

  def test_choose_with_scenario_reference
    builder = Loadsmith::Scenario::Builder.new
    builder.choose do
      percent 60, scenario: :card_flow
      percent 40, scenario: :gacha_flow
    end

    step = builder.steps[0]
    assert_equal :card_flow, step[:options][0][:scenario]
    assert_equal :gacha_flow, step[:options][1][:scenario]
  end

  def test_percent_without_block_or_scenario_raises
    builder = Loadsmith::Scenario::Builder.new
    assert_raises(ArgumentError) do
      builder.choose do
        percent 100
      end
    end
  end

  def test_complex_scenario
    builder = Loadsmith::Scenario::Builder.new
    builder.instance_eval do
      visit :home
      think 1..3
      choose do
        percent 80 do
          visit :cards
          think 1..2
          visit :card_detail
        end
        percent 20, scenario: :mission_flow
      end
    end

    assert_equal 3, builder.steps.size
    assert_equal :visit, builder.steps[0][:type]
    assert_equal :think, builder.steps[1][:type]
    assert_equal :choose, builder.steps[2][:type]
  end
end

class TestScenarioExecutor < Minitest::Test
  def test_execute_visit
    visited = []
    screens = {
      home: ->(ctx) { visited << :home }
    }
    steps = [{ type: :visit, screen: :home }]

    config = Loadsmith::Configuration.new
    config.base_url = "http://localhost:9999"
    ctx = Loadsmith::Context.new(user_id: 1, config: config)

    executor = Loadsmith::Scenario::Executor.new(screens: screens, scenarios: {})
    executor.execute(steps, ctx)

    assert_equal [:home], visited
  end

  def test_execute_choose_respects_weights
    counts = { a: 0, b: 0 }
    screens = {
      a: ->(ctx) { counts[:a] += 1 },
      b: ->(ctx) { counts[:b] += 1 }
    }
    steps = [{
      type: :choose,
      options: [
        { weight: 100, steps: [{ type: :visit, screen: :a }] },
        { weight: 0, steps: [{ type: :visit, screen: :b }] }
      ]
    }]

    config = Loadsmith::Configuration.new
    config.base_url = "http://localhost:9999"
    ctx = Loadsmith::Context.new(user_id: 1, config: config)

    executor = Loadsmith::Scenario::Executor.new(screens: screens, scenarios: {})
    10.times { executor.execute(steps, ctx) }

    assert_equal 10, counts[:a]
    assert_equal 0, counts[:b]
  end

  def test_execute_stops_on_abort
    visited = []
    screens = {
      a: ->(ctx) { visited << :a; ctx.abort! },
      b: ->(ctx) { visited << :b }
    }
    steps = [
      { type: :visit, screen: :a },
      { type: :visit, screen: :b }
    ]

    config = Loadsmith::Configuration.new
    config.base_url = "http://localhost:9999"
    ctx = Loadsmith::Context.new(user_id: 1, config: config)

    executor = Loadsmith::Scenario::Executor.new(screens: screens, scenarios: {})
    executor.execute(steps, ctx)

    assert_equal [:a], visited
  end

  def test_execute_records_error_on_exception
    screens = {
      bad: ->(_ctx) { raise "boom" }
    }
    steps = [{ type: :visit, screen: :bad }]

    config = Loadsmith::Configuration.new
    config.base_url = "http://localhost:9999"
    ctx = Loadsmith::Context.new(user_id: 1, config: config)

    executor = Loadsmith::Scenario::Executor.new(screens: screens, scenarios: {})
    executor.execute(steps, ctx)

    assert_equal 1, ctx.errors.size
    assert_match(/RuntimeError: boom/, ctx.errors[0][:message])
  end

  def test_execute_sub_scenario
    visited = []
    screens = {
      x: ->(ctx) { visited << :x },
      y: ->(ctx) { visited << :y }
    }
    scenarios = {
      sub: [{ type: :visit, screen: :y }]
    }
    steps = [{
      type: :choose,
      options: [{ weight: 100, scenario: :sub }]
    }]

    config = Loadsmith::Configuration.new
    config.base_url = "http://localhost:9999"
    ctx = Loadsmith::Context.new(user_id: 1, config: config)

    executor = Loadsmith::Scenario::Executor.new(screens: screens, scenarios: scenarios)
    executor.execute(steps, ctx)

    assert_equal [:y], visited
  end
end
