# frozen_string_literal: true

module Rails
  module GraphQL
    module Helpers
      module WithDescription

        # Define and format description
        def description=(value)
          @description = value.to_s.presence&.strip_heredoc&.chomp
        end

        # Return the description of the argument
        def description(namespace = nil, kind = nil)
          return @description if description?
          return i18n_description(namespace, kind) if GraphQL.config.enable_i18n_descriptions
        end

        # Return a description from I18n
        def i18n_description(namespace = nil, kind = nil)
          values = {
            kind: kind || try(:kind),
            parent: try(:owner)&.try(:to_sym),
            namespace: namespace || try(:namespaces)&.first,
            name: is_a?(Module) ? to_sym : name,
          }

          keys = GraphQL.config.i18n_scopes.map do |key|
            format(key, values).to_sym
          end

          ::I18n.translate!(keys.shift, default: keys)
        rescue I18n::MissingTranslationData
          nil
        end

        # Checks if a description was provided
        def description?
          defined?(@description) && !!@description
        end

      end
    end
  end
end