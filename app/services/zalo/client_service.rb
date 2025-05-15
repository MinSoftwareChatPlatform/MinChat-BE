require 'httparty'
require 'json'

module Zalo
  class ClientService
    # URL cơ bản từ ZaloURLManager
    MESSAGE_API_BASE_URL = "https://tt-chat2-wpa.chat.zalo.me/api/message"
    SEND_MESSAGE_ENDPOINT = "#{MESSAGE_API_BASE_URL}/sms"
    FILE_API_BASE_URL = "https://tt-files-wpa.chat.zalo.me/api"
    
    # Constants
    CHUNK_SIZE = 512 * 1024 # 512KB
    MAX_FILE_SIZE = 1024 * 1024 * 1024 # 1GB

    attr_reader :channel, :encryption_service

    def initialize(channel)
      @channel = channel
      @encryption_service = Zalo::EncryptionService.new(channel)
      @http_client_options = {
        headers: {
          'User-Agent' => Zalo::LoginService::DEFAULT_USER_AGENT,
          'Content-Type' => 'application/json',
          'Cookie' => channel.cookie_data.to_s
        }
      }
    end

    # Gửi tin nhắn văn bản
    def send_text_message(recipient_zalo_id, text_content)
      Rails.logger.info "[Zalo::ClientService] Sending text to #{recipient_zalo_id}: #{text_content}"
      
      client_msg_id = "chatwoot_#{SecureRandom.hex(8)}_#{Time.now.to_i}"
      
      # Chuẩn bị tham số
      params = {
        'toid' => recipient_zalo_id,
        'msg' => text_content,
        'clientid' => client_msg_id,
        'uid' => channel.zalo_id,
        't' => Time.now.to_i.to_s
      }
      
      # Mã hóa tham số
      encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'sendmsg')
      
      # Tạo payload
      payload = {
        'params' => encrypted_data[:params],
        'encrypted' => encrypted_data[:encrypted_params],
        'signature' => encrypted_data[:signkey]
      }
      
      # Gửi request
      response = HTTParty.post(
        SEND_MESSAGE_ENDPOINT,
        body: payload.to_json,
        **@http_client_options
      )
      
      # Xử lý response
      if response.success?
        parsed_response = JSON.parse(response.body)
        
        if parsed_response['error_code'] == 0
          msg_id = parsed_response.dig('data', 'msgId') || client_msg_id
          return { success: true, platform_message_id: msg_id }
        else
          error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
          Rails.logger.error "[Zalo::ClientService] Send message failed: #{error_msg}"
          return { success: false, error: error_msg, error_code: parsed_response['error_code'] }
        end
      else
        Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
        return { success: false, error: "HTTP Error: #{response.code}" }
      end
    rescue => e
      Rails.logger.error "[Zalo::ClientService] Exception: #{e.message}\n#{e.backtrace.join("\n")}"
      { success: false, error: "Error sending message: #{e.message}" }
    end
    
    # Gửi ảnh
    def send_image_message(recipient_zalo_id, image_path, caption = nil)
      Rails.logger.info "[Zalo::ClientService] Sending image to #{recipient_zalo_id}"
      
      begin
        # Kiểm tra file tồn tại
        unless File.exist?(image_path)
          return { success: false, error: "Image file not found: #{image_path}" }
        end
        
        # Tạo thông tin tệp và tải lên
        file_info = {
          filename: File.basename(image_path),
          file_path: image_path,
          mime_type: Marcel::MimeType.for(File.open(image_path)),
          size: File.size(image_path),
          attachment_type: 'image'
        }
        
        upload_result = upload_file(recipient_zalo_id, file_info)
        
        return upload_result unless upload_result[:success]
        
        # Nếu tải lên thành công, gửi tin nhắn ảnh
        client_msg_id = "chatwoot_img_#{SecureRandom.hex(8)}_#{Time.now.to_i}"
        
        params = {
          'toid' => recipient_zalo_id,
          'clientid' => client_msg_id,
          'uid' => channel.zalo_id,
          't' => Time.now.to_i.to_s,
          'image_id' => upload_result[:attachment_id]
        }
        
        params['caption'] = caption if caption.present?
        
        # Mã hóa tham số
        encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'sendimage')
        
        # Tạo URL dựa vào loại tệp
        endpoint = "#{FILE_API_BASE_URL}/message/photo_original/send"
        
        # Tạo payload
        payload = {
          'params' => encrypted_data[:params],
          'encrypted' => encrypted_data[:encrypted_params],
          'signature' => encrypted_data[:signkey]
        }
        
        # Gửi request
        response = HTTParty.post(
          endpoint,
          body: payload.to_json,
          **@http_client_options
        )
        
        # Xử lý response
        if response.success?
          parsed_response = JSON.parse(response.body)
          
          if parsed_response['error_code'] == 0
            msg_id = parsed_response.dig('data', 'msgId') || client_msg_id
            return { success: true, platform_message_id: msg_id }
          else
            error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
            Rails.logger.error "[Zalo::ClientService] Send image failed: #{error_msg}"
            return { success: false, error: error_msg, error_code: parsed_response['error_code'] }
          end
        else
          Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
          return { success: false, error: "HTTP Error: #{response.code}" }
        end
      rescue => e
        Rails.logger.error "[Zalo::ClientService] Exception: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error sending image: #{e.message}" }
      end
    end
    
    # Gửi file
    def send_file_message(recipient_zalo_id, file_path, caption = nil)
      Rails.logger.info "[Zalo::ClientService] Sending file to #{recipient_zalo_id}"
      
      begin
        # Kiểm tra file tồn tại
        unless File.exist?(file_path)
          return { success: false, error: "File not found: #{file_path}" }
        end
        
        # Kiểm tra kích thước
        file_size = File.size(file_path)
        if file_size > MAX_FILE_SIZE
          return { success: false, error: "File too large. Maximum size is 1GB" }
        end
        
        # Xác định loại file
        mime_type = Marcel::MimeType.for(File.open(file_path))
        file_info = {
          filename: File.basename(file_path),
          file_path: file_path,
          mime_type: mime_type,
          size: file_size,
          attachment_type: get_attachment_type(mime_type)
        }
        
        upload_result = upload_file(recipient_zalo_id, file_info)
        
        return upload_result unless upload_result[:success]
        
        # Nếu tải lên thành công, gửi tin nhắn file
        client_msg_id = "chatwoot_file_#{SecureRandom.hex(8)}_#{Time.now.to_i}"
        
        params = {
          'toid' => recipient_zalo_id,
          'clientid' => client_msg_id,
          'uid' => channel.zalo_id,
          't' => Time.now.to_i.to_s,
          'file_id' => upload_result[:attachment_id]
        }
        
        params['caption'] = caption if caption.present?
        
        # Mã hóa tham số
        encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'sendfile')
        
        # Tạo URL dựa vào loại tệp
        endpoint = "#{FILE_API_BASE_URL}/message/asyncfile/msg"
        
        # Tạo payload
        payload = {
          'params' => encrypted_data[:params],
          'encrypted' => encrypted_data[:encrypted_params],
          'signature' => encrypted_data[:signkey]
        }
        
        # Gửi request
        response = HTTParty.post(
          endpoint,
          body: payload.to_json,
          **@http_client_options
        )
        
        # Xử lý response
        if response.success?
          parsed_response = JSON.parse(response.body)
          
          if parsed_response['error_code'] == 0
            msg_id = parsed_response.dig('data', 'msgId') || client_msg_id
            return { success: true, platform_message_id: msg_id }
          else
            error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
            Rails.logger.error "[Zalo::ClientService] Send file failed: #{error_msg}"
            return { success: false, error: error_msg, error_code: parsed_response['error_code'] }
          end
        else
          Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
          return { success: false, error: "HTTP Error: #{response.code}" }
        end
      rescue => e
        Rails.logger.error "[Zalo::ClientService] Exception: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error sending file: #{e.message}" }
      end
    end
    
    # Friend management methods
    
    # Kiểm tra trạng thái bạn bè
    def check_friend_status(zalo_user_id)
      Rails.logger.info "[Zalo::ClientService] Checking friend status for #{zalo_user_id}"
      
      begin
        # Chuẩn bị tham số
        params = {
          'uid' => channel.zalo_id,
          'friend_uid' => zalo_user_id,
          't' => Time.now.to_i.to_s
        }
        
        # Mã hóa tham số
        encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'friendstatus')
        
        # Tạo URL
        url = Zalo::URLManager::Friend::GET_STATUS
        
        # Tạo payload
        payload = {
          'params' => encrypted_data[:params],
          'encrypted' => encrypted_data[:encrypted_params],
          'signature' => encrypted_data[:signkey]
        }
        
        # Gửi request
        response = HTTParty.post(
          url,
          body: payload.to_json,
          **@http_client_options
        )
        
        # Xử lý response
        if response.success?
          parsed_response = JSON.parse(response.body)
          
          if parsed_response['error_code'] == 0
            status_data = parsed_response.dig('data', 'status')
            status = case status_data
                    when 0
                      'not_friend'
                    when 1
                      'friend'
                    when 2
                      'requested_by_me'
                    when 3
                      'requested_by_them'
                    else
                      'unknown'
                    end
            
            return { success: true, status: status }
          else
            error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
            Rails.logger.error "[Zalo::ClientService] Friend status check failed: #{error_msg}"
            return { success: false, error: error_msg, error_code: parsed_response['error_code'] }
          end
        else
          Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
          return { success: false, error: "HTTP Error: #{response.code}" }
        end
      rescue => e
        Rails.logger.error "[Zalo::ClientService] Exception: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error checking friend status: #{e.message}" }
      end
    end
    
    # Gửi lời mời kết bạn
    def send_friend_request(zalo_user_id, message = nil)
      Rails.logger.info "[Zalo::ClientService] Sending friend request to #{zalo_user_id}"
      
      begin
        # Chuẩn bị tham số
        params = {
          'uid' => channel.zalo_id,
          'friend_uid' => zalo_user_id,
          't' => Time.now.to_i.to_s
        }
        
        params['message'] = message if message.present?
        
        # Mã hóa tham số
        encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'sendfriendrequest')
        
        # Tạo URL
        url = Zalo::URLManager::Friend::SEND_REQUEST
        
        # Tạo payload
        payload = {
          'params' => encrypted_data[:params],
          'encrypted' => encrypted_data[:encrypted_params],
          'signature' => encrypted_data[:signkey]
        }
        
        # Gửi request
        response = HTTParty.post(
          url,
          body: payload.to_json,
          **@http_client_options
        )
        
        # Xử lý response
        if response.success?
          parsed_response = JSON.parse(response.body)
          
          if parsed_response['error_code'] == 0
            return { success: true }
          else
            error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
            Rails.logger.error "[Zalo::ClientService] Friend request failed: #{error_msg}"
            return { success: false, error: error_msg, error_code: parsed_response['error_code'] }
          end
        else
          Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
          return { success: false, error: "HTTP Error: #{response.code}" }
        end
      rescue => e
        Rails.logger.error "[Zalo::ClientService] Exception: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error sending friend request: #{e.message}" }
      end
    end
    
    # Chấp nhận lời mời kết bạn
    def accept_friend_request(zalo_user_id)
      Rails.logger.info "[Zalo::ClientService] Accepting friend request from #{zalo_user_id}"
      
      begin
        # Chuẩn bị tham số
        params = {
          'uid' => channel.zalo_id,
          'friend_uid' => zalo_user_id,
          't' => Time.now.to_i.to_s
        }
        
        # Mã hóa tham số
        encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'acceptfriend')
        
        # Tạo URL
        url = Zalo::URLManager::Friend::ACCEPT
        
        # Tạo payload
        payload = {
          'params' => encrypted_data[:params],
          'encrypted' => encrypted_data[:encrypted_params],
          'signature' => encrypted_data[:signkey]
        }
        
        # Gửi request
        response = HTTParty.post(
          url,
          body: payload.to_json,
          **@http_client_options
        )
        
        # Xử lý response
        if response.success?
          parsed_response = JSON.parse(response.body)
          
          if parsed_response['error_code'] == 0
            return { success: true }
          else
            error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
            Rails.logger.error "[Zalo::ClientService] Friend accept failed: #{error_msg}"
            return { success: false, error: error_msg, error_code: parsed_response['error_code'] }
          end
        else
          Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
          return { success: false, error: "HTTP Error: #{response.code}" }
        end
      rescue => e
        Rails.logger.error "[Zalo::ClientService] Exception: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error accepting friend request: #{e.message}" }
      end
    end
    
    private
    
    # Tải lên file
    def upload_file(recipient_id, file_info)
      Rails.logger.info "[Zalo::ClientService] Uploading #{file_info[:attachment_type]} file: #{file_info[:filename]}"
      
      begin
        file_path = file_info[:file_path]
        file_size = file_info[:size]
        
        # Tính toán số lượng phần
        num_chunks = (file_size.to_f / CHUNK_SIZE).ceil
        
        # Tạo một phiên tải lên
        upload_session = init_upload_session(recipient_id, file_info)
        
        return { success: false, error: upload_session[:error] } unless upload_session[:success]
        
        session_id = upload_session[:session_id]
        
        # Tải lên từng phần
        File.open(file_path, 'rb') do |file|
          num_chunks.times do |chunk_index|
            offset = chunk_index * CHUNK_SIZE
            file.seek(offset)
            chunk_data = file.read([CHUNK_SIZE, file_size - offset].min)
            
            # Tải lên phần
            chunk_result = upload_chunk(session_id, chunk_data, chunk_index, num_chunks)
            
            return { success: false, error: chunk_result[:error] } unless chunk_result[:success]
          end
        end
        
        # Hoàn tất tải lên
        complete_result = complete_upload(session_id)
        
        return { success: false, error: complete_result[:error] } unless complete_result[:success]
        
        { 
          success: true, 
          attachment_id: complete_result[:attachment_id],
          attachment_type: file_info[:attachment_type]
        }
      rescue => e
        Rails.logger.error "[Zalo::ClientService] File upload error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: "Error uploading file: #{e.message}" }
      end
    end
    
    # Khởi tạo phiên tải lên
    def init_upload_session(recipient_id, file_info)
      client_msg_id = "chatwoot_init_#{SecureRandom.hex(8)}_#{Time.now.to_i}"
      
      # Chuẩn bị tham số
      params = {
        'toid' => recipient_id,
        'clientid' => client_msg_id,
        'uid' => channel.zalo_id,
        't' => Time.now.to_i.to_s,
        'filename' => file_info[:filename],
        'filesize' => file_info[:size],
        'filetype' => file_info[:mime_type]
      }
      
      # Mã hóa tham số
      encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'initupload')
      
      # Tạo URL dựa vào loại tệp
      endpoint_type = get_upload_endpoint_type(file_info[:attachment_type])
      endpoint = "#{FILE_API_BASE_URL}/message/#{endpoint_type}"
      
      # Tạo payload
      payload = {
        'params' => encrypted_data[:params],
        'encrypted' => encrypted_data[:encrypted_params],
        'signature' => encrypted_data[:signkey]
      }
      
      # Gửi request
      response = HTTParty.post(
        endpoint,
        body: payload.to_json,
        **@http_client_options
      )
      
      # Xử lý response
      if response.success?
        parsed_response = JSON.parse(response.body)
        
        if parsed_response['error_code'] == 0
          session_id = parsed_response.dig('data', 'session_id')
          return { success: true, session_id: session_id }
        else
          error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
          Rails.logger.error "[Zalo::ClientService] Init upload failed: #{error_msg}"
          return { success: false, error: error_msg }
        end
      else
        Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
        return { success: false, error: "HTTP Error: #{response.code}" }
      end
    end
    
    # Tải lên một phần
    def upload_chunk(session_id, chunk_data, chunk_index, total_chunks)
      # Chuẩn bị tham số
      params = {
        'session_id' => session_id,
        'chunk_index' => chunk_index,
        'total_chunks' => total_chunks
      }
      
      # Mã hóa tham số
      encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'uploadchunk')
      
      # Tạo URL
      endpoint = "#{FILE_API_BASE_URL}/message/upload_chunk"
      
      # Tạo form data cho upload
      form_data = {
        'params' => encrypted_data[:params].to_json,
        'encrypted' => encrypted_data[:encrypted_params].to_json,
        'signature' => encrypted_data[:signkey],
        'chunk_data' => HTTP::FormData::File.new(StringIO.new(chunk_data))
      }
      
      # Gửi request
      http_client_options_multipart = @http_client_options.merge({
        headers: {
          'User-Agent' => Zalo::LoginService::DEFAULT_USER_AGENT,
          'Cookie' => channel.cookie_data.to_s
        }
      })
      
      response = HTTParty.post(
        endpoint,
        multipart: true,
        body: form_data,
        **http_client_options_multipart
      )
      
      # Xử lý response
      if response.success?
        parsed_response = JSON.parse(response.body)
        
        if parsed_response['error_code'] == 0
          return { success: true }
        else
          error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
          Rails.logger.error "[Zalo::ClientService] Chunk upload failed: #{error_msg}"
          return { success: false, error: error_msg }
        end
      else
        Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
        return { success: false, error: "HTTP Error: #{response.code}" }
      end
    end
    
    # Hoàn tất tải lên
    def complete_upload(session_id)
      # Chuẩn bị tham số
      params = {
        'session_id' => session_id
      }
      
      # Mã hóa tham số
      encrypted_data = @encryption_service.encrypt_params_for_zalo_request(params, 'completeupload')
      
      # Tạo URL
      endpoint = "#{FILE_API_BASE_URL}/message/complete_upload"
      
      # Tạo payload
      payload = {
        'params' => encrypted_data[:params],
        'encrypted' => encrypted_data[:encrypted_params],
        'signature' => encrypted_data[:signkey]
      }
      
      # Gửi request
      response = HTTParty.post(
        endpoint,
        body: payload.to_json,
        **@http_client_options
      )
      
      # Xử lý response
      if response.success?
        parsed_response = JSON.parse(response.body)
        
        if parsed_response['error_code'] == 0
          attachment_id = parsed_response.dig('data', 'attachment_id')
          return { success: true, attachment_id: attachment_id }
        else
          error_msg = parsed_response['error_message'] || "Unknown Zalo error: #{parsed_response['error_code']}"
          Rails.logger.error "[Zalo::ClientService] Complete upload failed: #{error_msg}"
          return { success: false, error: error_msg }
        end
      else
        Rails.logger.error "[Zalo::ClientService] HTTP Error: #{response.code} - #{response.body}"
        return { success: false, error: "HTTP Error: #{response.code}" }
      end
    end
    
    # Xác định loại tệp đính kèm
    def get_attachment_type(mime_type)
      if mime_type.start_with?('image/')
        if mime_type == 'image/gif'
          'gif'
        else
          'image'
        end
      elsif mime_type.start_with?('video/')
        'video'
      else
        'others'
      end
    end
    
    # Lấy endpoint dựa vào loại tệp
    def get_upload_endpoint_type(attachment_type)
      case attachment_type
      when 'image'
        'photo_original/send?'
      when 'gif'
        'gif?'
      when 'video', 'others'
        'asyncfile/msg?'
      else
        'asyncfile/msg?'
      end
    end
  end
end