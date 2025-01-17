# frozen_string_literal: true

Rails::GraphQL.configure do |config|
  # This helps to keep track of when things were cached and registered. Cached
  # objects with mismatching versions need to be upgraded or simply reloaded.
  # An excellent way to use this is to set it to the commit hash. TypePap will
  # always use only the first 8 characters for simplicity.
  # config.version = nil

  # The instance responsible for caching all the information generated by
  # requests and all the other components. Manually setting this property
  # means that the object in it complies with `ActiveSupport::Cache::Store`.
  # This will map automatically to `Rails.cache` if kept as `nil`. This can
  # also be set per Schema.
  # config.cache = nil

  # This is the prefix key of all the cache entries for the GraphQL cached
  # things.
  # config.cache_prefix = 'graphql/'

  # This is very similar to `ActiveRecord` verbose logs, which simply show the
  # path of the file that started a GraphQL request.
  # config.verbose_logs = true

  # The list of parameters to omit from the logger when running a GraphQL
  # request. Those values are displayed better in the internal runtime logger
  # controller.
  # config.omit_parameters = %w[query operationName operation_name variables graphql]

  # Identical to the one available on a Rails application, but exclusive for
  # GraphQL operations. The list of parameters to display as filtered in the
  # logs. When it is nil, it will use the same as the Rails application.
  # config.filter_parameters = nil

  # The suffix that is added automatically to all the Input type objects. This
  # prevents situations like `PointInputInput`. If your inputs have a
  # different suffix, change this value to it.
  # config.auto_suffix_input_objects = 'Input'

  # Introspection is enabled by default. It is recommended to only use
  # introspection during development and tests, never in production.
  # This can also be set per schema level.
  config.enable_introspection = !Rails.env.production?

  # Define the names of the schema/operations types. The single "_" is a
  # suggestion. In an application that has a Subscription object, it will
  # prevent the conflict. Plus, it is easy to spot that it is something
  # internal. This can also be set per Schema.
  # config.schema_type_names = {
  #   query: '_Query',
  #   mutation: '_Mutation',
  #   subscription: '_Subscription',
  # }

  # For performance purposes, this gem implements a
  # {JsonCollector}[rdoc-ref:Rails::GraphQL::Collectors::JsonCollector].
  # You can disable this option if you prefer to use the standard
  # hash-to-string serialization provided by `ActiveSupport`.
  # This can also be set per Schema.
  # config.enable_string_collector = true

  # Set what is de default expected output type of GraphQL requests. String
  # combined with the previous setting has the best performance. On the
  # console, it will automatically shift to Hash. This can also be set per
  # Schema.
  # config.default_response_format = :string

  # Specifies if the results of operations should be encoded with
  # +ActiveSupport::JSON#encode+ instead of the default +JSON#generate+.
  # See also https://github.com/rails/rails/blob/master/activesupport/lib/active_support/json/encoding.rb
  # config.encode_with_active_support = false

  # Enable the ability of a callback to inject arguments dynamically into the
  # calling method.
  # config.callback_inject_arguments = true

  # Enable the ability of a callback to inject named arguments dynamically
  # into the calling method.
  # config.callback_inject_named_arguments = true

  # When importing fields from modules or other objects, a warning is
  # displayed for any given element that was not able to be correctly
  # imported. You can silence such warnings by changing this option.
  # config.silence_import_warnings = false

  # Enable the ability to define the description of any object, field, or
  # argument using I18n. It is recommended for multi-language documentation.
  config.enable_i18n_descriptions = true

  # The method that should be used to parse literal input values when they are
  # provided as Hash. `JSON.parse` only supports keys wrapped in quotes. You
  # can use `Psych.method(:safe_load)` to support keys without quotes, which
  # behaves closer to YAML. The received value is ensured to be wrapped in
  # "{}". If that produces unexpected results, you can assign a proc and then
  # parse the value in any other way.
  # config.literal_input_parser = Psych.method(:safe_load)
end
