# frozen_string_literal: true

require 'concurrent/map'

module Rails
  module GraphQL
    # = GraphQL Type Map
    #
    # Inspired by ActiveRecord::Type::TypeMap, this class stores all the things
    # defined, their unique name, their basic settings, and correctly index
    # them so they are easy to find whenever necessary.
    #
    # Items are stored as procs because aliases should fetch whatever the base
    # object is, even if they change in the another point.
    #
    # The cache stores in the following structure:
    # Namespace -> BaseClass -> ItemKey -> Item
    class TypeMap
      extend ActiveSupport::Autoload

      FILTER_REGISTER_TRACE = /((inherited|initialize)'$|schema\.rb:\d+)/.freeze

      # Store all the base classes that are managed by the Type Map
      mattr_accessor :base_classes, instance_writer: false,
        default: Set.new(%i[Type Directive Schema])

      # Get the current version of the Type Map. On each reset, the version is
      # changed and can be used to invalidate cache and similar things
      def version
        @version ||= GraphQL.config.version&.first(8) || SecureRandom.hex(8)
      end

      # Reset the state of the type mapper
      def reset!
        @objects = 0 # Number of types and directives defined
        @version = nil # Make sure to not keep the same version
        @skip_register = nil

        @pending = Concurrent::Array.new
        @reported_fallbacks = Concurrent::Set.new

        # Initialize the callbacks
        @callbacks = Concurrent::Map.new do |hc, key|
          hc.fetch_or_store(key, Concurrent::Array.new)
        end

        # Initialize the dependencies
        @dependencies = Concurrent::Map.new do |hd, key|
          hd.fetch_or_store(key, Concurrent::Array.new)
        end

        # A registered list of modules and to which namespaces they are
        # associated with
        @module_namespaces = Concurrent::Map.new

        # Initialize the index structure
        @index = Concurrent::Map.new do |h1, key1|                # Namespaces
          base_class = Concurrent::Map.new do |h2, key2|          # Base classes
            ensure_base_class!(key2)
            h2.fetch_or_store(key2, Concurrent::Map.new)          # Items
          end

          h1.fetch_or_store(key1, base_class)
        end

        # Provide the first dependencies
        seed_dependencies!
      end

      alias initialize reset!

      # Add a list of dependencies to the type map, so it can lazy load them
      def add_dependencies(*list, to:)
        @dependencies[to].concat(list.flatten.compact)
      end

      # Mark the given object to be registered later, when a fetch is triggered
      # TODO: Improve this with a Backtrace Cleaner
      def postpone_registration(object)
        source = caller(3).find { |item| item !~ FILTER_REGISTER_TRACE }
        @pending << [object, source]
      end

      # Associate the given +module+ to a given +namespace+. If registered
      # objects have no namespaces, but its +module_parents+ have been
      # associated, then use the value
      # TODO: Maybe turn this into a 1-to-Many association
      def associate(namespace, mod)
        @module_namespaces[mod] = namespace
      end

      # Grab all the +module_parents+ from the object and try to return the
      # first matching result
      def associated_namespace_of(object)
        return if @module_namespaces.empty?
        object.module_parents.find do |mod|
          ns = @module_namespaces[mod]
          break ns unless ns.nil?
        end
      rescue ::NameError
        # If any module parent can't be found, there is no much we can do
      end

      # Register a given object, which must be a class where the namespaces and
      # the base class can be inferred
      def register(object)
        namespaces = sanitize_namespaces(namespaces: object.namespaces, exclusive: true)
        namespaces << :base if namespaces.empty?

        base_class = find_base_class(object)
        ensure_base_class!(base_class)

        # Cache the name, the key, and the alias proc
        object_base = namespaces.first
        object_name = object.gql_name
        object_key = object.to_sym
        alias_proc = -> do
          value = dig(object_base, base_class, object_key)
          value.is_a?(Proc) ? value.call : value
        end

        # TODO Warn when the base key is being assigned to a different object
        # Register the main type object for both key and name
        add(object_base, base_class, object_key, object)
        add(object_base, base_class, object_name, alias_proc)

        # Register all the aliases plus the object name
        aliases = object.try(:aliases)
        aliases&.each do |alias_name|
          add(object_base, base_class, alias_name, alias_proc)
        end

        # For each remaining namespace, register a key and a name alias
        if namespaces.size > 1
          keys_and_names = [object_key, object_name, *aliases]
          namespaces.drop(1).product(keys_and_names) do |(namespace, key_or_name)|
            add(namespace, base_class, key_or_name, alias_proc)
          end
        end

        # Return the object for chain purposes
        @objects += 1
        object
      end

      # Unregister all the provided objects by simply assigning nil to their
      # final value on the index
      def unregister(*objects)
        sub_mod = Type::Creator::NESTED_MODULE
        objects.each do |object|
          namespaces = sanitize_namespaces(namespaces: object.namespaces, exclusive: true)
          namespaces << :base if namespaces.empty?
          base_class = find_base_class(object)

          if object.kind != :source
            @index[namespaces.first][base_class][object.to_sym] = nil
            @objects -= 1
          end

          return unless object.const_defined?(sub_mod, false)

          nested_mod = object.const_get(sub_mod)
          unregister(*nested_mod.constants.map(&nested_mod.method(:const_get)))
          object.send(:remove_const, sub_mod)
        end
      end

      # Register an item alias. Either provide a block that trigger the fetch
      # method to return that item, or a key from the same namespace and base
      # class
      def register_alias(name_or_key, key = nil, **xargs, &block)
        raise ArgumentError, (+<<~MSG).squish unless key.nil? ^ block.nil?
          Provide either a key or a block in order to register an alias.
        MSG

        base_class = xargs.delete(:base_class) || :Type
        ensure_base_class!(base_class)

        namespaces = sanitize_namespaces(**xargs, exclusive: true)
        namespaces << :base if namespaces.empty?

        block ||= -> do
          fetch(key, base_class: base_class, namespaces: namespaces, exclusive: true)
        end

        namespaces.each { |ns| add(ns, base_class, name_or_key, block) }
      end

      # Same as +fetch+ but it will raise an exception or retry depending if the
      # base type was already loaded or not
      def fetch!(key_or_name, base_class: :Type, fallback: nil, **xargs)
        xargs[:base_class] = base_class

        result = fetch(key_or_name, **xargs)
        return result unless result.nil?

        new_loads = load_dependencies!(**xargs)
        result = fetch(key_or_name, **xargs) if new_loads

        if result.nil? && fallback
          result = fetch(fallback, **xargs)
          report_fallback(key_or_name, result, base_class)
        end

        raise NotFoundError, (+<<~MSG).squish if result.nil?
          Unable to find #{key_or_name.inspect} #{base_class} object.
        MSG

        result
      end

      # Find the given key or name inside the base class either on the given
      # namespace or in the base +:base+ namespace
      def fetch(key_or_name, prevent_register: nil, **xargs)
        prevent_register = true if @pending.blank?
        if prevent_register != true
          items = prevent_register == true ? nil : ::Array.wrap(prevent_register)
          skip_register << items.to_set
          register_pending!
        end

        possibilities = ::Array.wrap(key_or_name)
        possibilities << xargs[:fallback] if xargs.key?(:fallback)

        base_class = xargs.fetch(:base_class, :Type)
        sanitize_namespaces(**xargs).find do |namespace|
          possibilities.find do |item|
            next if (result = dig(namespace, base_class, item)).nil?
            next if (result.is_a?(Proc) && (result = result.call).nil?)
            return result
          end
        end
      ensure
        skip_register.pop if prevent_register != true
      end

      # Checks if a given key or name is already defined under the same base
      # class and namespace. If +exclusive+ is set to +false+, then it won't
      # check the +:base+ namespace when not found on the given namespace.
      def exist?(name_or_key, **xargs)
        !fetch(name_or_key, **xargs, prevent_register: true).nil?
      end

      # Find if a given object is already defined. If +exclusive+ is set to
      # +false+, then it won't check the +:base+ namespace
      def object_exist?(object, **xargs)
        xargs[:base_class] = find_base_class(object)
        xargs[:namespaces] ||= object.namespaces
        exist?(object, **xargs)
      end

      # Iterate over the types of the given +base_class+ that are defined on the
      # given +namespaces+.
      def each_from(namespaces, base_class: nil, exclusive: false, base_classes: nil, &block)
        namespaces = sanitize_namespaces(namespaces: namespaces, exclusive: exclusive)
        load_dependencies!(_ns: namespaces)
        register_pending!

        iterated = Set.new
        base_classes = GraphQL.enumerate(base_class || base_classes || :Type)
        enumerator = Enumerator::Lazy.new(namespaces) do |yielder, namespace|
          next unless @index.key?(namespace)

          base_classes.each do |a_base_class|
            @index[namespace][a_base_class]&.each do |key, value|
              value = value.is_a?(Proc) ? value.call : value
              next if value.blank? || iterated.include?(value.gql_name)

              iterated << value.gql_name
              yielder << value
            end
          end
        end

        block.present? ? enumerator.each(&block) : enumerator
      end

      # Get the list of all registered objects
      # TODO: Maybe keep it as a lazy enumerator
      def objects(base_classes: nil, namespaces: nil)
        base_classes ||= self.class.base_classes
        each_from(namespaces || @index.keys, base_classes: base_classes).select do |obj|
          obj.is_a?(Helpers::Registerable)
        end.force
      end

      # Add a callback that will trigger when a type is registered under the
      # given set of settings of this method
      def after_register(name_or_key, base_class: :Type, **xargs, &block)
        item = fetch(name_or_key, prevent_register: true, base_class: base_class, **xargs)
        return block.call(item) unless item.nil?

        namespaces = sanitize_namespaces(**xargs)
        callback = ->(n, b, result) do
          return unless b === base_class && (n === :base || namespaces.include?(n))
          block.call(result)
          true
        end

        callbacks[name_or_key].unshift(callback)
      end

      def inspect
        dependencies = @dependencies.each_pair.map do |key, list|
          +("#{key}: #{list.size}")
        end.join(', ')

        (+<<~INFO).squish << '>'
          #<Rails::GraphQL::TypeMap [index]
          @namespaces=#{@index.size}
          @base_classes=#{base_classes.size}
          @objects=#{@objects}
          @pending=#{@pending.size}
          @dependencies={#{dependencies}}
        INFO
      end

      private

        attr_reader :callbacks

        # Add a item to the index and then trigger the callbacks if any
        def add(namespace, base_class, key, raw_result)
          @index[namespace][base_class][key] = raw_result
          return unless callbacks.key?(key)

          result = nil
          callbacks[key].delete_if do |callback|
            result ||= raw_result.is_a?(Proc) ? raw_result.call : raw_result
            callback.call(namespace, base_class, result)
          end

          callbacks.delete(key) if callbacks[key].empty?
        end

        # Make sure to parse the provided options and names and return a
        # quality list of namespaces
        def sanitize_namespaces(**xargs)
          xargs[:_ns] ||= begin
            result = xargs[:namespaces] || xargs[:namespace]
            result = result.is_a?(Set) ? result.dup : Array.wrap(result).to_set
            result << :base unless xargs.fetch(:exclusive, false)
            result
          end
        end

        # A list of classes to prevent the registration, since they might be
        # the source of a fetch
        def skip_register
          @skip_register ||= []
        end

        # Clear the pending list of classes to be registered
        def register_pending!
          return if @pending.blank?

          skip = skip_register.compact.reduce(:+)
          keep = []

          while (klass, source = @pending.shift)
            next if klass.registered?

            if skip&.include?(klass)
              keep << [klass, source]
            else
              klass.register!
            end
          end
        rescue DefinitionError => e
          raise e.class, +"#{e.message}\n  Defined at: #{source}"
        ensure
          @pending += keep unless keep.nil?
        end

        # Check the given namespaces and load any pending dependency, it returns
        # true if anything was actually loaded
        def load_dependencies!(**xargs)
          sanitize_namespaces(**xargs).reduce(false) do |result, namespace|
            next result if (list = @dependencies[namespace]).empty?

            while (src = list.shift)
              src.is_a?(Proc) ? src.call : require(src)
            end

            true
          end
        end

        # Since concurrent map doesn't implement this method, use this to
        # navigate through the index
        def dig(*parts)
          parts.inject(@index) do |h, key|
            break unless h.key?(key)
            h.fetch(key)
          end
        end

        # Find the base class of an object, which is basically the class that
        # doesn't inherit any other class (superclass is equal Object)
        def find_base_class(object)
          return object.base_type_class if object.respond_to?(:base_type_class)

          base_class = object
          base_class = base_class.superclass until base_class.superclass === Object
          base_class.name.demodulize.to_sym
        end

        # This is the minimum set of dependencies that Type Map needs
        # TODO: Maybe add even looser dependency
        def seed_dependencies!
          @dependencies[:base] += [
            "#{__dir__}/type/scalar",
            "#{__dir__}/type/object",
            "#{__dir__}/type/interface",
            "#{__dir__}/type/union",
            "#{__dir__}/type/enum",
            "#{__dir__}/type/input",

            "#{__dir__}/type/scalar/int_scalar",
            "#{__dir__}/type/scalar/float_scalar",
            "#{__dir__}/type/scalar/string_scalar",
            "#{__dir__}/type/scalar/boolean_scalar",
            "#{__dir__}/type/scalar/id_scalar",

            "#{__dir__}/directive/deprecated_directive",
            "#{__dir__}/directive/include_directive",
            "#{__dir__}/directive/skip_directive",
            "#{__dir__}/directive/specified_by_directive",
          ]
        end

        # Make sure that the given key is a valid base class key
        def ensure_base_class!(key)
          raise ArgumentError, (+<<~MSG).squish unless base_classes.include?(key)
            Unsupported base class "#{key.inspect}".
          MSG
        end

        # Warn whenever a new key was resolved as a fallback
        def report_fallback(key_or_name, result, base_class)
          return if @reported_fallbacks.include?(key_or_name)

          @reported_fallbacks << key_or_name
          GraphQL.logger.warn((+<<~MSG).squish)
            \e[95m[GraphQL]
            \e[33m#{base_class} "#{key_or_name}" is not defined,
            using #{result.gql_name} instead.\e[0m
          MSG
        end
    end
  end
end
