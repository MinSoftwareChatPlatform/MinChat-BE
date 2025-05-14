#!/usr/bin/env ruby
require 'securerandom'
require 'json'
require 'ostruct'
require 'redis'
require 'httparty'
require_relative 'login_service' # Points to the provided Zalo::LoginService
require_relative 'encryption_service' # Assumes Zalo::EncryptionService is available
require_relative 'zalo_url_manager' # Assumes Zalo::URLManager is available

module Zalo
  class QRLoginDemo
    def initialize
      @test_imei = SecureRandom.uuid
      @redis = Redis.new
      @zalo_account = OpenStruct.new(
        imei: @test_imei,
        api_type: 30,
        api_version: 655,
        language: 'vi'
      )
      @login_service = Zalo::LoginService.new(@zalo_account)
    end

    def demo_generate_qr
      puts "===== DEMO GENERATE QR CODE ====="

      begin
        # Generate QR code
        result = @login_service.generate_qr_code

        if result[:success]
          puts "QR code generated successfully:"
          puts "  - QR Code ID: #{result[:qr_code_id]}"
          puts "  - QR Image URL: #{result[:qr_image_url][0..50]}..." # Truncate for readability
          puts "QR code session stored in Redis with key: zalo_qr_#{result[:qr_code_id]}"
        else
          puts "Failed to generate QR code:"
          puts "  - Error: #{result[:error]}"
        end
      rescue StandardError => e
        puts "Error in demo_generate_qr: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end

    def demo_check_qr_scan(qr_code_id)
      puts "\n===== DEMO CHECK QR CODE SCAN ====="
      puts "Checking QR code with ID: #{qr_code_id}"

      begin
        # Check QR code scan status
        result = @login_service.check_qr_code_scan(qr_code_id)

        if result[:success]
          puts "QR code scan successful:"
          puts "  - Event Type: #{result[:event_type]}"
          puts "  - User Info:"
          puts "    - Name: #{result[:user_info][:name]}"
          puts "    - Phone: #{result[:user_info][:phone]}"
          puts "    - Avatar: #{result[:user_info][:avatar]}"
          puts "Zalo account saved successfully."
        else
          puts "Failed to check QR code scan:"
          puts "  - Error: #{result[:error]}"
          puts "  - Event Type: #{result[:event_type]}" if result[:event_type]
        end
      rescue StandardError => e
        puts "Error in demo_check_qr_scan: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end

    def demo_check_qr_scan_with_callback(qr_code_id)
      puts "\n===== DEMO CHECK QR CODE SCAN WITH CALLBACK ====="
      puts "Checking QR code with ID: #{qr_code_id}"

      # Define a sample callback to handle events
      callback = lambda do |event|
        puts "Callback received:"
        puts "  - Type: #{event[:type]}"
        puts "  - QR Code ID: #{event[:qr_code_id]}"
        puts "  - Message: #{event[:message]}"
        if event[:data]
          puts "  - Data:"
          event[:data].each { |key, value| puts "    - #{key}: #{value}" }
        end
      end

      begin
        # Check QR code scan status with callback
        result = @login_service.check_qr_code_scan_with_callback(qr_code_id, user_id, callback)

        if result[:success]
          puts "QR code scan completed successfully:"
          puts "  - Event Type: #{result[:event_type]}"
          puts "  - User Info:"
          puts "    - Name: #{result[:user_info][:name]}"
          puts "    - Phone: #{result[:user_info][:phone]}"
          puts "    - Avatar: #{result[:user_info][:avatar]}"
          puts "Zalo account saved successfully."
        else
          puts "Failed to check QR code scan:"
          puts "  - Error: #{result[:error]}"
          puts "  - Event Type: #{result[:event_type]}" if result[:event_type]
        end
      rescue StandardError => e
        puts "Error in demo_check_qr_scan_with_callback: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end

    def run_all_demos
      puts "==================================================="
      puts "          DEMO QR LOGIN IN ZALO SERVICE"
      puts "==================================================="

      puts "\n1. Generating QR code\n"
      qr_result = @login_service.generate_qr_code
      if qr_result[:success]
        qr_code_id = qr_result[:qr_code_id]

        puts "\n2. Checking QR code scan without callback\n"
        demo_check_qr_scan(qr_code_id)

        puts "\n3. Checking QR code scan with callback\n"
        demo_check_qr_scan_with_callback(qr_code_id)
      else
        puts "Skipping scan demos due to QR generation failure: #{qr_result[:error]}"
      end

      puts "\n==================================================="
      puts "               END OF DEMO"
      puts "==================================================="
    end
  end
end

# ==========================
# Run the program
# ==========================
begin
  demo = Zalo::QRLoginDemo.new
  demo.run_all_demos
rescue StandardError => e
  puts "Demo failed: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
