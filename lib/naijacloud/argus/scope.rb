# frozen_string_literal: true

module NaijaCloud
  module Argus
    # User, tags, contexts and breadcrumbs that are attached to the next event.
    #
    # There is one global scope, plus one per request or job: the Rack
    # middleware and the ActiveJob hook open a scope around each unit of work,
    # so `set_user` in one Puma thread never labels another thread's error.
    # Outside a request, writes go to the global scope.
    class Scope
      attr_reader :tags, :contexts, :breadcrumbs
      attr_accessor :user, :transaction, :request

      def initialize(max_breadcrumbs = 100)
        @max_breadcrumbs = max_breadcrumbs
        @tags = {}
        @contexts = {}
        @breadcrumbs = []
        @user = nil
        @transaction = nil
        @request = nil
        @mutex = Mutex.new
      end

      def set_tag(key, value)
        @mutex.synchronize { @tags[key.to_s] = value.to_s }
      end

      def set_context(name, ctx)
        @mutex.synchronize { ctx.nil? ? @contexts.delete(name.to_s) : @contexts[name.to_s] = ctx }
      end

      def add_breadcrumb(crumb)
        @mutex.synchronize do
          @breadcrumbs << crumb
          @breadcrumbs.shift(@breadcrumbs.length - @max_breadcrumbs) if @breadcrumbs.length > @max_breadcrumbs
        end
      end

      # `transaction` may be a callable: the Rack middleware only learns the
      # route after the router has run, which is after an error raised inside
      # the app may already have been reported.
      def snapshot
        @mutex.synchronize do
          t = @transaction
          t = (t.call rescue nil) if t.respond_to?(:call) # rubocop:disable Style/RescueModifier
          { user: @user, tags: @tags.dup, contexts: @contexts.dup, breadcrumbs: @breadcrumbs.dup,
            transaction: t, request: @request }
        end
      end

      def self.current
        Thread.current[:naijacloud_argus_scope]
      end

      def self.with(scope)
        prev = Thread.current[:naijacloud_argus_scope]
        Thread.current[:naijacloud_argus_scope] = scope
        yield scope
      ensure
        Thread.current[:naijacloud_argus_scope] = prev
      end
    end
  end
end
