require 'openssl'
require 'digest'
require 'base64'
require 'json'
require 'zlib'
require 'securerandom'

module Zalo
  class EncryptionService
    attr_reader :channel_zalo

    def initialize(channel_zalo = nil)
      @channel_zalo = channel_zalo
    end

    # Port of ZaloCryptoHelper.GetEncryptParam
    def get_encrypt_param(zalo_account, encrypt_params_flag, type)
      params_dict = {
        'computer_name' => 'Web',
        'imei' => zalo_account.imei,
        'language' => zalo_account.language || 'vi',
        'ts' => (Time.now.to_f * 1000).to_i.to_s
      }

      encrypted_data = encrypt_param(zalo_account, params_dict, encrypt_params_flag)

      if encrypted_data.nil?
        params_dict.merge!(params_dict)
      else
        params_dict.merge!(encrypted_data[:encrypted_params])
        params_dict['params'] = encrypted_data[:encrypted_data]
      end

      params_dict['type'] = zalo_account.api_type.to_s
      params_dict['client_version'] = zalo_account.api_version.to_s

      signkey = if type == 'getserverinfo'
                  temp_params = {
                    'imei' => zalo_account.imei,
                    'type' => zalo_account.api_type.to_s,
                    'client_version' => zalo_account.api_version.to_s,
                    'computer_name' => 'Web'
                  }
                  get_sign_key(type, temp_params)
                else
                  get_sign_key(type, params_dict)
                end

      params_dict['signkey'] = signkey

      {
        params_dict: params_dict,
        enk: encrypted_data&.[](:enk),
        params: encrypted_data&.[](:encrypted_params)
      }
    end

    # Port of ZaloCryptoHelper.EncryptParam
    def encrypt_param(zalo_account, data, encrypt_params_flag)
      return nil unless encrypt_params_flag

      encryptor = ParamsEncryptor.new(zalo_account.api_type, zalo_account.imei, (Time.now.to_f * 1000).to_i)
      begin
        params_json = data.to_json
        encrypted_key = encryptor.encrypt_key
        encoded_data = encryptor.encode_aes(encrypted_key, params_json, 'base64', false)
        params = encryptor.get_params
        return nil if params.nil?

        { encrypted_data: encoded_data, encrypted_params: params, enk: encrypted_key }
      rescue => e
        Rails.logger.error "[Zalo::EncryptionService] Encrypt Param Error: #{e.message}"
        raise "Failed to encrypt params: #{e.message}"
      end
    end

    # Port of ZaloCryptoHelper.GetSignKey
    def get_sign_key(type, params_dict)
      keys = params_dict.keys.sort
      str = "zsecure#{type}"
      keys.each { |k| str += params_dict[k].to_s }
      Digest::MD5.hexdigest(str)
    end

    # Port of ZaloCryptoHelper.MakeURL
    def make_url(zalo_account, base_url, extra_params, encrypted_params = nil)
      query_params = {}
      extra_params&.each { |k, v| query_params[k] = v }
      encrypted_params&.each { |k, v| query_params[k] = v unless v.nil? || v.empty? }
      query_params['zpw_ver'] ||= zalo_account.api_version.to_s
      query_params['zpw_type'] ||= zalo_account.api_type.to_s

      uri = URI.parse(base_url)
      uri.query = URI.encode_www_form(query_params)
      uri.to_s
    end

    # Port of ZaloCryptoHelper.DecryptResp
    def decrypt_resp(key, data)
      result = decode_resp_aes(key, data)
      JSON.parse(result)
    rescue
      result
    end

    # Port of ZaloCryptoHelper.DecodeRespAES
    def decode_resp_aes(key, data)
      data = URI.decode_www_form_component(data)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.key = key.byteslice(0, 32)
      cipher.iv = "\x00" * 16
      cipher.padding = 1 # PKCS7 padding

      encrypted_data = Base64.decode64(data)
      decrypted_data = cipher.update(encrypted_data) + cipher.final
      decrypted_data.force_encoding('UTF-8')
    rescue => e
      Rails.logger.error "[Zalo::EncryptionService] AES Decryption Error: #{e.message}"
      raise "AES Decryption Failed: #{e.message}"
    end

    # Port of ZaloCryptoHelper.ZwsDecode
    def zws_decode(parsed, key)
      data = JSON.parse(parsed)
      payload = data['data']
      encrypt_type = data['encrypt'].to_i

      decoded_data = case encrypt_type
                     when 0
                       payload
                     when 1
                       decompressed_data = Zlib::Inflate.inflate(Base64.decode64(payload))
                       decompressed_data.force_encoding('UTF-8')
                     when 2
                       data_bytes = Base64.decode64(payload)
                       raise 'Invalid data source length' if data_bytes.length < 48

                       iv = data_bytes[0...16]
                       additional_data = data_bytes[16...32]
                       data_source = data_bytes[32..-1]
                       cipher_text_length = data_source.length - 16
                       ciphertext = data_source[0...cipher_text_length]
                       tag = data_source[cipher_text_length..-1]

                       cipher_with_tag = ciphertext + tag
                       key_bytes = Base64.decode64(key)

                       decipher = OpenSSL::Cipher.new('aes-256-gcm')
                       decipher.decrypt
                       decipher.key = key_bytes
                       decipher.iv = iv
                       decipher.auth_tag = tag
                       decipher.auth_data = additional_data

                       decrypted_data = decipher.update(ciphertext) + decipher.final
                       decompressed_data = Zlib::Inflate.inflate(decrypted_data)
                       decompressed_data.force_encoding('UTF-8')
                     else
                       nil
                     end

      return nil if decoded_data.nil? || decoded_data.empty?
      JSON.parse(decoded_data)
    rescue => e
      Rails.logger.error "[Zalo::EncryptionService] ZWS Decode Error: #{e.message}"
      raise "Unable to decode payload: #{e.message}"
    end

    # Port of ZaloCryptoHelper.EncodeAES
    def encode_aes(secret_key, data, attempt = 0)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.encrypt
      cipher.key = Base64.decode64(secret_key)
      cipher.iv = "\x00" * 16
      cipher.padding = 1

      encrypted_data = cipher.update(data) + cipher.final
      Base64.strict_encode64(encrypted_data)
    rescue
      return encode_aes(secret_key, data, attempt + 1) if attempt < 3
      nil
    end

    # Port of ZaloCryptoHelper.DecodeAES
    def decode_aes(secret_key, data, attempt = 0)
      data = URI.decode_www_form_component(data)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.key = Base64.decode64(secret_key)
      cipher.iv = "\x00" * 16
      cipher.padding = 1

      encrypted_data = Base64.decode64(data)
      decrypted_data = cipher.update(encrypted_data) + cipher.final
      decrypted_data.force_encoding('UTF-8')
    rescue
      return decode_aes(secret_key, data, attempt + 1) if attempt < 3
      nil
    end

    # Enhanced from provided EncryptionService
    def generate_signature(params_hash, type_suffix)
      sorted_params = params_hash.sort_by { |key, _| key.to_s }
      param_string = sorted_params.map { |key, value| value.to_s }.join
      string_to_hash = "zsecure#{type_suffix}#{param_string}"
      Digest::MD5.hexdigest(string_to_hash)
    end

    # Enhanced from provided EncryptionService
    def decrypt_aes_cbc_pkcs7(encrypted_base64_data, key_string, iv_string)
      encrypted_data = Base64.decode64(encrypted_base64_data)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.key = key_string.byteslice(0, 32)
      cipher.iv = iv_string.byteslice(0, 16)
      cipher.padding = 1

      decrypted_data = cipher.update(encrypted_data) + cipher.final
      decrypted_data.force_encoding('UTF-8')
    rescue => e
      Rails.logger.error "[Zalo::EncryptionService] AES Decryption Error: #{e.message}"
      raise "AES Decryption Failed: #{e.message}"
    end

    # Enhanced from provided EncryptionService
    def encrypt_aes_cbc_pkcs7(plain_text_data, key_string, iv_string)
      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.encrypt
      cipher.key = key_string.byteslice(0, 32)
      cipher.iv = iv_string.byteslice(0, 16)
      cipher.padding = 1

      encrypted_data = cipher.update(plain_text_data.to_s) + cipher.final
      Base64.strict_encode64(encrypted_data)
    rescue => e
      Rails.logger.error "[Zalo::EncryptionService] AES Encryption Error: #{e.message}"
      raise "AES Encryption Failed: #{e.message}"
    end

    # Enhanced from provided EncryptionService
    def decrypt_websocket_message(binary_data, secret_key)
      iv = binary_data[0...12]
      auth_tag = binary_data[-16..-1]
      ciphertext = binary_data[12...-16]

      decipher = OpenSSL::Cipher.new('aes-256-gcm')
      decipher.decrypt
      decipher.key = secret_key[0...32]
      decipher.iv = iv
      decipher.auth_tag = auth_tag

      decrypted_data = decipher.update(ciphertext) + decipher.final
      decompressed_data = Zlib::Inflate.inflate(decrypted_data)
      decompressed_data.force_encoding('UTF-8')
    rescue => e
      Rails.logger.error "[Zalo::EncryptionService] WebSocket Decryption Error: #{e.message}"
      raise "Failed to decrypt WebSocket message: #{e.message}"
    end

    # Port of ZaloCryptoHelper.ParamsEncryptor
    class ParamsEncryptor
      attr_reader :encrypt_key, :zcid, :zcid_ext, :enc_ver

      def initialize(type, imei, first_launch_time)
        @enc_ver = 'v2'
        @zcid = create_zcid(type, imei, first_launch_time)
        @zcid_ext = random_string
        @encrypt_key = create_encrypt_key
      end

      def get_params
        return nil if zcid.nil?
        {
          'zcid' => zcid,
          'zcid_ext' => zcid_ext,
          'enc_ver' => enc_ver
        }
      end

      def encode_aes(key, message, output_type, uppercase, attempt = 0)
        cipher = OpenSSL::Cipher.new('AES-256-CBC')
        cipher.encrypt
        cipher.key = Encoding::UTF_8.encode(key)
        cipher.iv = "\x00" * 16
        cipher.padding = 1

        encrypted_data = cipher.update(message) + cipher.final
        result = output_type == 'hex' ? encrypted_data.unpack1('H*') : Base64.strict_encode64(encrypted_data)
        uppercase ? result.upcase : result.downcase
      rescue
        return encode_aes(key, message, output_type, uppercase, attempt + 1) if attempt < 3
        nil
      end

      private

      def create_zcid(type, imei, first_launch_time)
        raise 'Missing parameters for zcid' if type.zero? || imei.empty? || first_launch_time.zero?
        msg = "#{type},#{imei},#{first_launch_time}"
        encode_aes('3FC4F0D2AB50057BCE0D90D9187A22B1', msg, 'hex', true)
      end

      def create_encrypt_key(attempt = 0)
        raise 'zcid or zcid_ext is nil' if zcid.nil? || zcid_ext.nil?
        md5_str = Digest::MD5.hexdigest(zcid_ext).upcase
        success = try_generate_encrypt_key(md5_str, zcid)
        return @encrypt_key if success
        return create_encrypt_key(attempt + 1) if attempt < 3
        raise 'Failed to create encrypt key after multiple attempts'
      end

      def try_generate_encrypt_key(md5_str, zcid)
        even_md5, _ = process_str(md5_str)
        even_zcid, odd_zcid = process_str(zcid)
        return false if even_md5.nil? || even_zcid.nil? || odd_zcid.nil?

        part1 = even_md5.take(8).join
        part2 = even_zcid.take(12).join
        part3 = odd_zcid.reverse.take(12).join
        @encrypt_key = "#{part1}#{part2}#{part3}"
        true
      end

      def process_str(input)
        return [nil, nil] if input.nil? || input.empty?
        even = []
        odd = []
        input.chars.each_with_index do |char, i|
          i.even? ? even << char : odd << char
        end
        [even, odd]
      end

      def random_string(min_length = 6, max_length = 12)
        length = rand(min_length..max_length)
        chars = ('0'..'9').to_a + ('a'..'f').to_a
        segments = []
        remaining = length
        while remaining.positive?
          segment_length = [remaining, 12].min
          segments << Array.new(segment_length) { chars.sample }.join
          remaining -= segment_length
        end
        segments.join
      end
    end
  end
end