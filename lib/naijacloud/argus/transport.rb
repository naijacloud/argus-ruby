# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module NaijaCloud
  module Argus
    # Sending (spec §6). One bounded queue and one background thread per
    # endpoint ("lane"), so a slow traces endpoint never holds up errors, and
    # nothing here ever runs on, blocks, or raises into the app's own threads.
    #
    # - network errors and 5xx: back off 1 s, 2 s, 4 s … (cap 60 s), 5 tries;
    # - 429: wait Retry-After (or X-Sentry-Rate-Limits), retry without
    #   counting a try, and send nothing else on that lane meanwhile;
    # - 401/403: the key was refused; the lane stops until the process restarts;
    # - any other status: dropped, never retried. That includes 3xx: a
    #   followed redirect would resend the key to a host the response chose.
    class Transport
      MAX_ITEMS = 100
      MAX_BYTES = 1 << 20
      MAX_TRIES = 5
      MAX_BACKOFF = 60
      MAX_RATE_LIMIT = 3600

      Request = Struct.new(:url, :body, :headers) do
        def bytesize
          body.bytesize
        end
      end

      # A response as the transport saw it; handed to `observer` (contract
      # tests) and nothing else.
      Response = Struct.new(:lane, :url, :status, :headers)

      class Lane
        attr_accessor :queue, :bytes, :dead, :blocked_until, :busy, :thread, :cv

        def initialize
          @queue = []
          @bytes = 0
          @dead = false
          @blocked_until = 0.0
          @busy = false
          @cv = ConditionVariable.new
        end
      end

      # Test hooks. `sleeper` replaces waiting (it is handed the seconds that
      # would have been slept); `observer` sees every response.
      attr_writer :sleeper
      attr_accessor :observer
      # The per-lane byte bound (spec §6: 1 MB). Settable for tests only.
      attr_accessor :max_bytes

      def initialize(debug: nil, open_timeout: 5, read_timeout: 10)
        @debug = debug
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @sleeper = nil
        @observer = nil
        @max_bytes = MAX_BYTES
        @dropped_series_logged = false
        reset!
      end

      # Queues a request on a lane. Returns false when it was not accepted.
      def enqueue(lane_name, request)
        after_fork_reset if @pid != Process.pid
        @mutex.synchronize do
          return false if @closed

          lane = (@lanes[lane_name] ||= Lane.new)
          return false if lane.dead

          lane.queue << request
          lane.bytes += request.bytesize
          # Drop the oldest, not the newest: the newest describes the state
          # the app is in now, which is what someone looking at it wants.
          while lane.queue.length > MAX_ITEMS || (lane.bytes > @max_bytes && lane.queue.length > 1)
            lane.bytes -= lane.queue.shift.bytesize
          end
          if lane.bytes > @max_bytes
            lane.queue.clear
            lane.bytes = 0
            log("#{lane_name}: a single request over #{@max_bytes} bytes, dropped")
            return false
          end
          start_worker(lane_name, lane)
          lane.cv.signal
        end
        true
      rescue StandardError => e
        log("#{lane_name}: could not queue (#{e.class}: #{e.message})")
        false
      end

      # Waits until every lane is empty and idle, or timeout seconds pass.
      # True when everything went out.
      def flush(timeout = 2.0)
        deadline = monotonic + timeout.to_f
        @mutex.synchronize do
          until idle?
            remaining = deadline - monotonic
            return false if remaining <= 0

            @idle.wait(@mutex, remaining)
          end
        end
        true
      rescue StandardError
        false
      end

      # Stops the workers. Anything still queued is dropped.
      def close
        threads = @mutex.synchronize do
          @closed = true
          @lanes.each_value { |l| l.cv.broadcast }
          @wake.broadcast
          @lanes.values.map(&:thread).compact
        end
        threads.each { |t| t.join(0.5) }
        nil
      rescue StandardError
        nil
      end

      def dead?(lane_name)
        @mutex.synchronize { (l = @lanes[lane_name]) ? l.dead : false }
      end

      # For the flags endpoint, which answers synchronously but must obey the
      # same 401/429 rules as the queued lanes.
      def mark_dead(lane_name)
        @mutex.synchronize { (@lanes[lane_name] ||= Lane.new).dead = true }
      end

      def block(lane_name, seconds)
        @mutex.synchronize { (@lanes[lane_name] ||= Lane.new).blocked_until = monotonic + seconds }
      end

      def blocked?(lane_name)
        @mutex.synchronize { (l = @lanes[lane_name]) ? monotonic < l.blocked_until : false }
      end

      # One synchronous POST, outside the queues. Returns a Net::HTTPResponse
      # or raises; callers rescue.
      def post(url, body, headers, read_timeout: @read_timeout, open_timeout: @open_timeout)
        uri = URI.parse(url)
        req = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| req[k] = v }
        req["User-Agent"] = "#{SDK_NAME}/#{VERSION}"
        req.body = body
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        # Explicit, not inherited from whatever else in the process has
        # touched OpenSSL's defaults.
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.write_timeout = read_timeout if http.respond_to?(:write_timeout=)
        Transport.internal { http.start { |conn| conn.request(req) } }
      end

      # Marks the current thread as SDK-internal so the Net::HTTP integration
      # does not trace, or add breadcrumbs for, Argus's own requests.
      def self.internal
        prev = Thread.current[:naijacloud_argus_internal]
        Thread.current[:naijacloud_argus_internal] = true
        yield
      ensure
        Thread.current[:naijacloud_argus_internal] = prev
      end

      def self.internal?
        Thread.current[:naijacloud_argus_internal] == true
      end

      # Reads Retry-After, then X-Sentry-Rate-Limits; at least 1 s, at most 1 h.
      def self.retry_after(headers)
        ra = Float(headers["retry-after"].to_s, exception: false)
        seconds = ra && ra.positive? ? ra : nil
        unless seconds
          first = Float(headers["x-sentry-rate-limits"].to_s.split(":").first.to_s, exception: false)
          seconds = first && first.positive? ? first : 60
        end
        seconds.clamp(1, MAX_RATE_LIMIT)
      end

      def inspect
        "#<NaijaCloud::Argus::Transport>"
      end

      private

      def reset!
        @pid = Process.pid
        @mutex = Mutex.new
        @idle = ConditionVariable.new
        @wake = ConditionVariable.new
        @lanes = {}
        @closed = false
      end

      # Puma, Unicorn and Resque fork after the app has loaded. The parent's
      # worker threads do not exist in the child, and its queue belongs to the
      # parent, so the child starts empty.
      def after_fork_reset
        reset!
      end

      def idle?
        @lanes.each_value.all? { |l| (l.queue.empty? || l.dead) && !l.busy }
      end

      def start_worker(name, lane)
        return if lane.thread&.alive?

        lane.thread = Thread.new { work(name, lane) }
        lane.thread.name = "argus-#{name}" if lane.thread.respond_to?(:name=)
        lane.thread.report_on_exception = false
      end

      def work(name, lane)
        Thread.current[:naijacloud_argus_internal] = true
        loop do
          req = @mutex.synchronize do
            lane.cv.wait(@mutex) while lane.queue.empty? && !@closed && !lane.dead
            if @closed || lane.dead
              @idle.broadcast
              return
            end
            lane.busy = true
            r = lane.queue.shift
            lane.bytes -= r.bytesize
            r
          end
          begin
            deliver(name, lane, req)
          rescue StandardError => e
            log("#{name}: #{e.class}: #{e.message}")
          ensure
            @mutex.synchronize do
              lane.busy = false
              @idle.broadcast
            end
          end
        end
      end

      def deliver(name, lane, req)
        tries = 0
        wait = @mutex.synchronize { lane.blocked_until - monotonic }
        pause(wait) if wait.positive?
        loop do
          return if closed?

          res = begin
            post(req.url, req.body, req.headers)
          rescue StandardError => e
            log("#{name}: network error (#{e.class}: #{e.message}), try #{tries + 1}")
            nil
          end
          observe(name, req, res)
          code = res ? res.code.to_i : 0

          if res && code >= 200 && code < 300
            note_dropped_series(res)
            return
          end

          if code == 429
            seconds = Transport.retry_after(res)
            @mutex.synchronize { lane.blocked_until = monotonic + seconds }
            log("#{name}: 429, waiting #{seconds} s")
            pause(seconds)
            next
          end

          if [401, 403].include?(code)
            log("#{name}: #{code}, the key was refused; stopping this endpoint until restart")
            @mutex.synchronize do
              lane.dead = true
              lane.queue.clear
              lane.bytes = 0
            end
            return
          end

          if res && code < 500
            log("#{name}: #{code}, dropped")
            return
          end

          tries += 1
          if tries >= MAX_TRIES
            log("#{name}: giving up after #{tries} tries")
            return
          end
          log("#{name}: #{code}, try #{tries}") if res
          pause([MAX_BACKOFF, 2**(tries - 1)].min)
        end
      end

      def observe(name, req, res)
        return unless @observer

        headers = {}
        res&.each_header { |k, v| headers[k] = v }
        @observer.call(Response.new(name, req.url, res ? res.code.to_i : 0, headers))
      rescue StandardError
        nil
      end

      def note_dropped_series(res)
        return if @dropped_series_logged || res["x-argus-dropped-series"].nil?

        @dropped_series_logged = true
        log("the workspace hit its metric series limit; new series are being dropped (X-Argus-Dropped-Series: #{res['x-argus-dropped-series']})")
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      # Waits on a condition variable rather than Kernel#sleep so close can
      # wake a worker that is backing off.
      def pause(seconds)
        return @sleeper.call(seconds) if @sleeper

        deadline = monotonic + seconds
        @mutex.synchronize do
          until @closed
            remaining = deadline - monotonic
            break if remaining <= 0

            @wake.wait(@mutex, remaining)
          end
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def log(msg)
        @debug&.call(msg)
      end
    end
  end
end
