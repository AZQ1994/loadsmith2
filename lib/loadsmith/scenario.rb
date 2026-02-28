# frozen_string_literal: true

module Loadsmith
  module Scenario
    # Records scenario steps as pure data structures from the DSL block.
    class Builder
      attr_reader :steps

      def initialize
        @steps = []
      end

      def visit(screen_name)
        @steps << { type: :visit, screen: screen_name }
      end

      def think(range_or_number)
        range = case range_or_number
                when Range then range_or_number
                when Numeric then range_or_number..range_or_number
                else raise ArgumentError, "think expects a Range or Numeric, got #{range_or_number.class}"
                end
        @steps << { type: :think, range: range }
      end

      def choose(&block)
        chooser = Chooser.new
        chooser.instance_eval(&block)
        @steps << { type: :choose, options: chooser.options.freeze }
      end
    end

    # Collects weighted options inside a choose block.
    class Chooser
      attr_reader :options

      def initialize
        @options = []
      end

      def percent(weight, scenario: nil, &block)
        if scenario
          @options << { weight: weight, scenario: scenario }
        elsif block
          sub = Builder.new
          sub.instance_eval(&block)
          @options << { weight: weight, steps: sub.steps.freeze }
        else
          raise ArgumentError, "percent requires either a scenario: keyword or a block"
        end
      end
    end

    # Executes a recorded scenario (step array) against a Context.
    class Executor
      def initialize(screens:, scenarios:)
        @screens = screens
        @scenarios = scenarios
      end

      def execute(steps, ctx)
        steps.each do |step|
          break if ctx.aborted?

          case step[:type]
          when :visit
            execute_visit(step[:screen], ctx)
          when :think
            sleep(rand(step[:range]) + rand)
          when :choose
            execute_choose(step[:options], ctx)
          end
        end
      end

      private

      def execute_visit(screen_name, ctx)
        screen_proc = @screens[screen_name]
        unless screen_proc
          ctx.record_scenario_error(screen_name, "Screen :#{screen_name} not found")
          return
        end

        ctx.current_screen = screen_name
        screen_proc.call(ctx)
      rescue StandardError => e
        ctx.record_scenario_error(screen_name, "#{e.class}: #{e.message}")
      end

      def execute_choose(options, ctx)
        total = options.sum { _1[:weight] }
        roll = rand(1..total)

        selected = nil
        options.each do |opt|
          roll -= opt[:weight]
          if roll <= 0
            selected = opt
            break
          end
        end
        return unless selected

        if selected[:scenario]
          sub_steps = @scenarios[selected[:scenario]]
          if sub_steps
            execute(sub_steps, ctx)
          else
            ctx.record_scenario_error(nil, "Scenario :#{selected[:scenario]} not found")
          end
        elsif selected[:steps]
          execute(selected[:steps], ctx)
        end
      end
    end
  end
end
