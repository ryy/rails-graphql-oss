require 'config'

DESCRIBED_CLASS = Rails::GraphQL::Type::Scalar::BigintScalar

class BigintScalarTest < GraphQL::TestCase
  def test_valid_input_ask
    assert_equal(true, DESCRIBED_CLASS.valid_input?('123456789101112131415161718192021222324252627282930'))
    assert_equal(true, DESCRIBED_CLASS.valid_input?('+123'))
    assert_equal(true, DESCRIBED_CLASS.valid_input?('-123'))
    assert_equal(false, DESCRIBED_CLASS.valid_input?(1))
    assert_equal(false, DESCRIBED_CLASS.valid_input?('12.0'))
    assert_equal(false, DESCRIBED_CLASS.valid_input?('1abc'))
    assert_equal(false, DESCRIBED_CLASS.valid_input?(nil))
  end

  def test_valid_output_ask
    assert_equal(true, DESCRIBED_CLASS.valid_output?(1))
    assert_equal(true, DESCRIBED_CLASS.valid_output?('abc'))
    assert_equal(true, DESCRIBED_CLASS.valid_output?(nil))
    assert_equal(false, DESCRIBED_CLASS.valid_output?([1,'abc']))
  end

  def test_as_json
    assert_equal('1', DESCRIBED_CLASS.as_json(1))
    assert_equal('0', DESCRIBED_CLASS.as_json(nil))
    assert_equal('0', DESCRIBED_CLASS.as_json('a'))
  end

  def test_deserialize
    assert_equal(1, DESCRIBED_CLASS.deserialize(1))
    assert_equal(0, DESCRIBED_CLASS.deserialize('a'))
    assert_equal(0, DESCRIBED_CLASS.deserialize(nil))
  end
end