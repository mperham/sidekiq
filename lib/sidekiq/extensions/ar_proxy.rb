# frozen_string_literal: true
require 'yaml'

module Sidekiq
  module Extensions

    class ArProxy < BasicObject
      def initialize(performable, target, options={})
        @performable = performable
        @target = target
        @opts = options
      end

      def method_missing(name, *args)
        # Sidekiq has a limitation in that its message must be JSON.
        # JSON can't round trip real Ruby objects so we use YAML to
        # serialize the objects to a String.  The YAML will be converted
        # to JSON and then deserialized on the other side back into a
        # Ruby object.
        obj = [[@target.class, @target.id], name, args]
        marshalled = ::YAML.dump(obj)
        @performable.client_push({ 'class' => @performable, 'args' => [marshalled] }.merge(@opts))
      end
    end

  end
end
