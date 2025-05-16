#!/usr/bin/env ruby
require 'securerandom'
require 'json'
require 'ostruct'
require 'rest-client'
require_relative 'encryption_service' # Points to zalo_crypto_helper.rb
require_relative 'zalo_url_manager'

module Zalo
  class EncryptionDemo
    def initialize
      @test_imei = SecureRandom.uuid
      @zalo_account = OpenStruct.new(
        imei: @test_imei,
        api_type: 30,
        api_version: 655,
        language: 'vi',
        cookie: 'zpw_sek=yAl0.278914040.a0.ybmgYxKqw69DrtTob3JeOiuMZGcN3ieRna2GCFODXHN3HCTNtLoZ4TnThXZa2TL0o4LQKlde02EADPqTb5peOW; _zlang=vn; zpsid=i9ii.278914040.225.IKKGchsPuDD5Ud_3iPdWqyZgak6AeTdYYQdKuymhq9zXSQ7ilEsVyjMPuDC; _gat=1; _gid=GA1.2.916709822.1746758119; app.event.zalo.me=4924637835867111134; __zi-legacy=3000.SSZzejyD6zOgdh2mtnLQWYQN_RAG01ICFjIXe9fEM8uvaUIZcKPLZt6Gvw3TGbM8VPtWfZWv.1; zpw_sek=yAl0.278914040.a0.ybmgYxKqw69DrtTob3JeOiuMZGcN3ieRna2GCFODXHN3HCTNtLoZ4TnThXZa2TL0o4LQKlde02EADPqTb5peOW; __zi=3000.SSZzejyD6zOgdh2mtnLQWYQN_RAG01ICFjIXe9fEM8uvaUIZcKPLZt6Gvw3TGbM8VPtWfZWv.1; _ga_RYD7END4JE=GS1.2.1738655365.2.0.1738655365.60.0.0; _ga=GA1.2.890777085.1738574453;'
      )
      @encryption_service = Zalo::ZaloCryptoHelper.new(@zalo_account)
    end

    def demo_get_login_info
      puts "===== DEMO GET LOGIN INFO ====="

      begin
        # Get encryption parameters
        encrypted_result = @encryption_service.get_encrypt_param(true, "getlogininfo")
        encrypted_result[:params_dict]['nretry'] = '0' unless encrypted_result[:params_dict].key?('nretry')

        puts "Kết quả mã hóa tham số:"
        puts "  - Khóa mã hóa (enk): #{encrypted_result[:enk]}"
        puts "  - Tham số mã hóa: #{encrypted_result[:params_dict]}"

        # Create the API URL
        api_url = Zalo::URLManager::Login::GET_LOGIN_INFO
        full_url = @encryption_service.make_url(api_url, encrypted_result[:params_dict])

        puts "URL gọi API: #{full_url}"

        # Make the API request
        response = RestClient.get(full_url, cookies: { 'Cookie' => @zalo_account.cookie })

        # Parse the response
        parsed_response = JSON.parse(response.body)
        encrypted_data = parsed_response["data"].to_s

        # Decrypt the response
        decrypted_data = @encryption_service.decrypt_resp(encrypted_result[:enk], encrypted_data)
        return puts "Not data" if decrypted_data["data"].nil?
        parsed_decrypted = JSON.parse(decrypted_data)

        puts "Dữ liệu giải mã:"
        puts JSON.pretty_generate(parsed_decrypted)

      rescue StandardError => e
        puts "Lỗi trong demo get login info: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end

    def run_all_demos
      puts "==================================================="
      puts "          DEMO MÃ HÓA TRONG ZALO SERVICE"
      puts "==================================================="
      puts "\n1. Gọi API getlogininfo với mã hóa\n"
      demo_get_login_info
      puts "\n==================================================="
      puts "               KẾT THÚC DEMO"
      puts "==================================================="
    end
  end
end

# ==========================
# Chạy chương trình
# ==========================
begin
  demo = Zalo::EncryptionDemo.new
  demo.run_all_demos
rescue StandardError => e
  puts "Demo failed: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
