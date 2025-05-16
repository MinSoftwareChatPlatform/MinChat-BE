#!/usr/bin/env ruby
require 'securerandom'
require 'json'
require 'redis'
require 'logger'
require_relative 'login_service'
require_relative 'login_context'

module Zalo
  class QRLoginDemo
    def initialize
      @redis = Redis.new
      @logger = Logger.new(STDOUT)
      @test_imei = SecureRandom.uuid
      @login_service = Zalo::LoginService.new(@logger)
    end

    def demo_generate_qr
      puts "===== DEMO GENERATE QR CODE ====="

      begin
        # Define a callback for QR generation events
        callback = lambda do |event|
          puts "Callback received:"
          puts "  - Type: #{event[:type]}"
          puts "  - QR Code ID: #{event[:qr_code_id]}" if event[:qr_code_id]
          puts "  - Message: #{event[:message]}"
          if event[:data]
            puts "  - Data:"
            event[:data].each { |key, value| puts "    - #{key}: #{value}" }
          end
        end

        # Generate QR code
        result = @login_service.generate_qr_code(callback)

        if result[:success]
          puts "QR code generated successfully:"
          puts "  - QR Code ID: #{result[:qr_code_id]}"
          puts "  - Base64 Image: #{result[:base64_image][0..50]}..." # Truncate for readability
          puts "QR code session stored in Redis with key: zalo_qr_#{result[:qr_code_id]}"
          result
        else
          puts "Failed to generate QR code:"
          puts "  - Error: #{result[:error]}"
          nil
        end
      rescue StandardError => e
        @logger.error "Error in demo_generate_qr: #{e.message}\n#{e.backtrace.join("\n")}"
        puts "Error in demo_generate_qr: #{e.message}"
        nil
      end
    end

    def demo_check_qr_scan(qr_code_id)
      puts "\n===== DEMO CHECK QR CODE SCAN WITH CALLBACK ====="
      puts "Checking QR code with ID: #{qr_code_id}"

      # Define a sample callback to handle events
      callback = lambda do |event|
        puts "Callback received:"
        puts "  - Type: #{event[:type]}"
        puts "  - QR Code ID: #{event[:qr_code_id]}" if event[:qr_code_id]
        puts "  - Message: #{event[:message]}"
        if event[:data]
          puts "  - Data:"
          event[:data].each { |key, value| puts "    - #{key}: #{value}" }
        end
      end

      begin
        # Check QR code scan status with callback
        result = @login_service.check_qr_code_scan(qr_code_id, callback, @test_imei)

        if result[:success]
          puts "QR code scan completed successfully:"
          puts "  - Event Type: #{Zalo::LoginEventType::GOT_LOGIN_INFO}"
          puts "  - User Info:"
          puts "    - Name: #{result[:user_info][:display_name]}"
          puts "    - Phone: #{result[:user_info][:phone]}"
          puts "    - Avatar: #{result[:user_info][:avatar]}"
          puts "Zalo account saved successfully."
        else
          puts "Failed to check QR code scan:"
          puts "  - Error: #{result[:error]}"
        end
      rescue StandardError => e
        @logger.error "Error in demo_check_qr_scan_with_callback: #{e.message}\n#{e.backtrace.join("\n")}"
        puts "Error in demo_check_qr_scan_with_callback: #{e.message}"
      end
    end

    def run_all_demos
      puts "==================================================="
      puts "          DEMO QR LOGIN IN ZALO SERVICE"
      puts "==================================================="

      puts "\n1. Generating QR code\n"
      qr_result = demo_generate_qr
      if qr_result && qr_result[:success]
        qr_code_id = qr_result[:qr_code_id]

        puts "\n3. Checking QR code scan with callback\n"
        demo_check_qr_scan(qr_code_id)
      else
        puts "Skipping scan demos due to QR generation failure."
      end

      puts "\n==================================================="
      puts "               END OF DEMO"
      puts "==================================================="
    end
  end
end

begin
  demo = Zalo::QRLoginDemo.new
  demo.run_all_demos
rescue StandardError => e
  puts "Demo failed: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end
