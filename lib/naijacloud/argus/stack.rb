# frozen_string_literal: true

require "rbconfig"

module NaijaCloud
  module Argus
    # Turns a Ruby backtrace into Sentry frames, oldest first (spec §4).
    class Stack
      # "path:12:in `meth'" (Ruby < 3.4) and "path:12:in 'Klass#meth'" (3.4+).
      LINE = /\A(.+?):(\d+)(?::in [`'](.*)')?\z/.freeze
      CONTEXT_LINES = 5
      MAX_FRAMES = 250
      MAX_FILE_BYTES = 1 << 20
      CACHE_SIZE = 64

      def initialize(project_root: nil, context_lines: true)
        @root = project_root && File.expand_path(project_root.to_s)
        @context_lines = context_lines
        @cache = {}
        @mutex = Mutex.new
        @library_paths = library_paths
      end

      attr_reader :root

      def frames(exception)
        lines = exception.backtrace
        return [] if lines.nil? || lines.empty?

        lines.first(MAX_FRAMES).reverse.filter_map { |line| frame(line) }
      end

      private

      def frame(line)
        m = LINE.match(line.to_s)
        return nil unless m

        abs = m[1]
        lineno = m[2].to_i
        fn = m[3]
        f = { abs_path: abs, filename: relative(abs), lineno: lineno, in_app: in_app?(abs) }
        f[:function] = fn.sub(/\A(?:block|rescue|ensure)(?: \(\d+ levels\))? in /, "") if fn && !fn.empty?
        add_context(f, abs, lineno) if @context_lines && f[:in_app]
        f
      end

      def relative(abs)
        return abs.delete_prefix("#{@root}/") if @root && abs.start_with?("#{@root}/")

        gem_path = abs[%r{/gems/([^/]+/.+)\z}, 1]
        gem_path || abs
      end

      def in_app?(abs)
        return false if abs.start_with?("<internal:", "<main>") || abs.include?("/gems/") || abs.include?("/vendor/bundle/")
        return false if @library_paths.any? { |p| abs.start_with?(p) }
        return abs.start_with?("#{@root}/") if @root

        true
      end

      def library_paths
        paths = [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["rubyarchdir"]]
        paths.concat(Gem.path) if defined?(Gem)
        paths.compact.map { |p| File.expand_path(p) }.uniq
      rescue StandardError
        []
      end

      def add_context(frame, path, lineno)
        src = source(path)
        return unless src && lineno.positive? && lineno <= src.length

        i = lineno - 1
        frame[:pre_context] = src[[0, i - CONTEXT_LINES].max...i]
        frame[:context_line] = src[i]
        frame[:post_context] = src[(i + 1)..(i + CONTEXT_LINES)] || []
      end

      # Source files are read once, capped in size, and the cache is bounded,
      # so a deep stack in a hot error path costs a hash lookup, not disk I/O.
      def source(path)
        @mutex.synchronize do
          return @cache[path] if @cache.key?(path)

          @cache.shift if @cache.size >= CACHE_SIZE
          @cache[path] = read_source(path)
        end
      end

      def read_source(path)
        return nil unless File.file?(path) && File.size(path) <= MAX_FILE_BYTES

        File.readlines(path, chomp: true).map { |l| l.length > 500 ? "#{l[0, 500]}…" : l }
      rescue StandardError
        nil
      end
    end
  end
end
