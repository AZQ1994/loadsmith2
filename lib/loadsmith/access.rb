# frozen_string_literal: true

module Loadsmith
  # Base class for API access definitions.
  # Each subclass = one API endpoint. Each instance = one request.
  #
  #   class CardList < Loadsmith::Access
  #     get "/api/cards"
  #
  #     def after(res)
  #       ctx.store[:cards] = res["cards"] if res.success?
  #     end
  #   end
  #
  #   # In a screen block:
  #   CardList.call(ctx)
  #
  class Access
    # --- Class-level DSL ---

    class << self
      attr_reader :http_method, :path, :metric_name, :default_access_headers

      def get(path)    = set_method(:get, path)
      def post(path)   = set_method(:post, path)
      def put(path)    = set_method(:put, path)
      def patch(path)  = set_method(:patch, path)
      def delete(path) = set_method(:delete, path)

      def name(n)
        @metric_name = n
      end

      def headers(h)
        @default_access_headers = h
      end

      # Convenience: create instance and call
      def call(ctx, **opts)
        new(ctx).call(**opts)
      end

      private

      def set_method(method, path)
        @http_method = method
        @path = path
      end
    end

    # --- Instance ---

    attr_reader :ctx, :response

    def initialize(ctx)
      @ctx = ctx
    end

    def call(**opts)
      before

      method = self.class.http_method
      path = build_path

      extra_headers = (self.class.default_access_headers || {}).merge(request_headers)
      json_body = request_json
      raw_body = request_body
      params = request_params

      @response = ctx.public_send(
        method, path,
        headers: extra_headers,
        **(method == :get ? { params: params } : {}),
        **(json_body ? { json: json_body } : {}),
        **(raw_body && !json_body ? { body: raw_body } : {}),
        name: self.class.metric_name
      )

      after(@response)
      @response
    end

    # --- Override points ---

    # Called before the request. Use to prepare state.
    def before; end

    # Called after the request with the Response object.
    def after(response); end

    # Override to change the request path dynamically.
    def build_path
      self.class.path
    end

    # Override to add per-request headers.
    def request_headers
      {}
    end

    # Override to set query parameters (for GET requests).
    def request_params
      {}
    end

    # Override to set JSON request body.
    def request_json
      nil
    end

    # Override to set raw request body (ignored if request_json is set).
    def request_body
      nil
    end
  end
end
