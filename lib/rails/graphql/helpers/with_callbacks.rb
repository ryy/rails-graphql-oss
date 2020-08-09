# frozen_string_literal: true

module Rails # :nodoc:
  module GraphQL # :nodoc:
    module Helpers # :nodoc:
      # Callbacks is an extension of the events which works with the
      # {Callback}[rdoc-ref:Rails::GraphQL::Callback] class, then having extra
      # powers when actually executing the event against procs or owner-based
      # symbolic methods
      module WithCallbacks
        DEFAULT_EVENT_TYPES = %i[query mutation subscription request attach
          organize prepare finalize]

        def self.extended(other)
          other.extend(WithCallbacks::Setup)
        end

        def self.included(other)
          other.extend(WithCallbacks::Setup)
          other.define_method(:event_filters) { self.class.event_filters }
        end

        # Add the ability to set up filters before the actual execution of the
        # callback
        module Setup
          # Use the default list of event types when it's not set
          def event_types(*)
            super.presence || DEFAULT_EVENT_TYPES
          end

          # Return the list of event filters hooks
          def event_filters
            @event_filters ||= {}
          end

          protected

            # Auxiliar method that creates easy-accessible callback assignment
            def expose_events!
              event_types&.each do |event_name|
                define_method(event_name) do |*args, **xargs, &block|
                  on(event_name, *args, **xargs, &block)
                end
              end
            end

            # Attach a new key based event filter
            def event_filter(key, sanitizer = nil, &block)
              event_filters[key.to_sym] = { block: block, sanitizer: sanitizer }
            end
        end

        # Enhance the event by evolving the block to a
        # {Callback}[rdoc-ref:Rails::GraphQL::Callback] object.
        def on(event_name, *args, unshift: false, **xargs, &block)
          block = Callback.new(self, event_name, *args, **xargs, &block)
          super(event_name, unshift: unshift, &block)
        end

        # Override the +all_listeners+ method since callbacks can eventually be
        # attached to objects that have directives, which then they need to
        # be combined
        def all_listeners
          respond_to?(:all_directive_listeners) \
            ? super + all_directive_listeners \
            : super
        end

        # Override the +all_events+ method since callbacks can eventually be
        # attached to objects that have directives, which then they need to
        # be combined
        def all_events
          return super unless respond_to?(:all_directive_events)

          Helpers::AttributeDelegator.new do
            InheritedCollection.merge_hash_array(super, all_directive_events)
          end
        end
      end
    end
  end
end
