# app/services/zalo/login_service.rb
require 'http'
require 'json'
require 'securerandom'
require 'redis'
require 'timeout'
require 'logger'
require 'http-cookie'
require_relative 'zalo_url_manager'
require_relative 'encryption_service'
require 'typhoeus'

module Zalo
  module QRCallbackEventType
    QR_CODE_GENERATED = :qr_code_generated
    QR_CODE_SCANNED = :qr_code_scanned
    QR_CODE_DECLINED = :qr_code_declined
    QR_CODE_EXPIRED = :qr_code_expired
    GOT_LOGIN_INFO = :got_login_info
    ACCOUNT_EXISTS = :account_exists
  end

  class LoginService
    include Zalo::URLManager::Login

    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36'

    attr_reader :channel_zalo, :imei, :cookie_jar, :logger, :redis, :client

    def initialize(channel_zalo_instance = nil)
      @logger = ::Logger.new(STDOUT)
      @logger.level = ::Logger::INFO
      @channel_zalo = channel_zalo_instance
      @imei = channel_zalo_instance&.imei || SecureRandom.uuid
      @cookies = {}
      # Fallback cookies
      @cookies['_zlang'] = 'vn'
      @cookies['__zi'] = '2000.QOBlzDCV2uGerkFzm09Hqs3Hulp315FNAzBX_uW6LjSgsUlwDpW.1'
      @redis = Redis.new
      @logger.info "[Zalo::LoginService] Initialized cookies: #{cookie_string}"
    end

    def generate_qr_code
      @logger.info "[Zalo::LoginService] Generating QR code for IMEI: #{@imei}"
      begin
        version = load_login_page
        return { success: false, error: 'Failed to load login page' } unless version

        get_login_info(version)
        verify_client(version)
        qr_data = generate_qr(version)
        return { success: false, error: 'Failed to generate QR code' } unless qr_data

        qr_code_id = SecureRandom.uuid
        base64_image = qr_data['image'].sub('data:image/png;base64,', '')

        @redis.setex("zalo_qr_#{qr_code_id}", 300, {
          context: { cookie_jar: @cookie_jar.to_h },
          version: version,
          code: qr_data['code'],
          timestamp: Time.now.to_i
        }.to_json)

        @logger.info "[Zalo::LoginService] Stored QR session in Redis with cookies: #{cookie_string}"

        { success: true, qr_code_id: qr_code_id, qr_image_url: "data:image/png;base64,#{base64_image}" }
      rescue => e
        @logger.error "[Zalo::LoginService] QR Generation Error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error generating QR code: #{e.message}" }
      end
    end

    def check_qr_code_scan(qr_code_id)
      @logger.info "[Zalo::LoginService] Checking QR code status for ID: #{qr_code_id}"

      begin
        qr_session = @redis.get("zalo_qr_#{qr_code_id}")
        return { success: false, error: 'QR session not found or expired' } unless qr_session

        qr_data = JSON.parse(qr_session)
        cookies_data = qr_data['context']['cookies']
        temp_cookie_jar = HTTP::CookieJar.new
        cookies_data.each do |cookie_data|
          expires = cookie_data['expires'] ? Time.parse(cookie_data['expires']) : nil
          cookie = HTTP::Cookie.new(
            name: cookie_data['name'],
            value: cookie_data['value'],
            domain: cookie_data['domain'],
            for_domain: true,
            path: cookie_data['path'],
            expires: expires,
            secure: cookie_data['secure']
          )
          temp_cookie_jar.add(cookie)
        end
        temp_client = HTTP.use(:cookie_jar, jar: temp_cookie_jar).headers(@client.headers)

        scan_result = waiting_scan(temp_client, qr_data['version'], qr_data['code'])
        return handle_scan_error(scan_result, qr_code_id) unless scan_result['error_code'] == 0

        confirm_result = waiting_confirm(temp_client, qr_data['version'], qr_data['code'])
        return handle_confirm_error(confirm_result, qr_code_id) unless confirm_result['error_code'] == 0

        session_valid = check_session(temp_client)
        return { success: false, error: 'Failed to check session' } unless session_valid

        user_info_resp = get_user_info(temp_client)
        return { success: false, error: 'Failed to get user info' } unless user_info_resp&.dig('data', 'logged')

        user_info = {
          name: user_info_resp['data']['info']['name'],
          avatar: user_info_resp['data']['info']['avatar']
        }

        zalo_account = Channel::Zalo.new(imei: @imei, api_type: 30, api_version: 655)
        encrypt_params = @encryption_service.get_encrypt_param(zalo_account, true, 'getlogininfo')
        url = @encryption_service.make_url(zalo_account, GET_LOGIN_INFO, encrypt_params[:params_dict])
        uri = URI('https://chat.zalo.me/')
        cookies = temp_cookie_jar.cookies(uri)
        cookie_string = HTTP::Cookie.cookie_value(cookies)
        response = temp_client.get(url)
        return { success: false, error: 'Failed to get login info' } unless response.status == 200
        parsed = JSON.parse(response.body)
        decrypted = JSON.parse(@encryption_service.decrypt_resp(encrypt_params[:enk], parsed['data']))

        zalo_account = Channel::Zalo.new(
          zalo_id: decrypted['data']['uid'],
          display_name: user_info[:name],
          avatar: user_info[:avatar],
          secret_key: decrypted['data']['zpw_enk'],
          cookie: cookie_string,
          imei: @imei,
          phone: "0#{decrypted['data']['phone_number'][2..-1]}",
          api_type: 30,
          api_version: 655,
          language: 'vi'
        )

        existing = Channel::Zalo.find_by(zalo_id: zalo_account.zalo_id)
        return { success: false, error: 'Account already exists', event_type: QRCallbackEventType::ACCOUNT_EXISTS } if existing

        zalo_account.save!
        @redis.del("zalo_qr_#{qr_code_id}")
        start_keep_alive(qr_code_id, cookies_data)

        { success: true, event_type: QRCallbackEventType::GOT_LOGIN_INFO, user_info: user_info.merge(phone: zalo_account.phone) }
      rescue => e
        @logger.error "[Zalo::LoginService] QR Check Error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error checking QR code: #{e.message}" }
      end
    end

    private

    def load_login_page
      @logger.info "[Zalo::LoginService] Loading Zalo login page"
      url = 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      begin
        response = make_request(
          :get,
          'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
          headers: {
            'Connection' => 'keep-alive',
            'User-Agent' => DEFAULT_USER_AGENT,
            'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
            'Accept-Language' => 'vi-VN,vi;q=0.9',
            'sec-ch-ua' => '"Chromium";v="136", "Google Chrome";v="136", "Not.A/Brand";v="99"',
            'sec-ch-ua-mobile' => '?0',
            'sec-ch-ua-platform' => '"Windows"'
          }
        )

        @logger.info "[Zalo::LoginService] Response code: #{response.code}"
        @logger.info "[Zalo::LoginService] Response body: #{response.body[0..500]}..."
        @logger.info "[Zalo::LoginService] Response headers: #{response.headers.inspect}"

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to load login page: HTTP status #{response.code}"
          return nil
        end

        update_cookies(response.headers['set-cookie'])
        html = response.body
        match = html.match(/https:\/\/stc-zlogin\.zdn\.vn\/main-([\d\.]+)\.js/)
        version = match ? match[1] : '5.5.7'
        @logger.info "[Zalo::LoginService] Extracted version: #{version}"
        version
      rescue => e
        @logger.error "[Zalo::LoginService] Error in load_login_page: #{e.message}\n#{e.backtrace.join("\n")}"
        nil
      end
    end

    def get_login_info(version)
      @logger.info "[Zalo::LoginService] Getting login info for version: #{version}"
      url = 'https://id.zalo.me/account/logininfo'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        response = make_request(
          :post,
          'https://id.zalo.me/account/logininfo',
          headers: common_headers,
          body: URI.encode_www_form({ continue: 'https://zalo.me/pc', v: version })
        )

        @logger.info "[Zalo::LoginService] Response code: #{response.code}"
        @logger.info "[Zalo::LoginService] Response body: #{response.body}"
        @logger.info "[Zalo::LoginService] Response headers: #{response.headers.inspect}"

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to get login info: HTTP status #{response.code}"
          return nil
        end

        update_cookies(response.headers['set-cookie'])
        begin
          result = JSON.parse(response.body)
          return result['error_code'] == 0 ? result : nil
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in get_login_info: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in get_login_info: #{e.message}\n#{e.backtrace.join("\n")}"
        return nil
      end
    end

    def verify_client(version)
      @logger.info "[Zalo::LoginService] Verifying client for version: #{version}"
      url = 'https://id.zalo.me/account/verify-client'
      form_data = { type: 'device', continue: 'https://zalo.me/pc', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        response = make_request(
          :post,
          'https://id.zalo.me/account/verify-client',
          headers: common_headers,
          body: URI.encode_www_form({ type: 'device', continue: 'https://zalo.me/pc', v: version })
        )

        @logger.info "[Zalo::LoginService] Response code: #{response.code}"
        @logger.info "[Zalo::LoginService] Response body: #{response.body}"
        @logger.info "[Zalo::LoginService] Response headers: #{response.headers.inspect}"

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to verify client: HTTP status #{response.code}"
          return nil
        end

        update_cookies(response.headers['set-cookie'])
        begin
          result = JSON.parse(response.body)
          return result['error_code'] == 0 ? result : nil
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in verify_client: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in verify_client: #{e.message}\n#{e.backtrace.join("\n")}"
        return nil
      end
    end

    def generate_qr(version)
      @logger.info "[Zalo::LoginService] Generating QR code for version: #{version}"
      url = 'https://id.zalo.me/account/authen/qr/generate'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        response = make_request(
          :post,
          'https://id.zalo.me/account/authen/qr/generate',
          headers: common_headers,
          body: URI.encode_www_form({ continue: 'https://chat.zalo.me/', v: version })
        )

        @logger.info "[Zalo::LoginService] Response code: #{response.code}"
        @logger.info "[Zalo::LoginService] Response body: #{response.body}"
        @logger.info "[Zalo::LoginService] Response headers: #{response.headers.inspect}"

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to generate QR: HTTP status #{response.code}"
          return nil
        end

        update_cookies(response.headers['set-cookie'])
        begin
          result = JSON.parse(response.body)
          if result['error_code'] == -1003
            @logger.warn "[Zalo::LoginService] Session timed out (error -1003)"
            return nil
          end
          return result['error_code'] == 0 ? result['data'] : nil
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in generate_qr: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in generate_qr: #{e.message}\n#{e.backtrace.join("\n")}"
        return nil
      end
    end

    def make_request(method, path, headers: {}, body: nil)
      request = Typhoeus::Request.new(
        path,
        method: method,
        headers: headers.merge('Cookie' => cookie_string),
        body: body,
        followlocation: true,
        cookiefile: ':memory:',
        cookiejar: ':memory:',
        timeout: 5
      )

      response = request.run
      update_cookies(response.headers['set-cookie'])
      response
    end
    
    def waiting_scan(context, version, code, timeout = 60)
      url = 'https://id.zalo.me/account/authen/qr/waiting-scan'
      form_data = { code: code, continue: 'https://chat.zalo.me/', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        start_time = Time.now
        loop do
          return { 'error_code' => -99, 'error_message' => 'Timeout waiting for QR scan' } if Time.now - start_time > timeout
          response = client.post(url, form: form_data, headers: headers)
          return { 'error_code' => -1, 'error_message' => "HTTP Error: #{response.status}" } unless response.status == 200
          data = JSON.parse(response.body)
          return data unless data['error_code'] == 8
          sleep(2)
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in waiting_scan: #{e.message}"
        { 'error_code' => -1, 'error_message' => "Error: #{e.message}" }
      end
    end

    def waiting_confirm(client, version, code, timeout = 60)
      @logger.info "[Zalo::LoginService] Waiting for QR confirmation, code: #{code}"
      url = 'https://id.zalo.me/account/authen/qr/waiting-confirm'
      form_data = { code: code, gToken: '', gAction: 'CONFIRM_QR', continue: 'https://chat.zalo.me/', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        start_time = Time.now
        loop do
          if Time.now - start_time > timeout
            return { 'error_code' => -99, 'error_message' => 'Timeout waiting for confirmation' }
          end

          headers = common_headers
          headers['Cookie'] = cookie_string

          response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)

          if response.code != 200
            @logger.error "[Zalo::LoginService] Error in waiting_confirm: HTTP status #{response.code}"
            return { 'error_code' => -1, 'error_message' => "HTTP Error: #{response.code}" }
          end

          update_cookie_jar(response.headers['set-cookie'])

          begin
            data = JSON.parse(response.body)
          rescue JSON::ParserError => e
            @logger.error "[Zalo::LoginService] JSON parse error in waiting_confirm: #{e.message}"
            return { 'error_code' => -1, 'error_message' => "JSON parse error: #{e.message}" }
          end

          return data unless data['error_code'] == 8
          sleep(2)
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in waiting_confirm: #{e.message}"
        { 'error_code' => -1, 'error_message' => "Error: #{e.message}" }
      end
    end

    def check_session(client)
      @logger.info "[Zalo::LoginService] Checking session"
      url = 'https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html'
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        url = 'https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html'
        headers = common_headers
        headers['Cookie'] = cookie_string

        response = self.class.get(url, headers: headers)

        update_cookie_jar(response.headers['set-cookie'])

        if response.code != 200
          @logger.error "[Zalo::LoginService] Error in check_session: HTTP status #{response.code}"
          return nil
        end

        return response.success?
      rescue => e
        @logger.error "[Zalo::LoginService] Error in check_session: #{e.message}"
        false
      end
    end

    def get_user_info(client)
      @logger.info "[Zalo::LoginService] Getting user info"
      url = 'https://jr.chat.zalo.me/jr/userinfo'
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }
      begin
        url = 'https://jr.chat.zalo.me/jr/userinfo'
        headers = common_headers
        headers['Cookie'] = cookie_string

        response = self.class.get(url, headers: headers)

        update_cookie_jar(response.headers['set-cookie'])

        if response.code != 200
          @logger.error "[Zalo::LoginService] Error in get_user_info: HTTP status #{response.code}"
          return nil
        end

        begin
          return JSON.parse(response.body)
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in get_user_info: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in get_user_info: #{e.message}"
        nil
      end
    end

    def update_cookie_jar(set_cookie_header)
      return unless set_cookie_header
      Array(set_cookie_header).each do |cookie_str|
        @cookie_jar.add_cookies(cookie_str)
        @logger.info "[Zalo::LoginService] Added cookie: #{cookie_str}"
      end
      @logger.info "[Zalo::LoginService] Current cookie jar: #{cookie_string}"
    end

    def restore_cookie_jar(cookie_hash)
      @cookie_jar = HTTParty::CookieHash.new
      cookie_hash.each { |key, value| @cookie_jar[key] = value }
      @logger.info "[Zalo::LoginService] Restored cookie jar: #{cookie_string}"
    end

    def cookie_string
      cookies = @cookie_jar.to_cookie_string
      @logger.info "[Zalo::LoginService] Cookie string: #{cookies}"
      cookies
    end

    def validate_cookies
      required_cookies = ['_zlang', '__zi', 'zpdid', 'zlogin_session']
      missing_cookies = required_cookies.reject { |key| @cookie_jar[key] }
      if missing_cookies.any?
        @logger.warn "[Zalo::LoginService] Missing required cookies: #{missing_cookies.join(', ')}"
        return false
      end
      true
    end

    def handle_scan_error(result, qr_code_id)
      case result['error_code']
      when 8
        { success: false, error: 'QR code not scanned', event_type: QRCallbackEventType::QR_CODE_GENERATED }
      when -13
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: 'QR code declined', event_type: QRCallbackEventType::QR_CODE_DECLINED }
      else
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: "Unknown error: #{result['error_message']}", event_type: QRCallbackEventType::QR_CODE_EXPIRED }
      end
    end

    def common_headers
      {
        'accept' => '*/*',
        'accept-language' => 'vi-VN,vi;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5',
        'content-type' => 'application/x-www-form-urlencoded',
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'sec-ch-ua' => '"Chromium";v="136", "Google Chrome";v="136", "Not.A/Brand";v="99"',
        'sec-ch-ua-mobile' => '?0',
        'sec-ch-ua-platform' => '"Windows"',
        'sec-fetch-dest' => 'empty',
        'sec-fetch-mode' => 'cors',
        'sec-fetch-site' => 'same-origin',
        'user-agent' => DEFAULT_USER_AGENT,
        'Connection' => 'keep-alive',
        'priority' => 'u=1, i'
      }
    end

    def handle_confirm_error(result, qr_code_id)
      error_type = result['error_code'] == -13 ? QRCallbackEventType::QR_CODE_DECLINED : QRCallbackEventType::QR_CODE_EXPIRED
      @redis.del("zalo_qr_#{qr_code_id}")
      { success: false, error: error_message, event_type: error_type }
    end

    def notify_callback(callback, qr_code_id, event_type, message, data = nil)
      return { success: false, error: message, event_type: event_type } unless callback

      begin
        callback.call({
                        type: event_type,
                        qr_code_id: qr_code_id,
                        message: message,
                        data: data
                      })
      rescue => e
        @logger.error "[Zalo::LoginService] Callback Error: #{e.message}\n#{e.backtrace.join("\n")}"
      end

      { success: false, error: message, event_type: event_type }
    end

    def update_cookies(set_cookie)
      return unless set_cookie
      Array(set_cookie).each do |cookie|
        name, value = cookie.split(';').first.split('=')
        @cookies[name] = value
        @logger.info "[Zalo::LoginService] Added cookie: #{name}=#{value}"
      end
    end

    def cookie_string
      cookies = @cookies.map { |k, v| "#{k}=#{v}" }.join('; ')
      @logger.info "[Zalo::LoginService] Cookie string: #{cookies}"
      cookies
    end
    def with_timeout(timeout_seconds, &block)
      result = nil
      begin
        Timeout.timeout(timeout_seconds) do
          result = yield
        end
      rescue Timeout::Error
        result = { 'error_code' => -99, 'error_message' => "Operation timed out after #{timeout_seconds} seconds" }
      end
      result
    end
  end
end
