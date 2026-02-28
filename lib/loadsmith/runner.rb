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
    attr_reader :stats

    def initialize(runner, web_mode: false)
      @runner = runner
      @stats = Stats.new
      @mu = Mutex.new
      @active_count = 0
      @stop = false
      @running = false
      @start_time = nil
      @web_mode = web_mode

      # Dynamic scaling state
      @target_pool = 0
      @spawn_rate = runner.config.spawn_rate
      @spawned = 0
      @threads = []
    end

    def run
      @running = true
      @start_time = Time.now
      config = @runner.config
      @target_pool = config.users
      @spawn_rate = config.spawn_rate

      puts "Loadsmith starting (ThreadRunner)"
      puts "  Scenario: :#{@runner.scenario_name}"
      puts "  User Pool: #{@target_pool}, Spawn rate: #{@spawn_rate}/s, Concurrent: #{config.workers} threads"
      puts "  Duration: #{config.duration ? "#{config.duration}s" : "unlimited (until stopped)"}"
      puts "  Target: #{config.base_url}"
      puts ""

      monitor = @web_mode ? nil : start_monitor(@start_time)

      # Scaler thread: continuously adjusts pool to match @target_pool
      scaler = Thread.new { run_scaler }

      begin
        # Wait until stopped or duration elapsed
        if config.duration
          deadline = @start_time + config.duration
          sleep 0.1 until @stop || Time.now >= deadline
          @stop = true
        else
          sleep 0.1 until @stop
        end
        @threads.each { _1.join(2) }
      rescue Interrupt
        @stop = true
        puts "\nStopping..."
        @threads.each { _1.join(2) }
      ensure
        @stop = true
        scaler&.kill
        monitor&.kill
      end

      @stats.finalize(Time.now - @start_time)
      @stats.print_summary unless @web_mode
      @stats.save_to_file
      @running = false
    end

    # Run the load test in a background thread. Returns immediately.
    def start_async(&on_complete)
      Thread.new do
        run
        on_complete&.call
      end
    end

    def stop
      @stop = true
    end

    def running?
      @running
    end

    def active_count
      @active_count
    end

    def elapsed
      @start_time ? (Time.now - @start_time).to_i : 0
    end

    # --- Dynamic scaling (callable mid-test) ---

    def update_pool(target)
      @target_pool = target
    end

    def update_spawn_rate(rate)
      @spawn_rate = rate
    end

    private

    def run_scaler
      until @stop
        current = @active_count

        if @spawned < @target_pool
          # Scale UP: spawn more users
          @spawned += 1
          @threads << spawn_user(@spawned)
          sleep(1.0 / @spawn_rate) unless @spawned >= @target_pool
        else
          sleep 0.1
        end
      end
    end

    def spawn_user(user_id)
      Thread.new do
        @mu.synchronize { @active_count += 1 }
        @stats.user_started

        executor = Scenario::Executor.new(
          screens: @runner.screens,
          scenarios: @runner.scenarios
        )

        while !@stop
          # Scale down: if more active users than target, this user exits
          break if @active_count > @target_pool

          ctx = Context.new(user_id: user_id, config: @runner.config)
          begin
            @runner.on_start_hook&.call(ctx)
            executor.execute(@runner.scenarios[@runner.scenario_name], ctx)
            @runner.on_stop_hook&.call(ctx)
          rescue StandardError => e
            ctx.record_scenario_error(ctx.current_screen, "#{e.class}: #{e.message}")
          ensure
            ctx.close
            @stats.record_user(ctx)
          end
        end

        @stats.user_finished
        @mu.synchronize { @active_count -= 1 }
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
      pool_size = config.users
      spawn_rate = config.spawn_rate
      num_workers = config.workers
      scenario_name = @runner.scenario_name

      puts "Loadsmith starting (RactorRunner)"
      puts "  Scenario: :#{scenario_name}"
      puts "  User Pool: #{pool_size}, Spawn rate: #{spawn_rate}/s, Concurrent: #{num_workers} Ractors"
      puts "  Duration: #{config.duration ? "#{config.duration}s" : "unlimited (until stopped)"}"
      puts "  Target: #{config.base_url}"
      puts ""

      stats_port = Ractor::Port.new

      # Prepare shareable data
      screens = prepare_screens
      scenarios = prepare_scenarios
      config_data = prepare_config
      scenario_name_frozen = scenario_name.to_s.freeze.to_sym

      on_start_hook = @runner.on_start_hook ? Ractor.shareable_proc(&@runner.on_start_hook) : nil
      on_stop_hook = @runner.on_stop_hook ? Ractor.shareable_proc(&@runner.on_stop_hook) : nil

      # Launch worker Ractors — each loops its scenario until :stop
      workers = pool_size.times.map do |i|
        user_id = i + 1
        Ractor.new(user_id, screens, scenarios, config_data, scenario_name_frozen,
                   stats_port,
                   on_start_hook, on_stop_hook) do |uid, scr, scns, cfg, sc_name, sp, on_s, on_e|
          # Wait for :start signal
          Ractor.receive

          executor = Loadsmith::Scenario::Executor.new(screens: scr, scenarios: scns)

          loop do
            # Check for :stop (non-blocking)
            msg = Ractor.receive_if { |m| m == :stop } rescue nil
            break if msg == :stop

            config_obj = Loadsmith::Configuration.new
            config_obj.base_url = cfg[:base_url]
            config_obj.open_timeout = cfg[:open_timeout]
            config_obj.read_timeout = cfg[:read_timeout]

            ctx = Loadsmith::Context.new(user_id: uid, config: config_obj)

            begin
              on_s&.call(ctx)
              executor.execute(scns[sc_name], ctx)
              on_e&.call(ctx)
            rescue StandardError => e
              ctx.record_scenario_error(ctx.current_screen, "#{e.class}: #{e.message}")
            ensure
              ctx.close
            end

            sp.send(ctx.metrics)
          end

          sp.send(:done)
        end
      end

      # Stats collector thread
      active_count = pool_size
      stats_thread = Thread.new do
        loop do
          metrics = stats_port.receive
          if metrics == :stop
            break
          elsif metrics == :done
            active_count -= 1
            @stats.user_finished
            next
          end

          metrics.each { |m| @stats.record_metric(m) }
        end
      end

      # Spawn users at configured rate
      start_time = Time.now
      spawn_interval = 1.0 / spawn_rate

      monitor = Thread.new do
        loop do
          sleep 1
          elapsed = (Time.now - start_time).to_i
          @stats.print_live(elapsed, active_count, pool_size)
        end
      end

      begin
        workers.each_with_index do |w, i|
          @stats.user_started
          w.send(:start)
          sleep spawn_interval unless i == workers.size - 1
        end

        # Wait until stopped or duration elapsed
        if config.duration
          deadline = start_time + config.duration
          sleep 0.1 until Time.now >= deadline
        else
          sleep 0.1 until false  # Wait for Interrupt
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
