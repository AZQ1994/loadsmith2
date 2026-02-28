# frozen_string_literal: true

require_relative "test_helper"

class TestAccess < Minitest::Test
  def setup
    @config = Loadsmith::Configuration.new
    @config.base_url = "http://localhost:9999"
  end

  def test_class_level_dsl
    klass = Class.new(Loadsmith::Access) do
      get "/api/items"
      name "/api/items"
      headers({ "X-Custom" => "test" })
    end

    assert_equal :get, klass.http_method
    assert_equal "/api/items", klass.path
    assert_equal "/api/items", klass.metric_name
    assert_equal({ "X-Custom" => "test" }, klass.default_access_headers)
  end

  def test_post_method
    klass = Class.new(Loadsmith::Access) { post "/api/create" }
    assert_equal :post, klass.http_method
    assert_equal "/api/create", klass.path
  end

  def test_put_method
    klass = Class.new(Loadsmith::Access) { put "/api/update" }
    assert_equal :put, klass.http_method
  end

  def test_patch_method
    klass = Class.new(Loadsmith::Access) { patch "/api/patch" }
    assert_equal :patch, klass.http_method
  end

  def test_delete_method
    klass = Class.new(Loadsmith::Access) { delete "/api/remove" }
    assert_equal :delete, klass.http_method
  end

  def test_before_and_after_hooks
    before_called = false
    after_response = nil

    klass = Class.new(Loadsmith::Access) do
      get "/api/test"

      define_method(:before) { before_called = true }
      define_method(:after) { |res| after_response = res }
    end

    ctx = Loadsmith::Context.new(user_id: 1, config: @config)
    # Will fail to connect but that's fine — we're testing hooks
    klass.call(ctx)

    assert before_called
    assert_instance_of Loadsmith::Response, after_response
  end

  def test_request_json_override
    body_sent = nil

    klass = Class.new(Loadsmith::Access) do
      post "/api/test"
      define_method(:request_json) { { key: "value" } }
    end

    ctx = Loadsmith::Context.new(user_id: 1, config: @config)
    res = klass.call(ctx)

    # Connection will fail, but Access should still complete without raising
    assert_instance_of Loadsmith::Response, res
  end

  def test_ctx_accessible
    captured_ctx = nil

    klass = Class.new(Loadsmith::Access) do
      get "/api/test"
      define_method(:before) { captured_ctx = ctx }
    end

    ctx = Loadsmith::Context.new(user_id: 42, config: @config)
    klass.call(ctx)

    assert_equal ctx, captured_ctx
    assert_equal 42, captured_ctx.user_id
  end

  def test_call_creates_new_instance
    klass = Class.new(Loadsmith::Access) { get "/api/test" }
    ctx = Loadsmith::Context.new(user_id: 1, config: @config)

    instance1 = klass.new(ctx)
    instance1.call

    instance2 = klass.new(ctx)
    instance2.call

    refute_same instance1, instance2
  end
end
