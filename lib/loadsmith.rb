# frozen_string_literal: true

require "json"
require_relative "loadsmith/response"
require_relative "loadsmith/scenario"
require_relative "loadsmith/context"
require_relative "loadsmith/access"
require_relative "loadsmith/runner"
require_relative "loadsmith/stats"

module Loadsmith
  class Error < StandardError; end

  class Configuration
    attr_accessor :base_url, :workers, :users, :spawn_rate,
                  :open_timeout, :read_timeout, :duration

    def initialize
      @base_url = "http://localhost:3000"
      @workers = 4
      @users = 100
      @spawn_rate = 10
      @open_timeout = 5
      @read_timeout = 30
      @duration = nil
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def screens
      @screens ||= {}
    end

    def scenarios
      @scenarios ||= {}
    end

    def on_start_hook
      @on_start_hook
    end

    def on_stop_hook
      @on_stop_hook
    end

    # --- DSL ---

    def config(&block)
      configuration.instance_eval(&block)
    end

    def screen(name, &block)
      screens[name] = block
    end

    def scenario(name, &block)
      builder = Scenario::Builder.new
      builder.instance_eval(&block)
      scenarios[name] = builder.steps.freeze
    end

    def on_start(&block)
      @on_start_hook = block
    end

    def on_stop(&block)
      @on_stop_hook = block
    end

    def run(scenario_name)
      validate!(scenario_name)
      runner = Runner.new(
        scenario_name: scenario_name,
        screens: screens,
        scenarios: scenarios,
        config: configuration,
        on_start_hook: on_start_hook,
        on_stop_hook: on_stop_hook
      )
      runner.run
    end

    def reset!
      @configuration = Configuration.new
      @screens = {}
      @scenarios = {}
      @on_start_hook = nil
      @on_stop_hook = nil
    end

    private

    def validate!(scenario_name)
      unless scenarios.key?(scenario_name)
        raise Error, "Scenario :#{scenario_name} is not defined"
      end

      # Collect all referenced screens from all scenarios
      referenced = collect_referenced_screens(scenarios[scenario_name])
      missing = referenced - screens.keys
      unless missing.empty?
        raise Error, "Undefined screens referenced: #{missing.map { ":#{_1}" }.join(", ")}"
      end
    end

    def collect_referenced_screens(steps)
      screens_found = []
      steps.each do |step|
        case step[:type]
        when :visit
          screens_found << step[:screen]
        when :choose
          step[:options].each do |opt|
            if opt[:scenario]
              if scenarios.key?(opt[:scenario])
                screens_found.concat(collect_referenced_screens(scenarios[opt[:scenario]]))
              end
            elsif opt[:steps]
              screens_found.concat(collect_referenced_screens(opt[:steps]))
            end
          end
        end
      end
      screens_found.uniq
    end
  end
end
