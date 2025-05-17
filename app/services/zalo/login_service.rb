require 'typhoeus'
require 'json'
require 'securerandom'
require 'uri'
require 'redis'
require 'logger'
require 'base64'
require_relative 'LoginEventType'

module Zalo
  class LoginService
    attr_reader :redis, :imei

    def initialize(logger = Logger.new(STDOUT))
      @redis = Redis.new
      @logger = logger
      @imei = SecureRandom.uuid
    end

    # Tạo mã QR cho đăng nhập Zalo
    def generate_qr_code(callback = nil, options = { user_agent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36', qr_path: 'qr.png' })
      ctx = Zalo::LoginContext.new
      ctx.user_agent = options[:user_agent]
      ctx.logging = true
      ctx.set_logger(@logger)

      version = load_login_page(ctx, callback)
      unless version
        notify_callback(callback, nil, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Không thể lấy phiên bản API đăng nhập')
        return error_response('Không thể lấy phiên bản API đăng nhập')
      end
      @logger.info("[Zalo::LoginService] Phiên bản API đăng nhập: #{version}")

      get_login_info(ctx, version, callback)
      verify_client(ctx, version, callback)

      qr_response = generate_qr(ctx, version, callback)
      qr_data = qr_response['data']
      unless qr_data
        notify_callback(callback, nil, Zalo::LoginEventType::QR_CODE_EXPIRED, "Không thể tạo mã QR: #{qr_response.to_json}")
        return error_response("Không thể tạo mã QR: #{qr_response.to_json}")
      end

      code = qr_data['code']
      base64_image = qr_data['image'].sub('data:image/png;base64,', '')

      qr_code_id = SecureRandom.uuid
      qr_data_store = {
        'cookie_jar' => ctx.cookie_jar,
        'version' => version,
        'code' => code
      }
      @redis.setex("zalo_qr_#{qr_code_id}", 100, qr_data_store.to_json)

      notify_callback(
        callback,
        qr_code_id,
        Zalo::LoginEventType::QR_CODE_GENERATED,
        'QR code generated',
        { code: code, image: base64_image }
      )

      # Start timeout for QR code expiration
      Thread.new do
        sleep 100 # Wait 100 seconds
        if @redis.exists("zalo_qr_#{qr_code_id}")
          @logger.info("[Zalo::LoginService] QR hết hạn, tiến hành lấy mới")
          notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, 'QR code expired, generating new one')
          generate_qr_code(callback, options) # Regenerate QR code
        end
      end

      { success: true, qr_code_id: qr_code_id, base64_image: base64_image }
    rescue StandardError => e
      @logger.error "[Zalo::LoginService] Error in generate_qr_code: #{e.message}\n#{e.backtrace.join("\n")}"
      notify_callback(
        callback,
        nil,
        Zalo::LoginEventType::QR_CODE_EXPIRED,
        "Error add Zalo account: #{e.message}"
      )
      error_response("Error add Zalo account: #{e.message}")
    end

    def check_qr_code_scan(qr_code_id, callback = nil, user_id = nil)
      qr_data_key = "zalo_qr_#{qr_code_id}"
      qr_data_json = @redis.get(qr_data_key)
      unless qr_data_json
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, 'QR code not found or expired')
        return error_response('QR code not found or expired')
      end

      qr_data = JSON.parse(qr_data_json)
      cookie_jar = qr_data['cookie_jar']
      version = qr_data['version']
      code = qr_data['code']

      ctx = Zalo::LoginContext.new
      ctx.cookie_jar = cookie_jar
      ctx.logging = true
      ctx.set_logger(@logger)

      scan_result = waiting_scan(ctx, version, code, callback)
      error_code = scan_result['error_code']
      case error_code
      when 0
        scan_data = scan_result['data']
        notify_callback(
          callback,
          qr_code_id,
          Zalo::LoginEventType::QR_CODE_SCANNED,
          'QR code scanned',
          { avatar: scan_data['avatar'], display_name: scan_data['display_name'] }
        )
      when 8
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_GENERATED, 'Mã QR chưa được quét')
        return error_response('QR not scanned')
      when -13
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_DECLINED, 'Bạn đã từ chối đăng nhập bằng mã QR')
        return error_response('QR declined')
      else
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, "Lỗi không xác định: #{error_code}")
        return error_response("Unknown error: #{error_code}")
      end

      confirm_result = waiting_confirm(ctx, version, code, callback)
      if confirm_result['error_code'] != 0
        type = confirm_result['error_code'] == -13 ? Zalo::LoginEventType::QR_CODE_DECLINED : Zalo::LoginEventType::QR_CODE_EXPIRED
        message = confirm_result['error_code'] == -13 ? 'Bạn đã từ chối đăng nhập bằng mã QR' : "Đã có lỗi xảy ra: #{confirm_result.to_json}"
        notify_callback(callback, qr_code_id, type, message)
        return error_response(message)
      end

      unless check_session(ctx, callback)
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Không thể kiểm tra phiên đăng nhập')
        return error_response('Session check failed')
      end

      @logger.info("[Zalo::LoginService] Login thành công vào tài khoản #{scan_result['data']['display_name']}")

      update_cookie_jar(ctx, scan_result['data']['cookie'])

      user_info_resp = get_user_info(ctx, callback)
      unless user_info_resp && user_info_resp['data'] && user_info_resp['data']['logged']
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Không thể lấy thông tin người dùng hoặc đăng nhập thất bại')
      end

      user_info = {
        name: user_info_resp['data']['info']['name'],
        avatar: user_info_resp['data']['info']['avatar']
      }

      encrypted_result = Zalo::ZaloCryptoHelper.get_encrypt_param(true, "getlogininfo")
      encrypted_result[:params_dict]['nretry'] = '0' unless encrypted_result[:params_dict].key?('nretry')
      cookie = ctx.cookie_jar.map { |k, v| "#{k}=#{v}" }.join('; ')

      api_url = Zalo::URLManager::Login::GET_LOGIN_INFO
      full_url = @encryption_service.make_url(api_url, encrypted_result[:params_dict])

      @logger.info "[Zalo::LoginService] URL gọi API: #{full_url}"

      # Make the API request using make_request
      headers = {
        'Cookie' => cookie,
        'Accept' => 'application/json, text/plain, */*',
        'Content-Type' => 'application/x-www-form-urlencoded'
      }
      response = make_request(ctx, :get, full_url, headers: headers)

      # Parse the response
      parsed_response = parse_json_response(response.body)
      unless parsed_response
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Không thể phân tích phản hồi API')
        return error_response('Failed to parse API response')
      end
      encrypted_data = parsed_response["data"].to_s

      # Decrypt the response
      decrypted_data = @encryption_service.decrypt_resp(encrypted_result[:enk], encrypted_data)
      unless decrypted_data["data"]
        notify_callback(callback, qr_code_id, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Không có dữ liệu trong phản hồi được giải mã')
        return error_response('No data in decrypted response')
      end
      parsed_decrypted = JSON.parse(decrypted_data)

      zalo_account = {
        display_name: user_info[:name],
        avatar: user_info[:avatar],
        secret_key: parsed_decrypted['data']['zpw_enk'],
        cookie: cookie,
        imei: @imei,
        user_id: user_id,
        phone: "0#{parsed_decrypted['data']['phone_number'][2..]}",
        account_id: parsed_decrypted['data']['uid']
      }

      user_info[:phone] = zalo_account[:phone]

      notify_callback(
        callback,
        qr_code_id,
        Zalo::LoginEventType::GOT_LOGIN_INFO,
        'Login successful',
        user_info
      )

      { success: true, user_info: zalo_account }
    rescue StandardError => e
      @logger.error "[Zalo::LoginService] Error in check_qr_code_scan: #{e.message}\n#{e.backtrace.join("\n")}"
      notify_callback(
        callback,
        qr_code_id,
        Zalo::LoginEventType::QR_CODE_EXPIRED,
        "Error check Zalo account: #{e.message}"
      )
      error_response("Error check Zalo account: #{e.message}")
    end

    private

    def make_request(ctx, method, path, headers: {}, body: nil, timeout: 60)
      cookie_header = ctx.cookie_jar.map { |k, v| "#{k}=#{v}" }.join('; ')
      default_headers = {
        'User-Agent' => ctx.user_agent,
        'Cookie' => cookie_header,
        'Accept' => 'application/json, text/plain, */*',
        'Connection' => 'keep-alive'
      }
      full_headers = default_headers.merge(headers)

      options = {
        method: method,
        headers: full_headers,
        followlocation: true,
        timeout: timeout,
        ssl_verifypeer: true,
        ssl_verifyhost: 2
      }

      if body
        options[:body] = body
        full_headers['Content-Type'] ||= 'application/x-www-form-urlencoded'
      end

      request = Typhoeus::Request.new(path, options)

      if ctx.logging
        @logger.info "[Zalo::LoginService] Sending #{method.to_s.upcase} request to #{path}"
        @logger.debug "[Zalo::LoginService] Headers: #{full_headers}"
        @logger.debug "[Zalo::LoginService] Body: #{body}" if body
      end

      response = request.run
      update_cookie_jar(ctx, response.headers['set-cookie'])

      if ctx.logging
        @logger.info "[Zalo::LoginService] Response code: #{response.code}, Return code: #{response.return_code || 'none'}"
        @logger.debug "[Zalo::LoginService] Response Body: #{response.body}" unless response.body.empty?
        @logger.debug "[Zalo::LoginService] Connect time: #{response.connect_time}, Total time: #{response.total_time}"
      end

      if response.code == 0
        error_message = "HTTP request failed: Code 0 (#{response.return_code || 'unknown error'}) - Likely network or server issue"
        ctx.log_error(error_message)
        raise StandardError, error_message
      end

      unless response.success?
        error_message = "HTTP request failed: #{response.code} - #{response.body}"
        ctx.log_error(error_message)
        raise StandardError, error_message
      end

      response
    rescue StandardError => e
      error_message = "Lỗi khi gửi yêu cầu HTTP: #{e.message} (Return code: #{response&.return_code || 'none'})"
      ctx.log_error(error_message)
      raise StandardError, error_message
    end

    def update_cookie_jar(ctx, set_cookie)
      return unless set_cookie
      Array(set_cookie).each do |cookie_str|
        name, value = cookie_str.split(';').first.split('=')
        ctx.cookie_jar[name] = value if name && value
      end
    end

    def parse_json_response(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def load_login_page(ctx, callback = nil)
      url = 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      headers = {
        'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
        'Accept-Language' => 'vi-VN,vi;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5',
        'Cache-Control' => 'max-age=0',
        'Priority' => 'u=0, i',
        'Sec-Ch-Ua' => '"Chromium";v="130", "Google Chrome";v="130", "Not?A_Brand";v="99"',
        'Sec-Ch-Ua-Mobile' => '?0',
        'Sec-Ch-Ua-Platform' => '"Windows"',
        'Sec-Fetch-Dest' => 'document',
        'Sec-Fetch-Mode' => 'navigate',
        'Sec-Fetch-Site' => 'same-site',
        'Sec-Fetch-User' => '?1',
        'Upgrade-Insecure-Requests' => '1',
        'Referer' => 'https://chat.zalo.me/',
        'Referrer-Policy' => 'strict-origin-when-cross-origin'
      }

      response = make_request(ctx, :get, url, headers: headers)
      html = response.body
      match = /https:\/\/stc-zlogin\.zdn\.vn\/main-([\d\.]+)\.js/.match(html)
      version = match ? match[1] : nil

      notify_callback(
        callback,
        nil,
        version ? Zalo::LoginEventType::QR_CODE_GENERATED : Zalo::LoginEventType::QR_CODE_EXPIRED,
        version ? "Loaded login page, version: #{version}" : 'Failed to extract API version'
      )
      version
    end

    def get_login_info(ctx, version, callback = nil)
      url = 'https://id.zalo.me/account/logininfo'
      form_data = { continue: 'https://chat.zalo.me/', v: version }
      headers = {
        'Accept' => '*/*',
        'Accept-Language' => 'vi-VN,vi;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5',
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Priority' => 'u=1, i',
        'Sec-Ch-Ua' => '"Chromium";v="130", "Google Chrome";v="130", "Not?A_Brand";v="99"',
        'Sec-Ch-Ua-Mobile' => '?0',
        'Sec-Ch-Ua-Platform' => '"Windows"',
        'Sec-Fetch-Dest' => 'empty',
        'Sec-Fetch-Mode' => 'cors',
        'Sec-Fetch-Site' => 'same-origin',
        'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F',
        'Referrer-Policy' => 'strict-origin-when-cross-origin'
      }

      response = make_request(ctx, :post, url, headers: headers, body: URI.encode_www_form(form_data))
      result = parse_json_response(response.body)
      notify_callback(
        callback,
        nil,
        result ? Zalo::LoginEventType::QR_CODE_GENERATED : Zalo::LoginEventType::QR_CODE_EXPIRED,
        result ? 'Retrieved login info' : 'Failed to retrieve login info'
      )
      result
    end

    def verify_client(ctx, version, callback = nil)
      url = 'https://id.zalo.me/account/verify-client'
      form_data = { type: 'device', continue: 'https://zalo.me/pc', v: version }
      headers = {
        'DNT' => '1',
        'Origin' => 'https://id.zalo.me',
        'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }

      response = make_request(ctx, :post, url, headers: headers, body: URI.encode_www_form(form_data))
      result = parse_json_response(response.body)
      notify_callback(
        callback,
        nil,
        result ? Zalo::LoginEventType::QR_CODE_GENERATED : Zalo::LoginEventType::QR_CODE_EXPIRED,
        result ? 'Client verified' : 'Failed to verify client'
      )
      result
    end

    def generate_qr(ctx, version, callback = nil)
      url = 'https://id.zalo.me/account/authen/qr/generate'
      form_data = { continue: 'https://zalo.me/pc', v: version }
      headers = {
        'DNT' => '1',
        'Origin' => 'https://id.zalo.me',
        'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }

      response = make_request(ctx, :post, url, headers: headers, body: URI.encode_www_form(form_data))
      result = parse_json_response(response.body)
      notify_callback(
        callback,
        nil,
        result && result['data'] ? Zalo::LoginEventType::QR_CODE_GENERATED : Zalo::LoginEventType::QR_CODE_EXPIRED,
        result && result['data'] ? 'QR code generated' : 'Failed to generate QR code'
      )
      result
    end

    def waiting_scan(ctx, version, code, callback = nil, timeout = 60)
      url = 'https://id.zalo.me/account/authen/qr/waiting-scan'
      form_data = { code: code, continue: 'https://chat.zalo.me/', v: version }
      headers = {
        'DNT' => '1',
        'Origin' => 'https://id.zalo.me',
        'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }

      start_time = Time.now
      loop do
        if Time.now - start_time > timeout
          notify_callback(callback, nil, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Timeout waiting for scan')
          return { 'error_code' => -99, 'error_message' => 'Timeout' }
        end

        response = make_request(ctx, :post, url, headers: headers, body: URI.encode_www_form(form_data))
        data = parse_json_response(response.body)
        return data unless data && data['error_code'] == 8
      end
    end

    def waiting_confirm(ctx, version, code, callback = nil, timeout = 60)
      url = 'https://id.zalo.me/account/authen/qr/waiting-confirm'
      form_data = {
        code: code,
        gToken: '',
        gAction: 'CONFIRM_QR',
        continue: 'https://chat.zalo.me/',
        v: version
      }
      headers = {
        'DNT' => '1',
        'Origin' => 'https://id.zalo.me',
        'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }

      ctx.log_info('Vui lòng xác nhận trên điện thoại')
      start_time = Time.now
      loop do
        if Time.now - start_time > timeout
          notify_callback(callback, nil, Zalo::LoginEventType::QR_CODE_EXPIRED, 'Timeout waiting for confirmation')
          return { 'error_code' => -99, 'error_message' => 'Timeout' }
        end

        response = make_request(ctx, :post, url, headers: headers, body: URI.encode_www_form(form_data))
        data = parse_json_response(response.body)
        return data unless data && data['error_code'] == 8
      end
    end

    def check_session(ctx, callback = nil)
      url = 'https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html'
      headers = {
        'DNT' => '1',
        'Origin' => 'https://id.zalo.me',
        'Referer' => 'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F'
      }

      response = make_request(ctx, :get, url, headers: headers)
      success = response.code == 200
      notify_callback(
        callback,
        nil,
        success ? Zalo::LoginEventType::QR_CODE_GENERATED : Zalo::LoginEventType::QR_CODE_EXPIRED,
        success ? 'Session check successful' : 'Session check failed'
      )
      success
    end

    def get_user_info(ctx, callback = nil)
      url = 'https://jr.chat.zalo.me/jr/userinfo'
      headers = {
        'Accept' => '*/*',
        'Accept-Language' => 'vi-VN,vi;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5',
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Priority' => 'u=1, i',
        'Sec-Ch-Ua' => '"Chromium";v="130", "Google Chrome";v="130", "Not?A_Brand";v="99"',
        'Sec-Ch-Ua-Mobile' => '?0',
        'Sec-Ch-Ua-Platform' => '"Windows"',
        'Sec-Fetch-Dest' => 'empty',
        'Sec-Fetch-Mode' => 'cors',
        'Sec-Fetch-Site' => 'same-origin',
        'Referer' => 'https://chat.zalo.me/',
        'Referrer-Policy' => 'strict-origin-when-cross-origin'
      }

      response = make_request(ctx, :get, url, headers: headers)
      result = parse_json_response(response.body)
      notify_callback(
        callback,
        nil,
        result && result['data'] && result['data']['logged'] ? Zalo::LoginEventType::QR_CODE_GENERATED : Zalo::LoginEventType::QR_CODE_EXPIRED,
        result && result['data'] && result['data']['logged'] ? 'User info retrieved' : 'Failed to retrieve user info'
      )
      result
    end

    def notify_callback(callback, qr_code_id, type, message, data = nil, actions = nil)
      return unless callback
      callback.call({
                      type: type,
                      qr_code_id: qr_code_id,
                      message: message,
                      data: data,
                      actions: actions
                    })
    end

    def error_response(message)
      { success: false, error: message }
    end
  end
end
