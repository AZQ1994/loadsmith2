# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Loadsmith
  # Per-user execution context. Holds HTTP client, headers, store, and metrics.
  class Context
    attr_reader :user_id, :store, :metrics, :errors
    attr_accessor :current_screen, :default_headers

    def initialize(user_id:, config:)
      @user_id = user_id
      @config = config
      @base_uri = URI.parse(config.base_url)
      @store = {}
      @default_headers = { "Content-Type" => "application/json" }
      @metrics = []
      @errors = []
      @aborted = false
      @http = nil
    end

    def aborted?
      @aborted
    end

    def abort!
      @aborted = true
    end

    # --- HTTP Methods ---

    # name: optional label for metrics grouping (e.g., "/api/cards/:id")
    # Without name, the actual path is used as the metrics key.
    def get(path, headers: {}, params: {}, name: nil)
      request(:get, path, headers: headers, params: params, name: name)
    end

    def post(path, headers: {}, body: nil, json: nil, name: nil)
      request(:post, path, headers: headers, body: body, json: json, name: name)
    end

    def put(path, headers: {}, body: nil, json: nil, name: nil)
      request(:put, path, headers: headers, body: body, json: json, name: name)
    end

    def patch(path, headers: {}, body: nil, json: nil, name: nil)
      request(:patch, path, headers: headers, body: body, json: json, name: name)
    end

    def delete(path, headers: {}, name: nil)
      request(:delete, path, headers: headers, name: name)
    end

    def record_scenario_error(screen, message)
      @errors << { screen: screen, message: message, time: Time.now }
    end

    def close
      @http&.finish if @http&.started?
    rescue IOError
      # ignore
    ensure
      @http = nil
    end

    private

    def http_client
      return @http if @http&.started?

      @http = Net::HTTP.new(@base_uri.host, @base_uri.port)
      @http.use_ssl = (@base_uri.scheme == "https")
      @http.open_timeout = @config.open_timeout
      @http.read_timeout = @config.read_timeout
      @http.start
      @http
    end

    def request(method, path, headers: {}, params: {}, body: nil, json: nil, name: nil)
      uri = build_uri(path, params)
      req = build_request(method, uri, headers)

      if json
        req.body = json.is_a?(String) ? json : JSON.generate(json)
      elsif body
        req.body = body
      end

      metric_path = name || path
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw_response = http_client.request(req)
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

      record_metric(method, metric_path, raw_response.code.to_i, latency_ms, nil)
      Response.new(raw_response)
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
           Errno::ECONNRESET, SocketError, EOFError => e
      latency_ms = if start_time
                     ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)
                   end
      record_metric(method, metric_path || path, nil, latency_ms, e.class.name)
      @http = nil # Reset connection on error
      Response.new(nil, error: e.class.name)
    end

    def build_uri(path, params)
      uri = URI.join(@base_uri, path)
      uri.query = URI.encode_www_form(params) unless params.empty?
      uri
    end

    def build_request(method, uri, extra_headers)
      klass = case method
              when :get    then Net::HTTP::Get
              when :post   then Net::HTTP::Post
              when :put    then Net::HTTP::Put
              when :patch  then Net::HTTP::Patch
              when :delete then Net::HTTP::Delete
              else raise ArgumentError, "Unsupported HTTP method: #{method}"
              end
      req = klass.new(uri)
      default_headers.merge(extra_headers).each { |k, v| req[k] = v }
      req
    end

    def record_metric(method, path, status, latency_ms, error)
      @metrics << {
        method: method,
        path: path,
        status: status,
        latency_ms: latency_ms,
        error: error,
        screen: @current_screen,
        time: Time.now
      }
    end
  end
end
