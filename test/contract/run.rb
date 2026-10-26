# frozen_string_literal: true

# Contract test against a real Argus (staging or prod), not a stand-in.
#
#   ARGUS_CONTRACT_DSN=<dsn of a test source> rake contract
#
# Sends an error, a log, a span, a metric, a cron check-in and a flag
# evaluation, and checks Argus answered 2xx to each. The cron check-in expects
# a monitor with slug `argus-ruby-contract`; a 404 (no such monitor) is
# reported, not failed. Not part of `rake test`: it needs the network.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "naijacloud/argus"
require "securerandom"
require "uri"

dsn = ENV["ARGUS_CONTRACT_DSN"].to_s
if dsn.empty?
  warn "set ARGUS_CONTRACT_DSN to a test source DSN"
  exit 2
end

statuses = []
lock = Mutex.new
NaijaCloud::Argus.init(
  dsn: dsn,
  release: "argus-ruby@contract",
  environment: "contract",
  service_name: "argus-ruby-contract",
  debug: ENV["ARGUS_DEBUG"] == "1",
)
NaijaCloud::Argus.client.transport.observer = lambda do |res|
  lock.synchronize { statuses << { lane: res.lane, path: URI(res.url).path, status: res.status } }
end

marker = "argus-ruby contract #{SecureRandom.hex(4)}"
NaijaCloud::Argus.trace("contract.run", "contract.marker" => marker) do
  begin
    begin
      JSON.parse("{not json")
    rescue JSON::ParserError
      raise marker
    end
  rescue RuntimeError => e
    NaijaCloud::Argus.capture_exception(e, extra: { password: "hunter2" }, tags: { contract: "ruby" })
  end
  NaijaCloud::Argus.log.info("contract log line", marker: marker)
end
NaijaCloud::Argus.metrics.count("argus_ruby_contract_runs", 1)
NaijaCloud::Argus.cron.check_in("argus-ruby-contract", :ok)
flag = NaijaCloud::Argus.flags.on?("argus-ruby-contract-flag", "contract-user", false)
flushed = NaijaCloud::Argus.close(15)

failures = []
by = ->(lane) { statuses.select { |s| s[:lane] == lane }.map { |s| s[:status] } }
{ "errors" => "/api/", "logs" => "/v1/logs", "traces" => "/v1/traces", "metrics" => "/v1/metrics" }.each do |lane, path|
  got = by.call(lane)
  if !got.empty? && got.all? { |s| s >= 200 && s < 300 }
    puts "ok   #{path} #{got.join(',')}"
  else
    puts "FAIL #{path} #{got.inspect}"
    failures << path
  end
end
cron = by.call("crons")
if !cron.empty? && cron.all? { |s| s >= 200 && s < 300 }
  puts "ok   /v1/cron/ #{cron.join(',')}"
elsif cron.include?(404)
  puts "note /v1/cron/ 404 (create a cron monitor with slug argus-ruby-contract to check this)"
else
  puts "FAIL /v1/cron/ #{cron.inspect}"
  failures << "/v1/cron/"
end
fl = by.call("flags")
if !fl.empty? && fl.all? { |s| s >= 200 && s < 300 }
  puts "ok   /v1/flags/evaluate #{fl.join(',')} (argus-ruby-contract-flag = #{flag})"
else
  puts "FAIL /v1/flags/evaluate #{fl.inspect}"
  failures << "/v1/flags/evaluate"
end
failures << "flush timed out" unless flushed
puts "marker: #{marker}"

if failures.empty?
  puts "contract passed"
else
  puts "contract FAILED: #{failures.join(', ')}"
  exit 1
end
