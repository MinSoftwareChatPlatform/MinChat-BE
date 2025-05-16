require 'openssl'
require 'base64'
require 'json'
require 'uri'
require 'zlib'
require 'securerandom'
require 'stringio'
require 'digest/md5'

module Zalo
  class ZaloCryptoHelper
    def initialize(ctx)
      @ctx = ctx # Store zalo_account
    end
    def get_encrypt_param(encrypt_params, type)
      param_dict = {}
      data = {
        "computer_name" => "Web",
        "imei" => @ctx.imei,
        "language" => @ctx.language,
        "ts" => (Time.now.to_f * 1000).to_i
      }

      encrypted_data = encrypt_param(@ctx, data, encrypt_params)

      if encrypted_data.nil?
        # Merge data into param_dict
        data.each do |k, v|
          param_dict[k] = v.to_s
        end
      else
        encrypted_data[:encrypted_params].each do |k, v|
          param_dict[k] = v
        end
        param_dict["params"] = encrypted_data[:encrypted_data]
      end

      param_dict["type"] = @ctx.api_type.to_s
      param_dict["client_version"] = @ctx.api_version.to_s

      if type == "getserverinfo"
        temp = {
          "imei" => @ctx.imei,
          "type" => @ctx.api_type.to_s,
          "client_version" => @ctx.api_version.to_s,
          "computer_name" => "Web"
        }
        signkey = get_sign_key(type, temp)
      else
        signkey = get_sign_key(type, param_dict)
      end
      param_dict["signkey"] = signkey

      {
        params_dict: param_dict,
        enk: encrypted_data&.dig(:enk),
        params: encrypted_data&.dig(:encrypted_params)
      }
    end

    def encrypt_param(ctx, data, encrypt_params)
      return nil unless encrypt_params

      encryptor = ParamsEncryptor.new(@ctx.api_type, @ctx.imei, (Time.now.to_f * 1000).to_i)
      begin
        stringified_data = data.to_json
        encrypted_key = encryptor.get_encrypt_key
        encoded_data = encryptor.encode_aes(encrypted_key, stringified_data, "base64", false)
        paramz = encryptor.get_params

        if paramz
          {
            encrypted_data: encoded_data,
            encrypted_params: paramz,
            enk: encrypted_key
          }
        else
          nil
        end
      rescue => e
        raise "Failed to encrypt params: #{e.message}"
      end
    end

    def get_sign_key(type, param_dict)
      keys = param_dict.keys.sort
      a = "zsecure" + type
      keys.each do |k|
        a += param_dict[k]
      end

      Digest::MD5.hexdigest(a)
    end

    def make_url(base_url, extra_params, encrypted_params = nil)
      query_params = {}

      extra_params&.each do |k, v|
        query_params[k] = v
      end

      encrypted_params&.each do |k, v|
        query_params[k] = v unless v.nil? || v.empty?
      end

      query_params["zpw_ver"] = @ctx.api_version.to_s unless query_params.key?("zpw_ver")
      query_params["zpw_type"] = @ctx.api_type.to_s unless query_params.key?("zpw_type")

      uri = URI(base_url)
      uri.query = URI.encode_www_form(query_params)
      uri.to_s
    end

    def decrypt_resp(key, data)
      begin
        result = decode_resp_aes(key, data)
        parsed = JSON.parse(result)
        return parsed
      rescue
        return result
      end
    end

    def decode_resp_aes(key, data)
      key_bytes = key.bytes.to_a
      cipher_bytes = Base64.decode64(data)
      iv = "\x00" * 16

      cipher = OpenSSL::Cipher.new('AES-256-CBC')
      cipher.decrypt
      cipher.key = key_bytes.pack('C*')
      cipher.iv = iv
      cipher.padding = 1 # PKCS7

      decrypted = cipher.update(cipher_bytes) + cipher.final
      decrypted
    end

    def zws_decode(parsed, key)
      jobject = JSON.parse(parsed)
      payload = jobject["data"].to_s
      encrypt_type = jobject["encrypt"].to_i

      begin
        decoded_data = nil

        if encrypt_type == 0
          decoded_data = payload
        elsif encrypt_type == 1
          decrypted_data = Base64.decode64(payload)
          decoded_data = Zlib::GzipReader.new(StringIO.new(decrypted_data)).read
        elsif encrypt_type == 2
          data_bytes = Base64.decode64(payload)

          if data_bytes.length >= 48
            iv = data_bytes[0...16]
            additional_data = data_bytes[16...32]
            data_source = data_bytes[32..-1]

            raise "Invalid data source length" if data_source.length < 16

            cipher_text_length = data_source.length - 16
            ciphertext = data_source[0...cipher_text_length]
            tag = data_bytes[(32 + cipher_text_length)...(32 + cipher_text_length + 16)]

            key_bytes = Base64.decode64(key)

            # GCM decryption in Ruby
            cipher = OpenSSL::Cipher.new('aes-256-gcm')
            cipher.decrypt
            cipher.key = key_bytes
            cipher.iv = iv
            cipher.auth_tag = tag
            cipher.auth_data = additional_data

            decrypted_data = cipher.update(ciphertext) + cipher.final

            # Decompress with GZip
            decoded_data = Zlib::GzipReader.new(StringIO.new(decrypted_data)).read
          end
        else
          decoded_data = nil
        end

        return nil if decoded_data.nil? || decoded_data.empty?
        JSON.parse(decoded_data)
      rescue => e
        raise "Unable to decode payload! Error: #{e.message}"
      end
    end

    def encode_aes(secret_key, data, attempt = 0)
      begin
        key_bytes = Base64.decode64(secret_key)
        plain_bytes = data.bytes.to_a
        iv_bytes = "\x00" * 16

        cipher = OpenSSL::Cipher.new('AES-256-CBC')
        cipher.encrypt
        cipher.key = key_bytes
        cipher.iv = iv_bytes
        cipher.padding = 1 # PKCS7

        encrypted = cipher.update(data) + cipher.final
        Base64.strict_encode64(encrypted)
      rescue
        return encode_aes(secret_key, data, attempt + 1) if attempt < 3
        nil
      end
    end

    def decode_aes(secret_key, data, attempt = 0)
      begin
        data = URI.decode_www_form_component(data)
        key_bytes = Base64.decode64(secret_key)
        cipher_bytes = Base64.decode64(data)
        iv_bytes = "\x00" * 16

        cipher = OpenSSL::Cipher.new('AES-256-CBC')
        cipher.decrypt
        cipher.key = key_bytes
        cipher.iv = iv_bytes
        cipher.padding = 1 # PKCS7

        decrypted = cipher.update(cipher_bytes) + cipher.final
        decrypted
      rescue
        return decode_aes(secret_key, data, attempt + 1) if attempt < 3
        nil
      end
    end
  end

  class ParamsEncryptor
    attr_reader :enc_ver, :zcid, :encrypt_key, :zcid_ext

    def initialize(type, imei, first_launch_time)
      @enc_ver = "v2"
      create_zcid(type, imei, first_launch_time)
      @zcid_ext = random_string
      raise "Failed to create encrypt key after multiple attempts." unless create_encrypt_key
    end

    def get_encrypt_key
      raise "getEncryptKey: encryptKey chưa được tạo" if @encrypt_key.nil? || @encrypt_key.empty?
      @encrypt_key
    end

    def create_zcid(type, imei, first_launch_time)
      if type == 0 || imei.nil? || imei.empty? || first_launch_time == 0
        raise "createZcid: thiếu tham số"
      end

      msg = "#{type},#{imei},#{first_launch_time}"
      @zcid = encode_aes("3FC4F0D2AB50057BCE0D90D9187A22B1", msg, "hex", true)
    end

    def create_encrypt_key(attempt = 0)
      if @zcid.nil? || @zcid.empty? || @zcid_ext.nil? || @zcid_ext.empty?
        raise "createEncryptKey: zcid hoặc zcid_ext null"
      end

      md5_str = Digest::MD5.hexdigest(@zcid_ext).upcase
      success = try_generate_encrypt_key(md5_str, @zcid)

      if success
        true
      elsif attempt < 3
        create_encrypt_key(attempt + 1)
      else
        false
      end
    end

    def try_generate_encrypt_key(md5_str, zcid)
      proc_md5 = process_str(md5_str)
      proc_zcid = process_str(zcid)

      even_md5 = proc_md5[0]
      even_zcid = proc_zcid[0]
      odd_zcid = proc_zcid[1]

      return false if even_md5.nil? || even_zcid.nil? || odd_zcid.nil?

      part1 = even_md5[0...8].join
      part2 = even_zcid[0...12].join
      part3 = odd_zcid.reverse[0...12].join

      @encrypt_key = part1 + part2 + part3
      true
    end

    def get_params
      return nil if @zcid.nil? || @zcid.empty?

      {
        "zcid" => @zcid,
        "zcid_ext" => @zcid_ext,
        "enc_ver" => @enc_ver
      }
    end

    def process_str(input)
      return [nil, nil] if input.nil? || input.empty?

      even = []
      odd = []

      input.chars.each_with_index do |char, i|
        if i % 2 == 0
          even << char
        else
          odd << char
        end
      end

      [even, odd]
    end

    def random_string(min_length = 6, max_length = nil)
      min = min_length
      max = max_length && max_length > min ? max_length : 12
      len = rand(min..max)

      result = ""
      while len > 0
        segment = len > 12 ? 12 : len
        result += random_hex_string(segment)
        len -= segment
      end

      result
    end

    def random_hex_string(length)
      hex_chars = "0123456789abcdef"
      result = ""
      length.times do
        result += hex_chars[rand(16)]
      end
      result
    end

    def encode_aes(key_str, message, output_type, uppercase, attempt = 0)
      return nil if message.nil? || message.empty?

      begin
        key_bytes = key_str.bytes.to_a
        iv_bytes = "\x00" * 16

        cipher = OpenSSL::Cipher.new('AES-256-CBC')
        cipher.encrypt
        cipher.key = key_bytes.pack('C*')
        cipher.iv = iv_bytes
        cipher.padding = 1 # PKCS7

        encrypted = cipher.update(message) + cipher.final

        if output_type == "hex"
          hex = encrypted.unpack('H*').first
          uppercase ? hex.upcase : hex.downcase
        else
          b64 = Base64.strict_encode64(encrypted)
          uppercase ? b64.upcase : b64
        end
      rescue
        return encode_aes(key_str, message, output_type, uppercase, attempt + 1) if attempt < 3
        nil
      end
    end
  end
end
