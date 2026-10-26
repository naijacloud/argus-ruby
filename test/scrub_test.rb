# frozen_string_literal: true

require_relative "test_helper"

class ScrubTest < Minitest::Test
  S = NaijaCloud::Argus::Scrub
  F = "[Filtered]"

  def test_sensitive_keys_by_containment
    %w[password user_password PassWD client-secret access_token X-Api-Key AccessKeyId
       Authorization credentials cookie private_key card_number creditCard bvn cvv cvc
       session_id sessionToken signature].each do |k|
      assert S.sensitive_key?(k), k
    end
  end

  def test_sensitive_keys_by_equality
    %w[auth pwd PIN otp session card sid].each { |k| assert S.sensitive_key?(k), k }
    %w[author pinned cardinal sidebar email name id].each { |k| refute S.sensitive_key?(k), k }
  end

  def test_scrubs_nested_values
    out = S.scrub({ user: { password: "hunter2", name: "Ada" }, list: [{ "token" => "t" }], ok: 1, "pin" => "" })
    assert_equal({ "user" => { "password" => F, "name" => "Ada" }, "list" => [{ "token" => F }], "ok" => 1, "pin" => "" }, out)
  end

  def test_card_numbers_that_pass_luhn
    assert_equal "card #{F} ok", S.scrub_string("card 4111 1111 1111 1111 ok")
    assert_equal "id 4111111111111112", S.scrub_string("id 4111111111111112") # fails Luhn
    assert_equal "short 123456789012", S.scrub_string("short 123456789012")
  end

  def test_credentials_inside_strings
    assert_equal "Authorization: Bearer #{F}", S.scrub_string("Authorization: Bearer abcdefgh12345")
    assert_equal "Basic #{F}", S.scrub_string("Basic dXNlcjpwYXNzd29yZA==")
    assert_equal "token #{F}", S.scrub_string("token abcdefghijk")
  end

  def test_jwts
    # A made-up token, joined here so secret scanners don't flag the fixture.
    jwt = %w[eyJhbGciOiJIUzI1NiJ9 eyJzdWIiOiIxMjM0NSJ9 c2lnbmF0dXJlLXZhbHVl].join(".")
    assert_equal "got #{F}", S.scrub_string("got #{jwt}")
  end

  def test_sensitive_key_value_pairs
    assert_equal "password=#{F}&user=ada", S.scrub_string("password=hunter2&user=ada")
    assert_equal %(api_key: "#{F}"), S.scrub_string(%(api_key: "sk_live_x"))
  end

  def test_cycles_and_depth_are_cut
    a = { "name" => "a" }
    a["self"] = a
    assert_equal "[…]", S.scrub(a)["self"]
    deep = (1..12).reduce("leaf") { |acc, _| { "n" => acc } }
    assert_includes JSON.generate(S.scrub(deep)), "[…]"
  end

  def test_odd_values_become_strings
    out = S.scrub({ "sym" => :x, "obj" => Object.new, "inf" => Float::INFINITY, "nil" => nil })
    assert_equal "x", out["sym"]
    assert_match(/Object/, out["obj"])
    assert_equal "Infinity", out["inf"]
    assert_nil out["nil"]
  end

  def test_invalid_utf8_does_not_raise
    assert S.scrub_string((+"bad \xff bytes").force_encoding("BINARY")).valid_encoding?
  end

  def test_strip_query
    assert_equal "https://x.ng/a", S.strip_query("https://x.ng/a?token=1#frag")
    assert_equal "/p", S.strip_query("/p#x")
  end
end
