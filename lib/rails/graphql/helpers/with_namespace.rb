# frozen_string_literal: true

module Rails # :nodoc:
  module GraphQL # :nodoc:
    module Helpers # :nodoc:
      # Helper module that allows other objects to hold namespaces. It can
      # either work as an extension of the superclass using +add_namespace+ or
      # it can be reseted then set using +namespace+.
      module WithNamespace
        # Returns the list of defined namespaces
        def namespaces
          @namespaces || superclass.try(:namespaces) || (@namespaces = Set.new)
        end

        # Set or overwrite the list of namepsaces
        def namespace(*list)
          @namespaces = normalize_namespaces(list).to_set
        end

        # Add more namespaces to the list already defined. If the super class
        # has already defined namespaces, the extend that list.
        def add_namespace(*list)
          @namespaces = (superclass.try(:namespaces)&.dup || Set.new) \
            unless defined?(@namespaces)

          @namespaces.merge(normalize_namespaces(list))
        end

        private

          def normalize_namespaces(list)
            list.map { |item| item.to_s.underscore.to_sym }
          end
      end
    end
  end
end
