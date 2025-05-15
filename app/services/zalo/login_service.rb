require 'httparty'
require 'json'
require 'securerandom'
require 'redis'
require 'timeout'
require 'logger'
require_relative 'zalo_url_manager'
require_relative 'encryption_service'

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
    include HTTParty

    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36'

    attr_reader :channel_zalo, :imei, :cookie_jar, :logger

    def initialize(channel_zalo_instance = nil)
      @logger = ::Logger.new(STDOUT) # Explicitly use standard Ruby Logger
      @logger.level = ::Logger::INFO
      @channel_zalo = channel_zalo_instance
      @imei = channel_zalo_instance&.imei || SecureRandom.uuid
      @cookie_jar = HTTParty::CookieHash.new
      @encryption_service = Zalo::ZaloCryptoHelper.new(@channel_zalo)
      @redis = Redis.new
      self.class.headers({
                           'User-Agent' => DEFAULT_USER_AGENT,
                           'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
                           'Accept-Language' => 'vi-VN,vi;q=0.9'
                         })
      self.class.follow_redirects(true)
    end

    def generate_qr_code
      @logger.info "[Zalo::LoginService] Generating QR code for IMEI: #{@imei}"

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

        qr_code_id = SecureRandom.uuid
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
        response = self.class.get(url, headers: { 'Cookie' => cookie_string })
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
        @logger.error "[Zalo::LoginService] QR Check Error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error checking QR code: #{e.message}" }
      end
    end

    def check_qr_code_scan_with_callback(qr_code_id, callback = nil)
      @logger.info "[Zalo::LoginService] Checking QR code status for ID: #{qr_code_id} with callback"

      begin
        qr_session = @redis.get("zalo_qr_#{qr_code_id}")
        return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'QR session not found or expired') unless qr_session

        qr_data = JSON.parse(qr_session)
        restore_cookie_jar(qr_data['context']['cookie_jar'])

        scan_result = with_timeout(60) do
          waiting_scan(qr_data['context'], qr_data['version'], qr_data['code'])
        end

        case scan_result['error_code']
        when 0
          notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_SCANNED, 'QR code scanned successfully', {
            avatar: scan_result.dig('data', 'avatar'),
            display_name: scan_result.dig('data', 'display_name')
          })

          avatar = scan_result.dig('data', 'avatar')
          display_name = scan_result.dig('data', 'display_name')

          if avatar.present? && display_name.present?
            existing = Channel::Zalo.find_by(avatar: avatar, display_name: display_name)
            return notify_callback(callback, qr_code_id, QRCallbackEventType::ACCOUNT_EXISTS, 'Account already exists') if existing
          end
        when 8
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_GENERATED, 'QR code not scanned yet')
        when -13
          @redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_DECLINED, 'QR code declined')
        when -99
          @redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Timeout waiting for QR scan')
        else
          @redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, "Unknown error: #{scan_result['error_code']}")
        end

        confirm_result = with_timeout(60) do
          waiting_confirm(qr_data['context'], qr_data['version'], qr_data['code'])
        end

        case confirm_result['error_code']
        when 0
        when -13
          @redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_DECLINED, 'QR code declined')
        when -99
          @redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Timeout waiting for confirmation')
        else
          @redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Confirm error')
        end

        session = check_session(qr_data['context'])
        return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Failed to check session') unless session

        user_info_resp = get_user_info(qr_data['context'])
        return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Failed to get user info') unless user_info_resp&.dig('data', 'logged')

        user_info = {
          name: user_info_resp['data']['info']['name'],
          avatar: user_info_resp['data']['info']['avatar']
        }

        zalo_account = Channel::Zalo.new(imei: @imei, api_type: 30, api_version: 655)
        encrypt_params = @encryption_service.get_encrypt_param(zalo_account, true, 'getlogininfo')
        encrypt_params[:params_dict]['nretry'] = '0'
        url = @encryption_service.make_url(zalo_account, GET_LOGIN_INFO, encrypt_params[:params_dict])
        response = self.class.get(url, headers: { 'Cookie' => cookie_string })
        parsed = JSON.parse(response.body)
        return notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Failed to get login info from Zalo API') unless parsed['data'].present?

        decrypted = JSON.parse(@encryption_service.decrypt_resp(encrypt_params[:enk], parsed['data']))
        return notify_callback(cmdcallback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, 'Invalid login information') unless decrypted&.dig('data', 'uid').present?

        zalo_account = Channel::Zalo.new(
          account_id: decrypted['data']['uid'],
          display_name: user_info[:name],
          avatar: user_info[:avatar],
          secret_key: decrypted['data']['zpw_enk'],
          cookie: cookie_string,
          imei: @imei,
          phone: decrypted['data']['phone_number'].present? ? "0#{decrypted['data']['phone_number'][2..-1]}" : "",
          api_type: 30,
          api_version: 655,
          language: 'vi'
        )

        existing = Channel::Zalo.find_by(account_id: zalo_account.account_id)
        return notify_callback(callback, qr_code_id, QRCallbackEventType::ACCOUNT_EXISTS, 'Account already exists') if existing

        zalo_account.save!
        @redis.del("zalo_qr_#{qr_code_id}")

        user_info[:phone] = zalo_account.phone
        notify_callback(callback, qr_code_id, QRCallbackEventType::GOT_LOGIN_INFO, 'Login successful', user_info)

        {
          success: true,
          event_type: QRCallbackEventType::GOT_LOGIN_INFO,
          user_info: user_info
        }
      rescue => e
        @logger.error "[Zalo::LoginService] QR Check Error: #{e.message}\n#{e.backtrace.join("\n")}"
        notify_callback(callback, qr_code_id, QRCallbackEventType::QR_CODE_EXPIRED, "Error checking QR code: #{e.message}")
        { success: false, error: "Error checking QR code: #{e.message}" }
      end
    end

    def load_login_page
      begin
        url = 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
        response = self.class.get(url)

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to load login page: HTTP status #{response.code}"
          return nil
        end

        update_cookie_jar(response.headers['set-cookie'])
        html = response.body
        match = html.match(/https:\/\/stc-zlogin\.zdn\.vn\/main-([\d\.]+)\.js/)
        match ? match[1] : nil
      rescue => e
        @logger.error "[Zalo::LoginService] Error in load_login_page: #{e.message}"
        return nil
      end
    end

    def get_login_info(version)
      begin
        url = 'https://id.zalo.me/account/logininfo'
        form_data = { continue: 'https://zalo.me/pc', v: version }
        response = self.class.post(url, body: URI.encode_www_form(form_data), headers: {
          'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
        })

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to get login info: HTTP status #{response.code}"
          return nil
        end

        update_cookie_jar(response.headers['set-cookie'])

        begin
          result = JSON.parse(response.body)
          return result['error_code'] == 0 ? result : nil
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in get_login_info: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in get_login_info: #{e.message}"
        return nil
      end
    end

    def verify_client(version)
      begin
        url = 'https://id.zalo.me/account/verify-client'
        form_data = { type: 'device', continue: 'https://zalo.me/pc', v: version }

        headers = {
          'dnt' => '1',
          'origin' => 'https://id.zalo.me',
          'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        }

        response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to verify client: HTTP status #{response.code}"
          return nil
        end

        update_cookie_jar(response.headers['set-cookie'])

        begin
          result = JSON.parse(response.body)
          return result['error_code'] == 0 ? result : nil
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in verify_client: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in verify_client: #{e.message}"
        return nil
      end
    end

    def generate_qr(version)
      begin
        url = 'https://id.zalo.me/account/authen/qr/generate'
        form_data = {
          continue: 'https://zalo.me/pc',
          v: version
        }
        headers = {
          'dnt' => '1',
          'origin' => 'https://id.zalo.me',
          'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
          'Cookie' => 'zpdid=4H3vbbNtg3iG4f2KKlF0E1uHb9PPySKm; _zlang=vn; _ga=GA1.2.951217436.1747297305; _gid=GA1.2.558268858.1747297305; nl_b04af40bb0e193acf8a9877592394ada=tzaoLC8i6lt9r31Jn2uRzCBGCKRVSNwnazSJ3JenVG; _gat=1; zlogin_session=kW4JGLyjCnIxFnDDLXTbH-Tj1K1K46D5vsqRLmvGRLsiBmjV0b1gNQmk3KCTMcfHVG'
        }

        response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)

        if response.code != 200
          @logger.error "[Zalo::LoginService] Failed to generate QR: HTTP status #{response.code}"
          return nil
        end

        update_cookie_jar(response.headers['set-cookie'])

        begin
          result = JSON.parse(response.body)
          return result['error_code'] == 0 ? result['data'] : nil
        rescue JSON::ParserError => e
          @logger.error "[Zalo::LoginService] JSON parse error in generate_qr: #{e.message}"
          return nil
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in generate_qr: #{e.message}"
        return nil
      end
    end

    def waiting_scan(context, version, code, timeout = 60)
      url = 'https://id.zalo.me/account/authen/qr/waiting-scan'
      form_data = { code: code, continue: 'https://chat.zalo.me/', v: version }

      begin
        start_time = Time.now

        loop do
          if Time.now - start_time > timeout
            return { 'error_code' => -99, 'error_message' => 'Timeout waiting for QR scan' }
          end

          headers = {
            'dnt' => '1',
            'origin' => 'https://id.zalo.me',
            'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
            'Cookie' => '_zlang=vn; __zi=2000.QOBlzDCV2uGerkFzm09HqsVHvll30r7IAzNZ-eW0KjSeqEFwD3G.1; __zi-legacy=2000.QOBlzDCV2uGerkFzm09HqsVHvll30r7IAzNZ-eW0KjSeqEFwD3G.1; zpdid=4H3vbr3mgJuI7P6HKFp1FH4OafHHzCSp; _ga=GA1.2.1229565104.1747241478; _gid=GA1.2.295553455.1747241478; _gat=1; zlogin_session=kW4JGLyjCnIxFnDDLXTbH-Tj1K1L5614xMWOLWHLRbocAWXU25LfNAOh3a8NNsbGVG'
          }

          response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)

          if response.code != 200
            @logger.error "[Zalo::LoginService] Error in waiting_scan: HTTP status #{response.code}"
            return { 'error_code' => -1, 'error_message' => "HTTP Error: #{response.code}" }
          end

          update_cookie_jar(response.headers['set-cookie'])

          begin
            data = JSON.parse(response.body)
          rescue JSON::ParserError => e
            @logger.error "[Zalo::LoginService] JSON parse error in waiting_scan: #{e.message}"
            return { 'error_code' => -1, 'error_message' => "JSON parse error: #{e.message}" }
          end

          return data unless data['error_code'] == 8

          sleep(2)
        end
      rescue => e
        @logger.error "[Zalo::LoginService] Error in waiting_scan: #{e.message}"
        return { 'error_code' => -1, 'error_message' => "Error: #{e.message}" }
      end
    end

    def waiting_confirm(context, version, code, timeout = 60)
      url = 'https://id.zalo.me/account/authen/qr/waiting-confirm'
      form_data = { code: code, gToken: '', gAction: 'CONFIRM_QR', continue: 'https://chat.zalo.me/', v: version }

      begin
        start_time = Time.now
        @logger.info "[Zalo::LoginService] Waiting for confirmation on mobile device..."

        loop do
          if Time.now - start_time > timeout
            return { 'error_code' => -99, 'error_message' => 'Timeout waiting for confirmation' }
          end

          headers = {
            'dnt' => '1',
            'origin' => 'https://id.zalo.me',
            'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
            'Cookie' => '_zlang=vn; __zi=2000.QOBlzDCV2uGerkFzm09HqsVHvll30r7IAzNZ-eW0KjSeqEFwD3G.1; __zi-legacy=2000.QOBlzDCV2uGerkFzm09HqsVHvll30r7IAzNZ-eW0KjSeqEFwD3G.1; zpdid=4H3vbr3mgJuI7P6HKFp1FH4OafHHzCSp; _ga=GA1.2.1229565104.1747241478; _gid=GA1.2.295553455.1747241478; _gat=1; zlogin_session=kW4JGLyjCnIxFnDDLXTbH-Tj1K1L5614xMWOLWHLRbocAWXU25LfNAOh3a8NNsbGVG'
          }

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
        return { 'error_code' => -1, 'error_message' => "Error: #{e.message}" }
      end
    end

    def check_session(context)
      begin
        url = 'https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html'
        response = self.class.get(url, headers: {
          'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
        })

        update_cookie_jar(response.headers['set-cookie'])

        if response.code != 200
          @logger.error "[Zalo::LoginService] Error in check_session: HTTP status #{response.code}"
          return nil
        end

        return response.success?
      rescue => e
        @logger.error "[Zalo::LoginService] Error in check_session: #{e.message}"
        return nil
      end
    end

    def get_user_info(context)
      begin
        url = 'https://jr.chat.zalo.me/jr/userinfo'
        response = self.class.get(url, headers: {
          'dnt' => '1', 'origin' => 'https://id.zalo.me', 'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
        })

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
        return nil
      end
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
        { success: false, error: 'QR code not scanned', event_type: QRCallbackEventType::QR_CODE_GENERATED }
      when -13
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: 'QR code declined', event_type: QRCallbackEventType::QR_CODE_DECLINED }
      when -99
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: 'Timeout waiting for QR scan', event_type: QRCallbackEventType::QR_CODE_EXPIRED }
      else
        @redis.del("zalo_qr_#{qr_code_id}")
        { success: false, error: "Unknown error: #{result['error_code']}", event_type: QRCallbackEventType::QR_CODE_EXPIRED }
      end
    end

    def handle_confirm_error(result, qr_code_id)
      case result['error_code']
      when -13
        error_message = 'QR code declined'
        error_type = QRCallbackEventType::QR_CODE_DECLINED
      when -99
        error_message = 'Timeout waiting for confirmation'
        error_type = QRCallbackEventType::QR_CODE_EXPIRED
      else
        error_message = "Confirm error: #{result['error_code']}"
        error_type = QRCallbackEventType::QR_CODE_EXPIRED
      end

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
