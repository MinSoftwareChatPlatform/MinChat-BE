FactoryBot.define do
  factory :channel_zalo do
    name { "Zalo Channel" }
    description { "A channel for Zalo messaging" }
    status { "active" }
    created_at { Time.now }
    updated_at { Time.now }
  end
end