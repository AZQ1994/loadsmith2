# frozen_string_literal: true

module Loadsmith
  # Wraps Net::HTTP::HTTPResponse (or nil on network error) with convenience methods.
  # Always returned from Context#get, #post, etc. — eliminates nil checks.
  class Response
    attr_reader :error

    def initialize(http_response = nil, error: nil)
      @http_response = http_response
      @error = error
    end

    # Network-level success (got an HTTP response at all)?
    def ok?
      !@http_response.nil?
    end

    # HTTP-level success (2xx)?
    def success?
      ok? && status.between?(200, 299)
    end

    def status
      @http_response&.code&.to_i
    end

    def body
      @http_response&.body
    end

    # Auto-parse JSON body. Memoized. Returns {} on nil/parse error.
    def json
      return @json if defined?(@json)

      @json = if @http_response&.body
                JSON.parse(@http_response.body)
              else
                {}
              end
    rescue JSON::ParserError
      @json = {}
    end

    # Shortcut: response["token"] == response.json["token"]
    def [](key)
      json[key]
    end
  end
end
