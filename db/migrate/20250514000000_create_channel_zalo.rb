class CreateChannelZalo < ActiveRecord::Migration[6.1]
  def change
    create_table :channel_zalo do |t|
      t.integer :account_id, null: false
      t.string :zalo_id
      t.string :phone
      t.string :display_name
      t.string :avatar_url
      t.text :cookie_data
      t.string :secret_key
      t.string :imei
      t.string :access_token_data
      t.string :refresh_token_data
      t.string :language, default: 'vi'
      t.integer :api_type, default: 30
      t.integer :api_version, default: 655
      t.datetime :last_activity_at
      t.integer :status, default: 0
      t.jsonb :meta, default: {}

      t.timestamps
    end

    add_index :channel_zalo, :account_id
    add_index :channel_zalo, :zalo_id, unique: true
  end
end
