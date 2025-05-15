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
    include HTTParty
    include Zalo::URLManager::Login

    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36'

    attr_reader :channel_zalo, :imei, :cookies, :logger, :redis

    def initialize(channel_zalo_instance = nil, redis: Redis.new)
      @logger = ::Logger.new(STDOUT)
      @logger.level = ::Logger::INFO
      @channel_zalo = channel_zalo_instance
      @imei = channel_zalo_instance&.imei || SecureRandom.uuid
      @cookies = {}
      @redis = redis
      @encryption_service = Zalo::ZaloCryptoHelper.new(@channel_zalo)
      self.class.headers({
                           'User-Agent' => DEFAULT_USER_AGENT,
                           'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
                           'Accept-Language' => 'vi-VN,vi;q=0.9',
                           'Origin' => 'https://id.zalo.me',
                           'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
                         })
      self.class.follow_redirects(true)
      # Configure HTTParty to use the same Logger instance for HTTP request logging
      self.class.logger(@logger, :info, :curl)
    end

    def generate_qr_code(&callback)
      logger.info "[Zalo::LoginService] Generating QR code for IMEI: #{imei}"

      begin
        cookies.clear
        version = load_login_page
        return failure_result('Không thể lấy phiên bản API đăng nhập', 'SERVER_ERROR') unless version

        get_login_info(version)
        verify_client(version)
        qr_data = generate_qr(version)
        unless qr_data && qr_data['code'] && qr_data['image']
          logger.error "[Zalo::LoginService] Invalid QR data: #{qr_data.inspect}"
          return failure_result("Không thể tạo mã QR. Phản hồi: #{qr_data.to_json}", 'SERVER_ERROR')
        end

        qr_code_id = SecureRandom.uuid
        base64_image = qr_data['image'].sub('data:image/png;base64,', '')
        qr_code_data = {
          context: { cookies: cookies.dup },
          version: version,
          code: qr_data['code'],
          qr_code_id: qr_code_id
        }

        redis.setex("zalo_qr_#{qr_code_id}", 60, qr_code_data.to_json)

        if callback
          callback.call({
                          type: QRCallbackEventType::QR_CODE_GENERATED,
                          message: 'QR code generated',
                          data: { code: qr_data['code'], image: base64_image }
                        })
        end

        success_result({
                         qr_code_id: qr_code_id,
                         base64_image: base64_image
                       })
      rescue => e
        logger.error "[Zalo::LoginService] QR Generation Error: #{e.message}\n#{e.backtrace.join('\n')}"
        failure_result("Error add Zalo account: #{e.message}", 'SERVER_ERROR')
      end
    end

    def check_qr_code_scan(qr_code_id, user_id, &callback)
      logger.info "[Zalo::LoginService] Checking QR code status for ID: #{qr_code_id}"

      begin
        qr_session = redis.get("zalo_qr_#{qr_code_id}")
        unless qr_session
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 "QRCodeId #{qr_code_id} không hợp lệ hoặc đã hết hạn", 'QR_EXPIRED')
        end

        qr_data = JSON.parse(qr_session)
        restore_cookies(qr_data['context']['cookies'])

        scan_result = with_timeout(60) { waiting_scan(qr_data['version'], qr_data['code']) }
        case scan_result['error_code']
        when 0
          if callback
            callback.call({
                            type: QRCallbackEventType::QR_CODE_SCANNED,
                            message: 'QR code scanned successfully',
                            data: {
                              avatar: scan_result['data']['avatar'],
                              display_name: scan_result['data']['display_name']
                            }
                          })
          end

          existing = Channel::Zalo.find_by(
            avatar: scan_result['data']['avatar'],
            display_name: scan_result['data']['display_name']
          )
          if existing
            return notify_callback(callback, QRCallbackEventType::ACCOUNT_EXISTS,
                                   'Account already exists', 'ACCOUNT_ALREADY_EXISTS')
          end
        when 8
          return notify_callback(callback, QRCallbackEventType::QR_CODE_GENERATED,
                                 'Mã QR chưa được quét', 'QR_NOT_SCANNED')
        when -13
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_DECLINED,
                                 'Mã QR bị từ chối', 'QR_DECLINED')
        when -99
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 'Timeout waiting for QR scan', 'QR_EXPIRED')
        else
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 "Lỗi không xác định: error_code = #{scan_result['error_code']}", 'UNKNOWN_ERROR')
        end

        confirm_result = with_timeout(60) { waiting_confirm(qr_data['version'], qr_data['code']) }
        unless confirm_result['error_code'] == 0
          type = confirm_result['error_code'] == -13 ? QRCallbackEventType::QR_CODE_DECLINED : QRCallbackEventType::QR_CODE_EXPIRED
          message = confirm_result['error_code'] == -13 ? 'Xác nhận bị từ chối' : 'Lỗi khi xác nhận QR'
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, type, message, 'CONFIRM_ERROR')
        end

        session = check_session
        unless session
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 'Không thể kiểm tra phiên đăng nhập', 'SESSION_ERROR')
        end

        user_info_resp = get_user_info
        unless user_info_resp&.dig('data', 'logged')
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 'Không thể lấy thông tin người dùng hoặc đăng nhập thất bại', 'USERINFO_ERROR')
        end

        user_info = {
          name: user_info_resp['data']['info']['name'],
          avatar: user_info_resp['data']['info']['avatar']
        }

        cookie = cookie_string
        zalo_account = Channel::Zalo.new(imei: imei, api_type: 30, api_version: 655)
        encrypt_params = encryption_service.get_encrypt_param(zalo_account, true, 'getlogininfo')
        encrypt_params[:params_dict]['nretry'] = '0'
        url = encryption_service.make_url(zalo_account, GET_LOGIN_INFO, encrypt_params[:params_dict])
        response = self.class.get(url, headers: { 'Cookie' => cookie })
        parsed = JSON.parse(response.body)
        unless parsed['data']
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 'Failed to get login info from Zalo API', 'LOGIN_INFO_ERROR')
        end

        decrypted = JSON.parse(encryption_service.decrypt_resp(encrypt_params[:enk], parsed['data']))
        unless decrypted&.dig('data', 'uid')
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                                 'Invalid login information', 'INVALID_LOGIN_INFO')
        end

        zalo_account = Channel::Zalo.new(
          account_id: decrypted['data']['uid'],
          display_name: user_info[:name],
          avatar: user_info[:avatar],
          secret_key: decrypted['data']['zpw_enk'],
          cookie: cookie,
          imei: imei,
          user_id: user_id,
          phone: decrypted['data']['phone_number'] ? "0#{decrypted['data']['phone_number'][2..-1]}" : '',
          api_type: 30,
          api_version: 655,
          language: 'vi'
        )

        existing = Channel::Zalo.find_by(account_id: zalo_account.account_id)
        if existing
          redis.del("zalo_qr_#{qr_code_id}")
          return notify_callback(callback, QRCallbackEventType::ACCOUNT_EXISTS,
                                 'Account already exists', 'ACCOUNT_ALREADY_EXISTS')
        end

        zalo_account.save!
        redis.del("zalo_qr_#{qr_code_id}")

        user_info[:phone] = zalo_account.phone
        if callback
          callback.call({
                          type: QRCallbackEventType::GOT_LOGIN_INFO,
                          message: 'Login successful',
                          data: user_info
                        })
        end

        success_result({
                         event_type: QRCallbackEventType::GOT_LOGIN_INFO,
                         user_info: user_info
                       })
      rescue => e
        logger.error "[Zalo::LoginService] QR Check Error: #{e.message}\n#{e.backtrace.join('\n')}"
        redis.del("zalo_qr_#{qr_code_id}") if redis.get("zalo_qr_#{qr_code_id}")
        notify_callback(callback, QRCallbackEventType::QR_CODE_EXPIRED,
                        "Error checking QR code: #{e.message}", 'SERVER_ERROR')
      end
    end

    private

    def load_login_page
      url = 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      headers = {
        'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language' => 'vi-VN,vi;q=0.9',
        'Cache-Control' => 'max-age=0',
        'Sec-Fetch-Dest' => 'document',
        'Sec-Fetch-Mode' => 'navigate',
        'Sec-Fetch-Site' => 'same-site',
        'Sec-Fetch-User' => '?1',
        'Upgrade-Insecure-Requests' => '1',
        'Referer' => 'https://chat.zalo.me/',
        'Referrer-Policy' => 'strict-origin-when-cross-origin'
      }

      response = self.class.get(url, headers: headers)
      update_cookies(response.headers['set-cookie'])
      html = response.body
      match = html.match(/https:\/\/stc-zlogin\.zdn\.vn\/main-([\d\.]+)\.js/)
      match ? match[1] : nil
    rescue => e
      logger.error "[Zalo::LoginService] Error in load_login_page: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def get_login_info(version)
      url = 'https://id.zalo.me/account/logininfo'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => cookie_string
      }

      response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)
      update_cookies(response.headers['set-cookie'])
      JSON.parse(response.body)
    rescue => e
      logger.error "[Zalo::LoginService] Error in get_login_info: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def verify_client(version)
      url = 'https://id.zalo.me/account/verify-client'
      form_data = { type: 'device', continue: 'https://zalo.me/pc', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => cookie_string
      }

      response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)
      update_cookies(response.headers['set-cookie'])
      JSON.parse(response.body)
    rescue => e
      logger.error "[Zalo::LoginService] Error in verify_client: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def generate_qr(version)
      url = 'https://id.zalo.me/account/authen/qr/generate'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => '
