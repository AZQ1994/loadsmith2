# frozen_string_literal: true

module Loadsmith
  class Runner
    attr_reader :scenario_name, :screens, :scenarios, :config,
                :on_start_hook, :on_stop_hook

    def initialize(scenario_name:, screens:, scenarios:, config:,
                   on_start_hook: nil, on_stop_hook: nil)
      @scenario_name = scenario_name
      @screens = screens
      @scenarios = scenarios
      @config = config
      @on_start_hook = on_start_hook
      @on_stop_hook = on_stop_hook
    end

    def run
      impl = if ractor_available?
               RactorRunner.new(self)
             else
               ThreadRunner.new(self)
             end
      impl.run
    end

    private

    def ractor_available?
      RUBY_VERSION >= "4.0" && defined?(Ractor::Port)
    rescue
      false
    end
  end

  # Thread-based runner. Works on all Ruby versions.
  class ThreadRunner
    def initialize(runner)
      @runner = runner
      @stats = Stats.new
      @active_users = Mutex.new
      @active_count = 0
      @stop = false
    end

    def run
      config = @runner.config
      total_users = config.users
      spawn_rate = config.spawn_rate
      max_workers = config.workers

      puts "Loadsmith starting (ThreadRunner)"
      puts "  Scenario: :#{@runner.scenario_name}"
      puts "  Users: #{total_users}, Spawn rate: #{spawn_rate}/s, Workers: #{max_workers} threads"
      puts "  Target: #{config.base_url}"
      puts ""

      start_time = Time.now
      monitor = start_monitor(start_time)
      threads = []
      spawned = 0

      begin
        while spawned < total_users && !@stop
          # Spawn up to spawn_rate users per second
          batch = [spawn_rate, total_users - spawned].min
          batch.times do
            # Wait if we've hit worker limit
            while @active_count >= max_workers && !@stop
              sleep 0.05
            end
            break if @stop

            spawned += 1
            user_id = spawned
            threads << spawn_user(user_id)
          end
          sleep 1 unless @stop
        end

        threads.each(&:join)
      rescue Interrupt
        @stop = true
        puts "\nStopping..."
        threads.each { _1.join(2) }
      ensure
        @stop = true
        monitor&.kill
      end

      @stats.finalize(Time.now - start_time)
      @stats.print_summary
      @stats.save_to_file
    end

    private

    def spawn_user(user_id)
      Thread.new do
        @active_users.synchronize { @active_count += 1 }
        @stats.user_started

        ctx = Context.new(user_id: user_id, config: @runner.config)
        executor = Scenario::Executor.new(
          screens: @runner.screens,
          scenarios: @runner.scenarios
        )

        begin
          @runner.on_start_hook&.call(ctx)
          executor.execute(@runner.scenarios[@runner.scenario_name], ctx)
          @runner.on_stop_hook&.call(ctx)
        rescue StandardError => e
          ctx.record_scenario_error(ctx.current_screen, "#{e.class}: #{e.message}")
        ensure
          ctx.close
          @stats.record_user(ctx)
          @stats.user_finished
          @active_users.synchronize { @active_count -= 1 }
        end
      end
    end

    def start_monitor(start_time)
      Thread.new do
        loop do
          break if @stop
          sleep 1
          elapsed = (Time.now - start_time).to_i
          @stats.print_live(elapsed, @active_count, @runner.config.users)
        end
      end
    end
  end

  # Ractor-based runner for Ruby 4.0+. Uses Ractor::Port for communication.
  class RactorRunner
    def initialize(runner)
      @runner = runner
      @stats = Stats.new
    end

    def run
      config = @runner.config
      total_users = config.users
      spawn_rate = config.spawn_rate
      num_workers = config.workers
      scenario_name = @runner.scenario_name

      puts "Loadsmith starting (RactorRunner)"
      puts "  Scenario: :#{scenario_name}"
      puts "  Users: #{total_users}, Spawn rate: #{spawn_rate}/s, Workers: #{num_workers} Ractors"
      puts "  Target: #{config.base_url}"
      puts ""

      stats_port = Ractor::Port.new
      done_port = Ractor::Port.new

      # Prepare shareable data
      screens = prepare_screens
      scenarios = prepare_scenarios
      config_data = prepare_config
      scenario_name_frozen = scenario_name.to_s.freeze.to_sym

      on_start_hook = @runner.on_start_hook ? Ractor.shareable_proc(&@runner.on_start_hook) : nil
      on_stop_hook = @runner.on_stop_hook ? Ractor.shareable_proc(&@runner.on_stop_hook) : nil

      # Launch worker Ractors
      workers = num_workers.times.map do
        Ractor.new(screens, scenarios, config_data, scenario_name_frozen,
                   stats_port, done_port,
                   on_start_hook, on_stop_hook) do |scr, scns, cfg, sc_name, sp, dp, on_s, on_e|
          loop do
            msg = Ractor.receive
            break if msg == :stop

            user_id = msg
            config_obj = Loadsmith::Configuration.new
            config_obj.base_url = cfg[:base_url]
            config_obj.open_timeout = cfg[:open_timeout]
            config_obj.read_timeout = cfg[:read_timeout]

            ctx = Loadsmith::Context.new(user_id: user_id, config: config_obj)
            executor = Loadsmith::Scenario::Executor.new(screens: scr, scenarios: scns)

            begin
              on_s&.call(ctx)
              executor.execute(scns[sc_name], ctx)
              on_e&.call(ctx)
            rescue StandardError => e
              ctx.record_scenario_error(ctx.current_screen, "#{e.class}: #{e.message}")
            ensure
              ctx.close
            end

            sp.send(ctx.metrics + [{ __user_done__: true }])
            dp.send(user_id)
          end
        end
      end

      # Stats collector thread
      stats_thread = Thread.new do
        loop do
          metrics = stats_port.receive
          break if metrics == :stop

          @stats.user_started
          metrics.each do |m|
            next if m.key?(:__user_done__)
            @stats.record_metric(m)
          end
          @stats.user_finished
        end
      end

      # Spawn users
      start_time = Time.now
      spawned = 0
      finished = 0
      worker_idx = 0

      monitor = Thread.new do
        loop do
          sleep 1
          elapsed = (Time.now - start_time).to_i
          active = spawned - finished
          @stats.print_live(elapsed, active, total_users)
        end
      end

      begin
        while spawned < total_users
          batch = [spawn_rate, total_users - spawned].min
          batch.times do
            spawned += 1
            workers[worker_idx % num_workers].send(spawned)
            worker_idx += 1
          end
          sleep 1
        end

        # Wait for all to complete
        while finished < total_users
          done_port.receive
          finished += 1
        end
      rescue Interrupt
        puts "\nStopping..."
      ensure
        monitor&.kill
        workers.each do |w|
          w.send(:stop) rescue nil
        end
        workers.each { |w| w.join rescue nil }
        stats_port.send(:stop)
        stats_thread&.join(5)
      end

      @stats.finalize(Time.now - start_time)
      @stats.print_summary
      @stats.save_to_file
    end

    private

    def prepare_screens
      h = {}
      @runner.screens.each do |name, block|
        h[name] = Ractor.shareable_proc(&block)
      end
      Ractor.make_shareable(h)
    end

    def prepare_scenarios
      Ractor.make_shareable(@runner.scenarios.transform_values(&:dup))
    end

    def prepare_config
      c = @runner.config
      Ractor.make_shareable({
        base_url: c.base_url,
        open_timeout: c.open_timeout,
        read_timeout: c.read_timeout
      })
    end
  end
end
