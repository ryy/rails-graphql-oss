# frozen_string_literal: true

module Rails
  module GraphQL
    class Type
      # Uses as a float extension in order to transmit times (hours, minutes,
      # and seconds) as a numeric representation of seconds and milliseconds.
      class Scalar::TimeScalar < Scalar::FloatScalar
        EPOCH = Time.utc(2000, 1, 1)

        desc <<~MSG
          The Time scalar type that represents a distance in time using hours,
          minutes, seconds, and milliseconds.
        MSG

        use :specified_by, url: 'https://www.rfc-editor.org/rfc/rfc3339'

        # A +base_object+ helps to identify what methods are actually available
        # to work as resolvers
        class_attribute :precision, instance_accessor: false, default: 6

        class << self
          def valid_input?(value)
            value.match?(/\d+:\d\d(:\d\d(\.\d+)?)?/)
          end

          def valid_output?(value)
            value.respond_to?(:to_time)
          end

          def as_json(value)
            value.to_time.strftime(format('%%T.%%%dN', precision))
          end

          def deserialize(value)
            (+"#{EPOCH.to_date.iso8601} #{value} UTC").to_time
          end
        end
      end
    end
  end
end
