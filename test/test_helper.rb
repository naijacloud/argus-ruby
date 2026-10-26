# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "json"
require "zlib"
require "stringio"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "naijacloud/argus"

# A test key with a run of zeros: it is not, and never was, a real key.
TEST_KEY = "a0000000000000000000000000000000"

# A minimal HTTP/1.1 server on a real socket, on 127.0.0.1 with an ephemeral
# port. Raw TCPServer rather than webrick: webrick left the standard library
# in Ruby 3.0, and the suite must run offline on a fresh checkout. The suite
# makes no outbound connection of any kind.
class MockServer
  STATUS_TEXT = {
    200 => "OK", 202 => "Accepted", 301 => "Moved Permanently", 400 => "Bad Request",
    401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 413 => "Payload Too Large",
    429 => "Too Many Requests", 500 => "Internal Server Error", 502 => "Bad Gateway",
    503 => "Service Unavailable"
  }.freeze

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @queue = []
    @requests = []
    @mutex = Mutex.new
    @cv = ConditionVariable.new
    @running = true
    @threads = []
    @acceptor = Thread.new { accept_loop }
  end

  def port
    @server.addr[1]
  end

  def dsn(project = 7)
    "http://#{TEST_KEY}@127.0.0.1:#{port}/#{project}"
  end

  # Script one response. Unscripted requests get 200 with an empty JSON body.
  def enqueue(status: 200, body: "{}", headers: {}, hang: nil)
    body = JSON.generate(body) unless body.is_a?(String)
    @mutex.synchronize { @queue << { status: status, body: body, headers: headers, hang: hang } }
    self
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def requests_to(prefix)
    requests.select { |r| r[:path].start_with?(prefix) }
  end

  # Waits until at least n requests (optionally to a path prefix) arrived.
  def wait_for(n, prefix = "", timeout: 5)
    deadline = Time.now + timeout
    @mutex.synchronize do
      until @requests.count { |r| r[:path].start_with?(prefix) } >= n
        remaining = deadline - Time.now
        break if remaining <= 0

        @cv.wait(@mutex, remaining)
      end
    end
    requests_to(prefix)
  end

  def shutdown
    @running = false
    begin
      @server.close
    rescue IOError, Errno::EBADF
      nil
    end
    @acceptor.join(2)
    @threads.each { |t| t.join(2) }
  end

  private

  def accept_loop
    while @running
      begin
        socket = @server.accept
      rescue IOError, Errno::EBADF, Errno::EINVAL
        break
      end
      @threads << Thread.new(socket) { |sock| handle(sock) }
    end
  end

  def handle(socket)
    request = read_request(socket)
    return if request.nil?

    response = @mutex.synchronize do
      @requests << request
      @cv.broadcast
      @queue.shift
    end || { status: 200, body: "{}", headers: {} }
    sleep(response[:hang]) if response[:hang]
    write_response(socket, response)
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  ensure
    begin
      socket.close
    rescue IOError
      nil
    end
  end

  def read_request(socket)
    line = socket.gets
    return nil if line.nil?

    method, path, = line.split(" ")
    headers = {}
    while (l = socket.gets)
      l = l.chomp
      break if l.empty?

      name, value = l.split(":", 2)
      headers[name.to_s.downcase.strip] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    raw = length.positive? ? socket.read(length) : ""
    body = headers["content-encoding"] == "gzip" ? Zlib::GzipReader.new(StringIO.new(raw)).read : raw
    { method: method, path: path, headers: headers, body: body, raw: raw }
  end

  def write_response(socket, response)
    body = response[:body].to_s
    lines = ["HTTP/1.1 #{response[:status]} #{STATUS_TEXT.fetch(response[:status], 'Status')}"]
    response[:headers].each { |k, v| lines << "#{k}: #{v}" }
    lines << "Content-Type: application/json"
    lines << "Content-Length: #{body.bytesize}"
    lines << "Connection: close"
    socket.write(lines.join("\r\n") + "\r\n\r\n")
    socket.write(body)
  end
end

# Base class: a server per test, and no ambient ARGUS_*/SENTRY_* environment,
# which would otherwise change what these tests exercise.
class ArgusTest < Minitest::Test
  ENV_KEYS = %w[
    ARGUS_DSN SENTRY_DSN ARGUS_RELEASE SENTRY_RELEASE ARGUS_ENVIRONMENT SENTRY_ENVIRONMENT
    ARGUS_SERVICE_NAME OTEL_SERVICE_NAME ARGUS_DEBUG
  ].freeze

  def setup
    @saved_env = ENV_KEYS.each_with_object({}) { |k, acc| acc[k] = ENV[k] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    @server = MockServer.new
    @clients = []
  end

  def teardown
    NaijaCloud::Argus.close(0.5)
    @clients.each { |c| c.close(0.5) }
    @server&.shutdown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # A client of its own (not the module-level one), pointed at the server.
  def build_client(**options)
    config = NaijaCloud::Argus::Configuration.new(**{ dsn: @server.dsn, net_http: false }.merge(options))
    config.resolve!
    client = NaijaCloud::Argus::Client.new(config)
    @clients << client
    client
  end

  # Initializes the module-level client against the server.
  def init_argus(**options, &block)
    NaijaCloud::Argus.init(**{ dsn: @server.dsn }.merge(options), &block)
  end

  # Replaces the transport's waits so backoff is asserted, not waited out.
  def capture_sleeps(client)
    slept = []
    client.transport.sleeper = ->(s) { slept << s }
    slept
  end

  # The envelope's three lines, parsed.
  def envelope(request)
    request[:body].split("\n").map { |l| JSON.parse(l) }
  end

  def event_from(request)
    envelope(request)[2]
  end

  def json(request)
    JSON.parse(request[:body])
  end

  def otlp_attrs(list)
    list.each_with_object({}) { |kv, h| h[kv["key"]] = kv["value"].values.first }
  end

  def closed_port
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    port
  end

  def raise_and_rescue(error)
    raise error
  rescue StandardError => e
    e
  end
end
