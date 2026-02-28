# frozen_string_literal: true

require "json"
require "time"

module Loadsmith
  class Stats
    def initialize
      @mutex = Mutex.new
      @metrics = []           # All recorded request metrics
      @active_users = 0
      @total_started = 0
      @total_finished = 0
      @scenario_errors = []
      @interval_metrics = []  # Metrics accumulated since last live print
    end

    def record_metric(metric)
      @mutex.synchronize do
        @metrics << metric
        @interval_metrics << metric
      end
    end

    def record_user(ctx)
      @mutex.synchronize do
        @metrics.concat(ctx.metrics)
        @interval_metrics.concat(ctx.metrics)
        ctx.errors.each do |err|
          @scenario_errors << err.merge(user_id: ctx.user_id)
        end
      end
    end

    def user_started
      @mutex.synchronize { @total_started += 1 }
    end

    def user_finished
      @mutex.synchronize { @total_finished += 1 }
    end

    def print_live(elapsed, active_count, total_users)
      interval, rps = @mutex.synchronize do
        m = @interval_metrics.dup
        @interval_metrics.clear
        [m, m.size]
      end

      errors = interval.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
      finished = @mutex.synchronize { @total_finished }

      mm = elapsed / 60
      ss = elapsed % 60
      time_str = format("%02d:%02d", mm, ss)

      print "\e[2J\e[H"  # Clear screen
      puts "Loadsmith - #{time_str} elapsed"
      puts "\u2501" * 62
      puts "RPS: #{rps} | Users: #{active_count} active, #{finished}/#{total_users} done | Errors: #{errors}"
      puts "\u2501" * 62

      # Per-endpoint breakdown from interval
      by_endpoint = interval.group_by { |m| "#{m[:method].to_s.upcase.ljust(6)} #{m[:path]}" }
      unless by_endpoint.empty?
        puts format("%-30s %6s %8s %8s %8s %4s", "Endpoint", "Count", "Avg(ms)", "P95(ms)", "P99(ms)", "Err")
        by_endpoint.sort_by { |k, _| k }.each do |key, reqs|
          latencies = reqs.filter_map { _1[:latency_ms] }.sort
          count = reqs.size
          err = reqs.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
          avg = latencies.empty? ? 0 : (latencies.sum / latencies.size).round(0)
          p95 = percentile(latencies, 95)
          p99 = percentile(latencies, 99)
          puts format("%-30s %6d %8.0f %8.0f %8.0f %4d", key, count, avg, p95, p99, err)
        end
      end

      puts "\u2501" * 62

      # Show recent scenario errors
      recent_errors = @mutex.synchronize { @scenario_errors.last(3) }
      recent_errors.each do |err|
        puts "\e[33m[WARN] User##{err[:user_id]} in :#{err[:screen]} \u2014 #{err[:message]}\e[0m"
      end
    end

    # Returns a snapshot of current metrics for the web UI (SSE streaming).
    # Clears interval_metrics, just like print_live does.
    def snapshot(elapsed: 0, active_users: 0, total_users: 0)
      @mutex.synchronize do
        interval = @interval_metrics.dup
        @interval_metrics.clear
        {
          rps: interval.size,
          error_count: interval.count { _1[:error] || (_1[:status] && _1[:status] >= 400) },
          total_requests: @metrics.size,
          total_errors: @metrics.count { _1[:error] || (_1[:status] && _1[:status] >= 400) },
          elapsed: elapsed,
          active_users: active_users,
          total_users: total_users,
          finished_users: @total_finished,
          endpoints: build_interval_endpoints(interval),
          cumulative_endpoints: build_cumulative_endpoints,
          recent_errors: @scenario_errors.last(5).map { |e|
            { user_id: e[:user_id], screen: e[:screen]&.to_s, message: e[:message] }
          }
        }
      end
    end

    def finalize(duration)
      @duration = duration
    end

    def print_summary
      puts ""
      puts ""
      puts "=" * 62
      puts "LOAD TEST COMPLETE"
      puts "=" * 62

      mm = (@duration / 60).to_i
      ss = (@duration % 60).round(1)
      puts "Duration: #{mm}m #{ss}s"
      puts "Total requests: #{@metrics.size}"
      puts "Total users: #{@total_finished}"
      puts ""

      by_endpoint = @metrics.group_by { |m| "#{m[:method].to_s.upcase.ljust(6)} #{m[:path]}" }
      puts format("%-30s %6s %8s %8s %8s %8s %4s",
                   "Endpoint", "Count", "Avg(ms)", "P50(ms)", "P95(ms)", "P99(ms)", "Err")
      puts "-" * 78

      by_endpoint.sort_by { |k, _| k }.each do |key, reqs|
        latencies = reqs.filter_map { _1[:latency_ms] }.sort
        count = reqs.size
        err = reqs.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
        avg = latencies.empty? ? 0 : (latencies.sum / latencies.size).round(1)
        p50 = percentile(latencies, 50)
        p95 = percentile(latencies, 95)
        p99 = percentile(latencies, 99)
        puts format("%-30s %6d %8.1f %8.1f %8.1f %8.1f %4d", key, count, avg, p50, p95, p99, err)
      end

      puts "-" * 78
      total_err = @metrics.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
      all_latencies = @metrics.filter_map { _1[:latency_ms] }.sort
      total_avg = all_latencies.empty? ? 0 : (all_latencies.sum / all_latencies.size).round(1)
      puts format("%-30s %6d %8.1f %8s %8s %8s %4d",
                   "TOTAL", @metrics.size, total_avg, "", "", "", total_err)
      puts ""

      unless @scenario_errors.empty?
        puts "Scenario Errors (#{@scenario_errors.size} total):"
        @scenario_errors.first(10).each do |err|
          puts "  User##{err[:user_id]} in :#{err[:screen]} \u2014 #{err[:message]}"
        end
        puts "  ... and #{@scenario_errors.size - 10} more" if @scenario_errors.size > 10
        puts ""
      end

      puts "=" * 62
    end

    def save_to_file
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      filename = "loadsmith_results_#{timestamp}.json"

      data = {
        timestamp: Time.now.iso8601,
        duration_seconds: @duration.round(2),
        total_requests: @metrics.size,
        total_users: @total_finished,
        total_errors: @metrics.count { _1[:error] || (_1[:status] && _1[:status] >= 400) },
        endpoints: build_endpoint_summary,
        scenario_errors: @scenario_errors.map { |e|
          { user_id: e[:user_id], screen: e[:screen]&.to_s, message: e[:message] }
        },
        raw_metrics: @metrics.map { |m|
          {
            method: m[:method].to_s,
            path: m[:path],
            status: m[:status],
            latency_ms: m[:latency_ms],
            error: m[:error],
            screen: m[:screen]&.to_s,
            time: m[:time]&.iso8601
          }
        }
      }

      File.write(filename, JSON.pretty_generate(data))
      puts "Results saved to: #{filename}"
    end

    private

    def percentile(sorted_array, pct)
      return 0 if sorted_array.empty?
      idx = [(sorted_array.size * pct / 100.0).ceil - 1, 0].max
      sorted_array[idx] || 0
    end

    def build_interval_endpoints(interval)
      interval.group_by { |m| "#{m[:method].to_s.upcase.ljust(6)} #{m[:path]}" }
        .sort_by { |k, _| k }
        .map do |key, reqs|
          latencies = reqs.filter_map { _1[:latency_ms] }.sort
          err = reqs.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
          {
            name: key,
            count: reqs.size,
            avg: latencies.empty? ? 0 : (latencies.sum / latencies.size).round(1),
            p95: percentile(latencies, 95).round(1),
            p99: percentile(latencies, 99).round(1),
            errors: err
          }
        end
    end

    def build_cumulative_endpoints
      @metrics.group_by { |m| "#{m[:method].to_s.upcase.ljust(6)} #{m[:path]}" }
        .sort_by { |k, _| k }
        .map do |key, reqs|
          latencies = reqs.filter_map { _1[:latency_ms] }.sort
          err = reqs.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
          {
            name: key,
            count: reqs.size,
            avg: latencies.empty? ? 0 : (latencies.sum / latencies.size).round(1),
            min: latencies.first || 0,
            max: latencies.last || 0,
            p50: percentile(latencies, 50).round(1),
            p95: percentile(latencies, 95).round(1),
            p99: percentile(latencies, 99).round(1),
            errors: err
          }
        end
    end

    def build_endpoint_summary
      @metrics.group_by { |m| "#{m[:method].to_s.upcase} #{m[:path]}" }.map do |key, reqs|
        latencies = reqs.filter_map { _1[:latency_ms] }.sort
        err = reqs.count { _1[:error] || (_1[:status] && _1[:status] >= 400) }
        {
          endpoint: key,
          count: reqs.size,
          errors: err,
          avg_ms: latencies.empty? ? nil : (latencies.sum / latencies.size).round(1),
          min_ms: latencies.first,
          max_ms: latencies.last,
          p50_ms: percentile(latencies, 50),
          p90_ms: percentile(latencies, 90),
          p95_ms: percentile(latencies, 95),
          p99_ms: percentile(latencies, 99)
        }
      end
    end
  end
end
