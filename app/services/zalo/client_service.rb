require 'http'
require 'json'
require 'securerandom'
require 'logger'
require 'http-cookie'
require 'digest'
require_relative 'encryption_service'
require_relative 'zalo_url_manager'

module Zalo
  class ClientService
    CHUNK_SIZE = 512 * 1024 # 512KB
    MAX_SIZE_FILE = 1024 * 1024 * 1024 # 1GB
    MAX_FILES = 50

    attr_reader :logger, :http_client, :cookie_jar

    def initialize
      @logger = Logger.new(STDOUT)
      @logger.level = Logger::INFO
      @cookie_jar = HTTP::CookieJar.new
      @http_client = HTTP.use(:cookie_jar, jar: @cookie_jar).headers({
                                                                       'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36',
                                                                       'Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
                                                                       'Accept-Language' => 'vi-VN,vi;q=0.9',
                                                                       'Connection' => 'keep-alive'
                                                                     })
    end

    def send_message(zalo_account, request)
      @logger.info "[Zalo::Service] Gửi tin nhắn cho tài khoản: #{zalo_account.zalo_id}, conversation_id: #{request[:conversation_id]}"

      begin
        # Thiết lập cookie từ zalo_account
        update_cookies(zalo_account.cookie)

        # Gửi file đính kèm nếu có
        file_attachments = request[:files] && !request[:files].empty? ? upload_attachments(zalo_account, request) : nil
        return { success: false, error: 'Không thể tải file đính kèm' } if request[:files] && file_attachments.nil?

        # Gửi tin nhắn
        response = send_zalo_message(zalo_account, request, file_attachments)
        return response unless response[:success]

        # Lưu tin nhắn vào Chatwoot
        save_message(zalo_account, request, file_attachments)

        { success: true, message: 'Tin nhắn được gửi thành công' }
      rescue => e
        @logger.error "[Zalo::Service] Lỗi khi gửi tin nhắn: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Lỗi khi gửi tin nhắn: #{e.message}" }
      end
    end

    private

    def send_zalo_message(zalo_account, request, file_attachments = nil)
      content = request[:content].to_s.strip
      is_group = request[:is_group] || false
      member_id = request[:member_id]
      url = if file_attachments
              Zalo::URLManager::File.upload(is_group)
            else
              member_id ? Zalo::URLManager::Message.mention : Zalo::URLManager::Message.text_message(is_group)
            end

      if file_attachments
        is_multi_file = file_attachments.size > 1
        group_layout_id = (Time.now.to_f * 1000).to_i.to_s
        id_in_group = file_attachments.size - 1

        file_attachments.each_with_index do |file_attachment, index|
          json_data = build_file_payload(zalo_account, request, file_attachment, is_multi_file, group_layout_id, id_in_group)
          id_in_group -= 1
          response = send_api_request(zalo_account, url + file_attachment[:endpoint], json_data)
          return response unless response[:success]
          return response if index == file_attachments.size - 1 # Trả về phản hồi cuối cùng
        end
      else
        json_data = build_text_payload(zalo_account, request)
        send_api_request(zalo_account, url, json_data)
      end
    end

    def upload_attachments(zalo_account, request)
      return [] unless request[:files]&.any?

      @logger.info "[Zalo::Service] Tải file đính kèm cho tài khoản: #{zalo_account.zalo_id}"
      return nil if request[:files].size > MAX_FILES

      results = []
      request[:files].each do |file|
        next if file.nil? || file.size == 0 || file.size > MAX_SIZE_FILE

        file_name = file.original_filename
        file_extension = File.extname(file_name).downcase[1..-1]
        file_type = get_file_type(file_extension)
        total_size = file.size
        total_chunks = (total_size.to_f / CHUNK_SIZE).ceil
        client_id = (Time.now.to_f * 1000).to_i

        begin
          file.tempfile.rewind
          (0...total_chunks).each do |chunk_index|
            chunk_size = [CHUNK_SIZE, total_size - (chunk_index * CHUNK_SIZE)].min
            chunk_data = file.tempfile.read(chunk_size)
            json_data = build_upload_payload(zalo_account, request, file_name, total_size, total_chunks, chunk_index + 1, client_id, file_type)

            url = Zalo::URLManager::File.upload(request[:is_group]) + get_upload_endpoint(file_type)
            response = send_file_upload_request(zalo_account, url, json_data, chunk_data, file_name)
            return nil unless response[:success]

            if response[:data]['finished'] == 1
              inner_data = response[:data]['data']
              case file_type
              when 'image'
                results << {
                  file_type: 'image',
                  photo_id: inner_data['photo_id'],
                  width: inner_data['width'],
                  height: inner_data['height'],
                  hd_url: inner_data['hd_url'],
                  hd_size: inner_data['hd_size'],
                  endpoint: 'photo_original/send?'
                }
              when 'video'
                results << {
                  file_type: 'video',
                  file_id: inner_data['file_id'],
                  file_name: file_name,
                  total_size: total_size,
                  file_url: inner_data['file_url'],
                  checksum: calculate_md5(file.tempfile),
                  endpoint: 'asyncfile/msg?'
                }
              else
                results << {
                  file_type: 'others',
                  file_id: inner_data['file_id'],
                  file_name: file_name,
                  total_size: total_size,
                  file_url: inner_data['file_url'],
                  checksum: calculate_md5(file.tempfile),
                  endpoint: 'asyncfile/msg?'
                }
              end
            end
          end
        ensure
          file.tempfile.rewind
        end
      end
      results
    end

    def build_file_payload(zalo_account, request, file_attachment, is_multi_file, group_layout_id, id_in_group)
      case file_attachment[:file_type]
      when 'image'
        {
          photo_id: file_attachment[:photo_id],
          client_id: (Time.now.to_f * 1000).to_i,
          desc: is_multi_file ? nil : request[:content],
          width: file_attachment[:width],
          height: file_attachment[:height],
          toid: request[:is_group] ? nil : request[:conversation_id],
          grid: request[:is_group] ? request[:conversation_id] : nil,
          raw_url: file_attachment[:hd_url],
          thumb_url: file_attachment[:hd_url],
          ori_url: request[:is_group] ? file_attachment[:hd_url] : nil,
          normal_url: request[:is_group] ? nil : file_attachment[:hd_url],
          hd_url: file_attachment[:hd_url],
          hd_size: file_attachment[:hd_size],
          zsource: -1,
          jcp: { convertible: 'jxl' }.to_json,
          ttl: 0,
          imei: request[:member_id] ? nil : zalo_account.imei,
          group_layout_id: is_multi_file ? group_layout_id : nil,
          is_group_layout: is_multi_file ? 1 : nil,
          id_in_group: is_multi_file ? id_in_group : nil,
          total_item_in_group: is_multi_file ? file_attachment.size : nil,
          mention_info: build_mention_info(request)
        }
      when 'video'
        {
          file_id: file_attachment[:file_id],
          checksum: file_attachment[:checksum],
          checksum_sha: '',
          extension: File.extname(file_attachment[:file_name]).downcase[1..-1],
          height: file_attachment[:total_size],
          file_name: file_attachment[:file_name],
          client_id: (Time.now.to_f * 1000).to_i,
          f_type: 1,
          file_count: 0,
          fdata: {},
          toid: request[:is_group] ? nil : request[:conversation_id],
          grid: request[:is_group] ? request[:conversation_id] : nil,
          file_url: file_attachment[:file_url],
          zsource: -1,
          ttl: 0,
          imei: zalo_account.imei
        }
      else
        {
          file_id: file_attachment[:file_id],
          checksum: file_attachment[:checksum],
          checksum_sha: '',
          extension: File.extname(file_attachment[:file_name]).downcase[1..-1],
          total_size: file_attachment[:total_size],
          file_name: file_attachment[:file_name],
          client_id: (Time.now.to_f * 1000).to_i,
          f_type: 1,
          file_count: 0,
          fdata: {},
          toid: request[:is_group] ? nil : request[:conversation_id],
          grid: request[:is_group] ? request[:conversation_id] : nil,
          file_url: file_attachment[:file_url],
          zsource: -1,
          ttl: 0,
          imei: zalo_account.imei
        }
      end.to_json
    end

    def build_text_payload(zalo_account, request)
      {
        message: request[:content],
        client_id: (Time.now.to_f * 1000).to_i,
        imei: request[:member_id] ? nil : zalo_account.imei,
        ttl: 0,
        visibility: request[:is_group] ? 0 : nil,
        toid: request[:is_group] ? nil : request[:conversation_id],
        grid: request[:is_group] ? request[:conversation_id] : nil,
        mention_info: build_mention_info(request)
      }.to_json
    end

    def build_upload_payload(zalo_account, request, file_name, total_size, total_chunks, chunk_id, client_id, file_type)
      {
        total_chunk: total_chunks,
        file_name: file_name,
        client_id: client_id,
        total_size: total_size,
        imei: zalo_account.imei,
        chunk_id: chunk_id,
        toid: request[:is_group] ? nil : request[:conversation_id],
        grid: request[:is_group] ? request[:conversation_id] : nil,
        is_e2ee: 0,
        jxl: file_type == 'image' ? 1 : 0
      }.to_json
    end

    def build_mention_info(request)
      return nil unless request[:member_id]
      [
        {
          pos: 0,
          len: 15,
          uid: request[:member_id],
          type: request[:member_id] == '-1' ? 1 : 0
        }
      ].to_json
    end

    def send_api_request(zalo_account, url, json_data)
      json_data = remove_nulls(JSON.parse(json_data))
      extra_params = {
        'params' => Zalo::CryptoHelper.encode_aes(zalo_account.secret_key, json_data),
        'nretry' => '0'
      }
      full_url = Zalo::CryptoHelper.make_url(zalo_account, url, extra_params)

      @logger.info "[Zalo::Service] Gửi yêu cầu API: #{full_url}"
      response = @http_client.post(full_url)
      return { success: false, error: "Yêu cầu API thất bại: #{response.status}" } unless response.status == 200

      parsed = JSON.parse(response.body)
      data = parsed['data']
      return { success: false, error: 'Không có dữ liệu phản hồi' } unless data

      decoded = Zalo::CryptoHelper.decode_aes(zalo_account.secret_key, data)
      decoded_data = JSON.parse(decoded)
      { success: true, data: decoded_data }
    rescue => e
      @logger.error "[Zalo::Service] Lỗi gửi yêu cầu API: #{e.message}"
      { success: false, error: "Lỗi gửi yêu cầu API: #{e.message}" }
    end

    def send_file_upload_request(zalo_account, url, json_data, chunk_data, file_name)
      json_data = remove_nulls(JSON.parse(json_data))
      extra_params = {
        'params' => Zalo::CryptoHelper.encode_aes(zalo_account.secret_key, json_data),
        'type' => request[:is_group] ? '11' : '2'
      }
      full_url = Zalo::CryptoHelper.make_url(zalo_account, url, extra_params)

      @logger.info "[Zalo::Service] Tải file lên: #{full_url}"
      response = @http_client.post(full_url,
                                   form: {
                                     chunk_content: HTTP::FormData::File.new(StringIO.new(chunk_data), filename: file_name, content_type: 'application/octet-stream')
                                   },
                                   headers: { 'Content-Type' => 'multipart/form-data' }
      )
      return { success: false, error: "Tải file thất bại: #{response.status}" } unless response.status == 200

      parsed = JSON.parse(response.body)
      data = parsed['data']
      return { success: false, error: 'Không có dữ liệu phản hồi' } unless data

      decoded = Zalo::CryptoHelper.decode_aes(zalo_account.secret_key, data)
      decoded_data = JSON.parse(decoded)
      { success: true, data: decoded_data }
    rescue => e
      @logger.error "[Zalo::Service] Lỗi tải file: #{e.message}"
      { success: false, error: "Lỗi tải file: #{e.message}" }
    end

    def save_message(zalo_account, request, file_attachments)
      conversation = Conversation.find_by(zalo_conversation_id: request[:conversation_id], inbox: zalo_account.inbox)
      return unless conversation

      content = request[:content].to_s.strip
      if file_attachments
        file_info = file_attachments.map do |file|
          case file[:file_type]
          when 'image'
            "Image: #{file[:hd_url]}"
          when 'video'
            "Video: #{file[:file_url]}"
          else
            "File: #{file[:file_url]}"
          end
        end.join(', ')
        content = content.empty? ? file_info : "#{content} (#{file_info})"
      end

      Message.create!(
        conversation: conversation,
        content: content,
        message_type: file_attachments ? 'attachment' : 'text',
        sender: nil, # Tin nhắn gửi đi từ đại lý
        created_at: Time.now
      )

      ActionCable.server.broadcast("conversation_#{conversation.id}", {
        sender_id: zalo_account.zalo_id,
        conversation_id: request[:conversation_id],
        content: content,
        message_type: file_attachments ? 'attachment' : 'text',
        timestamp: (Time.now.to_f * 1000).to_i
      })
      @logger.info "[Zalo::Service] Đã lưu và phát tin nhắn cho tài khoản: #{zalo_account.zalo_id}"
    end

    def update_cookies(cookie_string)
      cookies = cookie_string.split(';').map { |c| c.strip.split('=', 2) }
      cookies.each do |name, value|
        cookie = HTTP::Cookie.new(
          name: name,
          value: value,
          domain: 'chat.zalo.me',
          for_domain: true,
          path: '/'
        )
        @cookie_jar.add(cookie)
      end
    end

    def get_file_type(extension)
      case extension
      when 'jpg', 'jpeg', 'png', 'gif' then 'image'
      when 'mp4', 'avi', 'mov' then 'video'
      else 'file'
      end
    end

    def get_upload_endpoint(file_type)
      case file_type
      when 'image' then 'photo_original/upload'
      else 'asyncfile/upload'
      end
    end

    def calculate_md5(file)
      file.rewind
      Digest::MD5.hexdigest(file.read)
    end

    def remove_nulls(hash)
      hash.reject { |k, v| v.nil? }
    end
  end
end
