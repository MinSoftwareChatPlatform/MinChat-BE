require 'rails_helper'

RSpec.describe Channel::Zalo, type: :model do
  describe 'validations' do
    it 'is valid with valid attributes' do
      channel = Channel::Zalo.new(attribute1: 'value1', attribute2: 'value2')
      expect(channel).to be_valid
    end

    it 'is not valid without required attributes' do
      channel = Channel::Zalo.new(attribute1: nil)
      expect(channel).to_not be_valid
    end
  end

  describe 'associations' do
    it 'has many messages' do
      association = Channel::Zalo.reflect_on_association(:messages)
      expect(association.macro).to eq :has_many
    end
  end

  describe 'methods' do
    it 'returns expected value from a method' do
      channel = Channel::Zalo.new(attribute1: 'value1')
      expect(channel.some_method).to eq 'expected_value'
    end
  end
end