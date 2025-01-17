# frozen_string_literal: true

module Rails
  module GraphQL
    module Helpers
      # Helper module that allows other objects to hold schema fields (query,
      # mutation, and subscription fields). Works very similar to fields, but
      # they are placed in different places regarding their type.
      module WithSchemaFields
        TYPE_FIELD_CLASS = {
          query:        'OutputField',
          mutation:     'MutationField',
          subscription: 'SubscriptionField',
        }.freeze

        module ClassMethods
          def inherited(subclass)
            super if defined? super

            TYPE_FIELD_CLASS.each_key do |type|
              fields = instance_variable_defined?("@#{type}_fields")
              fields = fields ? instance_variable_get("@#{type}_fields") : EMPTY_HASH
              fields.each_value { |field| subclass.add_proxy_field(type, field) }
            end
          end
        end

        # Helper class to be used as the +self+ in configuration blocks
        ScopedConfig = Struct.new(:source, :type) do
          def argument(*args, **xargs, &block)
            xargs[:owner] ||= source
            GraphQL::Argument.new(*args, **xargs, &block)
          end

          alias arg argument
          alias kind type

          private

            def respond_to_missing?(method_name, include_private = false)
              schema_methods.key?(method_name) ||
                source.respond_to?(method_name, include_private) || super
            end

            def method_missing(method_name, *args, **xargs, &block)
              schema_method = schema_methods[method_name]
              args.unshift(type) unless schema_method.nil?
              source.send(schema_method || method_name, *args, **xargs, &block)
            end

            def schema_methods
              @@schema_methods ||= begin
                typed_methods = WithSchemaFields.public_instance_methods
                typed_methods = typed_methods.zip(typed_methods).to_h
                typed_methods.merge(
                  fields:      :fields_for,
                  fields?:     :fields_for?,
                  safe_field:  :safe_add_field,
                  field:       :add_field,
                  proxy_field: :add_proxy_field,
                  import:      :import_into,
                  import_all:  :import_all_into,
                )
              end
            end
        end

        def self.extended(other)
          other.extend(WithSchemaFields::ClassMethods)
        end

        # A little helper for getting the list of fields of a given type
        def fields_for(type, initialize = nil)
          if instance_variable_defined?(ivar = :"@#{type}_fields")
            instance_variable_get(ivar)
          elsif initialize
            instance_variable_set(ivar, Concurrent::Map.new)
          end
        end

        # Allow hash access with the type or the type and the name
        def [](type, name = nil)
          name.nil? ? fields_for(type) : find_field(type, name)
        end

        # Check if there are fields set fot he given type
        def fields_for?(type)
          public_send("#{type}_fields?")
        end

        # Return the object name for a given +type+ of list of fields
        def type_name_for(type)
          method_name = :"#{type}_type_name"
          public_send(method_name) if respond_to?(method_name)
        end

        # Only add the field if it is not already defined
        def safe_add_field(*args, of_type: nil, **xargs, &block)
          method_name = of_type.nil? ? :add_field : "add_#{of_type}_field"
          public_send(method_name, *args, **xargs, &block)
        rescue DuplicatedError
          # Do not do anything if it is duplicated
        end

        # Add a new field of the give +type+
        # See {OutputField}[rdoc-ref:Rails::GraphQL::OutputField] class.
        def add_field(type, *args, **xargs, &block)
          klass = Field.const_get(TYPE_FIELD_CLASS[type])
          object = klass.new(*args, **xargs, owner: self, &block)

          raise DuplicatedError, (+<<~MSG).squish if has_field?(type, object.name)
            The "#{object.name}" field is already defined on #{type} fields and
            cannot be redefined.
          MSG

          fields_for(type, true)[object.name] = object
        rescue DefinitionError => e
          raise e.class, +"#{e.message}\n  Defined at: #{caller(2)[0]}"
        end

        # Add a new field to the list but use a proxy instead of a hard copy of
        # a given +field+
        def add_proxy_field(type, field, *args, **xargs, &block)
          field = field.field if field.is_a?(Module) && field <= Alternative::Query
          raise ArgumentError, (+<<~MSG).squish if field.schema_type != type
            A #{field.schema_type} field cannot be added as a #{type} field.
          MSG

          klass = Field.const_get(TYPE_FIELD_CLASS[type])
          raise ArgumentError, (+<<~MSG).squish unless field.is_a?(klass)
            The #{field.class.name} is not a valid field for #{type} fields.
          MSG

          xargs[:owner] = self
          object = field.to_proxy(*args, **xargs, &block)
          raise DuplicatedError, (+<<~MSG).squish if has_field?(type, object.name)
            The #{field.name.inspect} field is already defined on #{type} fields
            and cannot be replaced.
          MSG

          fields_for(type, true)[object.name] = object
        end

        # Find a field and then change some flexible attributes of it
        def change_field(type, object, **xargs, &block)
          find_field!(type, object).apply_changes(**xargs, &block)
        end

        alias overwrite_field change_field

        # Run a configuration block for the given field of a given +type+
        def configure_field(type, object, &block)
          find_field!(type, object).configure(&block)
        end

        # Disable a list of given +fields+ from a given +type+
        def disable_fields(type, *list)
          list.flatten.map { |item| find_field(type, item)&.disable! }
        end

        # Enable a list of given +fields+ from a given +type+
        def enable_fields(type, *list)
          list.flatten.map { |item| find_field(type, item)&.enable! }
        end

        # Check if a field of the given +type+ exists. The +object+ can be the
        # +gql_name+, +name+, or an actual field.
        def has_field?(type, object)
          return false unless fields_for?(type)
          object = object.name if object.is_a?(GraphQL::Field)
          fields_for(type).key?(object.is_a?(String) ? object.underscore.to_sym : object)
        end

        # Find a specific field on the given +type+ list. The +object+ can be
        # the +gql_name+, +name+, or an actual field.
        def find_field(type, object)
          return unless fields_for?(type)
          object = object.name if object.is_a?(GraphQL::Field)
          fields_for(type)[object.is_a?(String) ? object.underscore.to_sym : object]
        end

        # If the field is not found it will raise an exception
        def find_field!(type, object)
          find_field(type, object) || raise(NotFoundError, (+<<~MSG).squish)
            The #{object.inspect} field on #{type} is not defined yet.
          MSG
        end

        # Get the list of GraphQL names of all the fields defined
        def field_names_for(type, enabled_only = true)
          source = (enabled_only ? enabled_fields_from(type) : lazy_each_field_from(type))
          source&.map(&:gql_name)&.eager
        end

        # Return a lazy enumerator for enabled fields
        def enabled_fields_from(type)
          lazy_each_field_from(type)&.select(&:enabled?)
        end

        # Run a configuration block for the given +type+
        def configure_fields(type, &block)
          WithSchemaFields::ScopedConfig.new(self, type).instance_exec(&block)
        end

        # Import a class of fields into the given section of schema fields
        def import_into(type, source)
          # Import an alternative declaration of a field
          if source.is_a?(Module) && source <= Alternative::Query
            return add_proxy_field(type, source.field)
          end

          case source
          when Array
            # Import a list of fields
            source.each { |field| add_proxy_field(type, field) }
          when Hash, Concurrent::Map
            # Import a keyed list of fields
            source.each_value { |field| add_proxy_field(type, field) }
          when Helpers::WithFields
            # Import a set of fields
            source.fields.each_value { |field| add_proxy_field(type, field) }
          when Helpers::WithSchemaFields
            # Import other schema fields
            (type == :all ? TYPE_FIELD_CLASS.each_key : type.then).each do |import_type|
              source.fields_for(import_type)&.each_value do |field|
                add_proxy_field(import_type, field)
              end
            end
          else
            return if GraphQL.config.silence_import_warnings
            GraphQL.logger.warn(+"Unable to import #{source.inspect} into #{self.name}.")
          end
        end

        # Import a module containing several classes to be imported
        # TODO: Maybe add deepness into the recursive value
        def import_all_into(type, mod, recursive: false, **xargs)
          mod.constants.each do |const_name|
            object = mod.const_get(const_name)

            import_into(type, object, **xargs) if object.is_a?(Class)
            import_all_into(type, object, recursive: recursive, **xargs) if recursive && object.is_a?(Module)
          end
        end

        # Same as above, but if the name of the module being imported already
        # dictates the type, skip specifying it
        def import_all(mod, **xargs)
          type = mod.name.demodulize.underscore.singularize
          type = TYPE_FIELD_CLASS.each_key.find { |key| key.to_s == type }
          return import_all_into(type, mod, **xargs) unless type.nil?

          raise(::ArgumentError, (+<<~MSG).squish)
            Unable to extract type from #{mod.name}.
            Please use "import_all_into(_type_, #{mod.name}) instead."
          MSG
        end

        # Validate all the fields to make sure the definition is valid
        def validate!(*)
          super if defined? super

          TYPE_FIELD_CLASS.each_key do |type|
            next unless public_send("#{type}_fields?")
            fields_for(type).each_value(&:validate!)
          end
        end

        # Find a specific field using its id as +gql_name.type+
        def find_by_gid(gid)
          find_field!(gid.scope, gid.name)
        end

        TYPE_FIELD_CLASS.each_key do |type|
          class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{type}_fields?
              defined?(@#{type}_fields) && @#{type}_fields.present?
            end

            def #{type}_fields(&block)
              configure_fields(:#{type}, &block) if block.present?
              @#{type}_fields if defined?(@#{type}_fields)
            end

            def add_#{type}_field(*args, **xargs, &block)
              add_field(:#{type}, *args, **xargs, &block)
            end

            def #{type}_field?(name)
              has_field?(:#{type}, name)
            end

            def #{type}_field(name)
              find_field(:#{type}, name)
            end

            def #{type}_type_name
              source = (respond_to?(:config) ? config : GraphQL.config)
              source.schema_type_names[:#{type}]
            end

            def #{type}_type
              return unless #{type}_fields?

              OpenStruct.new(
                name: "\#{name}[:#{type}]",
                kind: :object,
                object?: true,
                kind_enum: 'OBJECT',
                fields: @#{type}_fields,
                gql_name: #{type}_type_name,
                description: nil,
                output_type?: true,
                operational?: true,
                interfaces?: false,
                internal?: false,
              ).freeze
            end
          RUBY
        end

        protected

          # A little helper to define arguments using the :arguments key
          def argument(*args, **xargs, &block)
            xargs[:owner] = self
            GraphQL::Argument.new(*args, **xargs, &block)
          end

          alias arg argument

        private

          def lazy_each_field_from(type)
            fields_for(type).each_pair.lazy.each_entry.map(&:last) if fields_for?(type)
          end
      end
    end
  end
end