zpdid=4H3vbbNtg3iG4f2KKlF0E1uHb9PPySKm; _zlang=vn; _ga=GA1.2.951217436.1747297305; _gid=GA1.2.558268858.1747297305; nl_b04af40bb0e193acf8a9877592394ada=tzaoLC8i6lt9r35QpYmSySBICqFVStoqazKH23enVG; zlogin_session=kW4JGLyjCnIxFnDDLXTbH-Tj1K1L6Mb7uM4HLGXSPr-g8m5T15nWNweY1q4RLc1JVG; _gat=1'
      }

      response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)
      update_cookies(response.headers['set-cookie'])
      data = JSON.parse(response.body)
      data['data'] if data['error_code'] == 0
    rescue => e
      logger.error "[Zalo::LoginService] Error in generate_qr: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def waiting_scan(version, code)
      url = 'https://id.zalo.me/account/authen/qr/waiting-scan'
      form_data = { code: code, continue: 'https://chat.zalo.me/', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => cookie_string
      }

      response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)
      update_cookies(response.headers['set-cookie'])
      data = JSON.parse(response.body)
      data['error_code'] == 8 ? waiting_scan(version, code) : data
    rescue => e
      logger.error "[Zalo::LoginService] Error in waiting_scan: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def waiting_confirm(version, code)
      url = 'https://id.zalo.me/account/authen/qr/waiting-confirm'
      form_data = { code: code, gToken: '', gAction: 'CONFIRM_QR', continue: 'https://chat.zalo.me/', v: version }
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => cookie_string
      }

      logger.info "[Zalo::LoginService] Vui lòng xác nhận trên điện thoại"
      response = self.class.post(url, body: URI.encode_www_form(form_data), headers: headers)
      update_cookies(response.headers['set-cookie'])
      data = JSON.parse(response.body)
      data['error_code'] == 8 ? waiting_confirm(version, code) : data
    rescue => e
      logger.error "[Zalo::LoginService] Error in waiting_confirm: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def check_session
      url = 'https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html'
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => cookie_string
      }

      response = self.class.get(url, headers: headers)
      update_cookies(response.headers['set-cookie'])
      response.success?
    rescue => e
      logger.error "[Zalo::LoginService] Error in check_session: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def get_user_info
      url = 'https://jr.chat.zalo.me/jr/userinfo'
      headers = {
        'dnt' => '1',
        'origin' => 'https://id.zalo.me',
        'referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Cookie' => cookie_string
      }

      response = self.class.get(url, headers: headers)
      update_cookies(response.headers['set-cookie'])
      JSON.parse(response.body)
    rescue => e
      logger.error "[Zalo::LoginService] Error in get_user_info: #{e.message}"
      raise ZaloApiError, "Lỗi khi gửi yêu cầu HTTP: #{e.message}"
    end

    def update_cookies(set_cookie_header)
      return unless set_cookie_header

      Array(set_cookie_header).each do |cookie_str|
        key_value = cookie_str.split(';').first
        next unless key_value&.include?('=')

        key, value = key_value.split('=', 2)
        cookies[key.strip] = value.strip
        logger.info "[Zalo::LoginService] Added cookie: #{key}=#{value}"
      end
    end

    def cookie_string
      cookies.map { |k, v| "#{k}=#{v}" }.join('; ')
    end

    def restore_cookies(cookie_hash)
      logger.info "[Zalo::LoginService] Restoring cookies: #{cookie_hash.inspect}"
      self.cookies = cookie_hash || {}
    end

    def success_result(data)
      { success: true, data: data }
    end

    def failure_result(message, code)
      { success: false, error: message, code: code }
    end

    def notify_callback(callback, type, message, code, data = nil)
      return failure_result(message, code) unless callback

      callback.call({
                      type: type,
                      message: message,
                      data: data
                    })
      failure_result(message, code)
    rescue => e
      logger.error "[Zalo::LoginService] Callback Error: #{e.message}\n#{e.backtrace.join('\n')}"
      failure_result(message, code)
    end

    def with_timeout(timeout_seconds)
      Timeout.timeout(timeout_seconds) { yield }
    rescue Timeout::Error
      { 'error_code' => -99, 'error_message' => "Operation timed out after #{timeout_seconds} seconds" }
    end
  end

  class ZaloApiError < StandardError; end
end
