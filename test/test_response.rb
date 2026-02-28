# frozen_string_literal: true

require_relative "test_helper"

class TestResponse < Minitest::Test
  def test_ok_with_http_response
    http_res = mock_http_response(200, '{"key":"value"}')
    res = Loadsmith::Response.new(http_res)

    assert res.ok?
    assert res.success?
    assert_equal 200, res.status
    assert_equal '{"key":"value"}', res.body
    assert_nil res.error
  end

  def test_success_only_for_2xx
    res_200 = Loadsmith::Response.new(mock_http_response(200, "{}"))
    res_201 = Loadsmith::Response.new(mock_http_response(201, "{}"))
    res_404 = Loadsmith::Response.new(mock_http_response(404, "{}"))
    res_500 = Loadsmith::Response.new(mock_http_response(500, "{}"))

    assert res_200.success?
    assert res_201.success?
    refute res_404.success?
    refute res_500.success?
  end

  def test_network_error
    res = Loadsmith::Response.new(nil, error: "Net::ReadTimeout")

    refute res.ok?
    refute res.success?
    assert_nil res.status
    assert_nil res.body
    assert_equal "Net::ReadTimeout", res.error
  end

  def test_json_parsing
    http_res = mock_http_response(200, '{"cards":[1,2,3]}')
    res = Loadsmith::Response.new(http_res)

    assert_equal({ "cards" => [1, 2, 3] }, res.json)
    assert_equal [1, 2, 3], res["cards"]
  end

  def test_json_memoized
    http_res = mock_http_response(200, '{"a":1}')
    res = Loadsmith::Response.new(http_res)

    assert_same res.json, res.json
  end

  def test_json_returns_empty_hash_on_parse_error
    http_res = mock_http_response(200, "not json")
    res = Loadsmith::Response.new(http_res)

    assert_equal({}, res.json)
  end

  def test_json_returns_empty_hash_on_nil_body
    res = Loadsmith::Response.new(nil, error: "Errno::ECONNREFUSED")

    assert_equal({}, res.json)
    assert_nil res["anything"]
  end

  private

  def mock_http_response(code, body)
    obj = Object.new
    obj.define_singleton_method(:code) { code.to_s }
    obj.define_singleton_method(:body) { body }
    obj
  end
end
