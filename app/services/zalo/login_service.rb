require 'httparty'
require 'json'
require 'securerandom'
require 'redis'

module Zalo
  class LoginService
    include Zalo::URLManager::Login

    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36'

    attr_reader :channel_zalo, :imei, :cookie_jar

    def initialize(channel_zalo_instance = nil)
      @channel_zalo = channel_zalo_instance
      @imei = channel_zalo_instance&.imei || SecureRandom.uuid
      @cookie_jar = HTTParty::CookieHash.new
      @encryption_service = Zalo::EncryptionService.new(channel_zalo_instance)
      @redis = Redis.new
      @http_client_options = {
        headers: {
          'User-Agent' => DEFAULT_USER_AGENT,
          'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
          'Accept-Language' => 'vi-VN,vi;q=0.9'
        },
        follow_redirects: true
      }
    end

    def generate_qr_code
      Rails.logger.info "[Zalo::LoginService] Generating QR code for IMEI: #{@imei}"

      begin
        # Step 1: Load login page to get version
        version = load_login_page
        return { success: false, error: 'Failed to load login page' } unless version

        # Step 2: Get login info
        get_login_info(version)

        # Step 3: Verify client
        verify_client(version)

        # Step 4: Generate QR code
        qr_data = generate_qr(version)
        return { success: false, error: 'Failed to generate QR code' } unless qr_data

        qr_code_id = SecureRandom.hex(10)
        base64_image = qr_data['image'].sub('data:image/png;base64,', '')

        # Store QR session in Redis
        @redis.setex("zalo_qr_#{qr_code_id}", 300, {
          context: { cookie_jar: @cookie_jar.to_h },
          version: version,
          code: qr_data['code'],
          timestamp: Time.now.to_i
        }.to_json)

        { success: true, qr_code_id: qr_code_id, qr_image_url: "data:image/png;base64,#{base64_image}" }
      rescue => e
        Rails.logger.error "[Zalo::LoginService] QR Generation Error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error generating QR code: #{e.message}" }
      end
    end

    def check_qr_code_scan(qr_code_id, user_id)
      Rails.logger.info "[Zalo::LoginService] Checking QR code status for ID: #{qr_code_id}"

      begin
        qr_session = @redis.get("zalo_qr_#{qr_code_id}")
        return { success: false, error: 'QR session not found or expired' } unless qr_session

        qr_data = JSON.parse(qr_session)
        restore_cookie_jar(qr_data['context']['cookie_jar'])

        # Step 1: Wait for QR scan
        scan_result = waiting_scan(qr_data['context'], qr_data['version'], qr_data['code'])
        return handle_scan_error(scan_result, qr_code_id) unless scan_result['error_code'] == 0

        # Step 2: Wait for confirmation
        confirm_result = waiting_confirm(qr_data['context'], qr_data['version'], qr_data['code'])
        return handle_confirm_error(confirm_result, qr_code_id) unless confirm_result['error_code'] == 0

        # Step 3: Check session
        session = check_session(qr_data['context'])
        return { success: false, error: 'Failed to check session' } unless session

        # Step 4: Get user info
        user_info_resp = get_user_info(qr_data['context'])
        return { success: false, error: 'Failed to get user info' } unless user_info_resp&.dig('data', 'logged')

        user_info = {
          name: user_info_resp['data']['info']['name'],
          avatar: user_info_resp['data']['info']['avatar']
        }

        # Step 5: Get detailed login info
        zalo_account = Channel::Zalo.new(imei: @imei, api_type: 30, api_version: 655)
        encrypt_params = @encryption_service.get_encrypt_param(zalo_account, true, 'getlogininfo')
        url = @encryption_service.make_url(zalo_account, GET_LOGIN_INFO, encrypt_params[:params_dict])
        response = HTTParty.get(url, headers: { 'Cookie' => cookie_string }.merge(@http_client_options[:headers]))
        parsed = JSON.parse(response.body)
        decrypted = JSON.parse(@encryption_service.decrypt_resp(encrypt_params[:enk], parsed['data']))

        zalo_account = Channel::Zalo.new(
          account_id: decrypted['data']['uid'],
          display_name: user_info[:name],
          avatar: user_info[:avatar],
          secret_key: decrypted['data']['zpw_enk'],
          cookie: cookie_string,
          imei: @imei,
          phone: "0#{decrypted['data']['phone_number'][2..-1]}",
          user_id: user_id,
          api_type: 30,
          api_version: 655,
          language: 'vi'
        )

        existing = Channel::Zalo.find_by(account_id: zalo_account.account_id)
        return { success: false, error: 'Account already exists' } if existing

        zalo_account.save!
        @redis.del("zalo_qr_#{qr_code_id}")

        { success: true, event_type: :got_login_info, user_info: user_info.merge(phone: zalo_account.phone) }
      rescue => e
        Rails.logger.error "[Zalo::LoginService] QR Check Error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error checking QR code: #{e.message}" }
      end
    end

    private

    def load_login_page
      url = 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      response = HTTParty.get(url, @http_client_options)
      update_cookie_jar(response.headers['set-cookie'])
      html = response.body
      match = html.match(/https:\/\/stc-zlogin\.zdn\.vn\/main-([\d\.]+)\.js/)
      match ? match[1] : nil
    end

    def get_login_info(version)
      url = 'https://id.zalo.me/account/logininfo'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      response = HTTParty.post(url, body: URI.encode_www_form(form_data), headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      JSON.parse(response.body)
    end

    def verify_client(version)
      url = 'https://id.zalo.me/account/verify-client'
      form_data = { type: 'device', continue: 'https://zalo.me/pc', v: version }
      response = HTTParty.post(url, body: URI.encode_www_form(form_data), headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      JSON.parse(response.body)
    end

    def generate_qr(version)
      url = 'https://id.zalo.me/account/authen/qr/generate'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      response = HTTParty.post(url, body: URI.encode_www_form(form_data), headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      JSON.parse(response.body)['data']
    end

    def waiting_scan(context, version, code)
      url = 'https://id.zalo.me/account/authen/qr/waiting-scan'
      form_data = { code: code, continue: 'https://chat.zalo.me/', v: version }
      response = HTTParty.post(url, body: URI.encode_www_form(form_data), headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      data = JSON.parse(response.body)
      data['error_code'] == 8 ? waiting_scan(context, version, code) : data
    end

    def waiting_confirm(context, version, code)
      url = 'https://id.zalo.me/account/authen/qr/waiting-confirm'
      form_data = { code: code, gToken: '', gAction: 'CONFIRM_QR', continue: 'https://chat.zalo.me/', v: version }
      response = HTTParty.post(url, body: URI.encode_www_form(form_data), headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      data = JSON.parse(response.body)
      data['error_code'] == 8 ? waiting_confirm(context, version, code) : data
    end

    def check_session(context)
      url = 'https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html'
      response = HTTParty.get(url, headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      response.success? ? true : nil
    end

    def get_user_info(context)
      url = 'https://jr.chat.zalo.me/jr/userinfo'
      response = HTTParty.get(url, headers: {
        'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }.merge(@http_client_options[:headers]))
      update_cookie_jar(response.headers['set-cookie'])
      JSON.parse(response.body)
    end

    def update_cookie_jar(set_cookie_header)
      return unless set_cookie_header
      Array(set_cookie_header).each { |cookie_str| @cookie_jar.add_cookies(cookie_str) }
    end

    def restore_cookie_jar(cookie_hash)
      @cookie_jar = HTTParty::CookieHash.new
      cookie_hash.each { |key, value| @cookie_jar[key] = value }
    end

    def cookie_string
      @cookie_jar.to_cookie_string
    end

    def handle_scan_error(result, qr_code_id)
      case result['error_code']
      when 8
        { success: false, error: 'QR code not scanned' }
      when -13
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: 'QR code declined' }
      else
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: "Unknown error: #{result['error_code']}" }
      end
    end

    def handle_confirm_error(result, qr_code_id)
      error_type = result['error_code'] == -13 ? 'QR code declined' : 'Confirm error'
      @redis.del("zalo_qr_#{qr_code_id}")
      { success: false, error: error_type }
    end
  end
end