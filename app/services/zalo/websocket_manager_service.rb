require 'singleton'
require 'faye/websocket'
require 'eventmachine'
require 'concurrent'

module Zalo
  class WebsocketManagerService
    include Singleton

    # URL của Zalo WebSocket
    ZALO_WS_URL = "wss://ws2-msg.chat.zalo.me/?zpw_ver=655&zpw_type=30&t="

    def initialize
      @listeners = Concurrent::Hash.new # Thread-safe hash
      @lock = Mutex.new
      # Dữ liệu được lưu trữ tạm thời khi nhận từ WebSocket
      @message_buffers = Concurrent::Hash.new
      @client_connections = Concurrent::Hash.new
      @disconnect_timers = Concurrent::Hash.new
      @auto_disconnect = true
      ensure_eventmachine_running
    end

    def start_listener_for(zalo_channel)
      channel_id = zalo_channel.id
      return unless zalo_channel.is_a?(::Channel::Zalo) &&
                    zalo_channel.cookie_data.present? &&
                    zalo_channel.secret_key.present?

      return if listener_exists?(channel_id)

      Rails.logger.info "[ZaloWSManager] Starting listener for Zalo Channel ID: #{channel_id}"

      zalo_cookie = zalo_channel.cookie_data
      user_agent = Zalo::LoginService::DEFAULT_USER_AGENT

      @lock.synchronize do
        return if @listeners.key?(channel_id)

        thread = Thread.new do
          # Khởi tạo EventMachine loop nếu chưa chạy
          EM.run do
            # Tạo timestamp cho URL
            timestamp = (Time.now.to_f * 1000).to_i
            ws_url = "#{ZALO_WS_URL}#{timestamp}"
            
            # Tạo headers cho WebSocket
            ws_headers = {
              'Cookie' => zalo_cookie,
              'User-Agent' => user_agent
            }
            
            # Khởi tạo WebSocket client
            ws = Faye::WebSocket::Client.new(ws_url, nil, { 
              headers: ws_headers,
              ping: 30 # Gửi ping mỗi 30 giây để giữ kết nối
            })
            
            # Khởi tạo buffer cho channel này
            @message_buffers[channel_id] = []
            
            # Xử lý sự kiện khi kết nối được mở
            ws.on :open do |event|
              Rails.logger.info "[ZaloWS Client - Channel #{channel_id}] Connection established!"
              zalo_channel.update(last_activity_at: Time.current)
              
              # Thông báo cho tất cả client thông qua ActionCable
              broadcast_status_to_clients(channel_id, { status: "connected", message: "WebSocket connection established" })
            end
            
            # Xử lý sự kiện khi nhận được tin nhắn
            ws.on :message do |event|
              begin
                # Cập nhật thời gian hoạt động
                zalo_channel.update(last_activity_at: Time.current)
                
                data = event.data
                # Xử lý dữ liệu nhận được (có thể là chuỗi hoặc dữ liệu nhị phân)
                if data.is_a?(String)
                  # Dữ liệu văn bản (JSON)
                  parsed_data = JSON.parse(data)
                  process_text_message(zalo_channel, parsed_data)
                else
                  # Dữ liệu nhị phân (mã hóa)
                  process_binary_message(zalo_channel, data)
                end
              rescue => e
                Rails.logger.error "[ZaloWS Client - Channel #{channel_id}] Error processing message: #{e.message}\n#{e.backtrace.join("\n")}"
              end
            end
            
            # Xử lý sự kiện khi đóng kết nối
            ws.on :close do |event|
              Rails.logger.info "[ZaloWS Client - Channel #{channel_id}] Connection closed: code=#{event.code}, reason=#{event.reason}"
              
              # Thông báo cho tất cả client thông qua ActionCable
              broadcast_status_to_clients(channel_id, { status: "disconnected", message: "WebSocket connection closed" })
              
              # Xóa message buffer
              @message_buffers.delete(channel_id)
              
              # Thử kết nối lại sau 30 giây nếu không phải đóng có chủ ý
              if event.code != 1000 # 1000 là mã đóng bình thường
                Rails.logger.info "[ZaloWS Client - Channel #{channel_id}] Reconnecting in 30 seconds..."
                EM.add_timer(30) do
                  # Thử kết nối lại với cùng cookie và headers
                  ws = Faye::WebSocket::Client.new(ZALO_WS_URL + (Time.now.to_f * 1000).to_i.to_s, nil, { 
                    headers: ws_headers,
                    ping: 30
                  })
                end
              end
            end
            
            # Lưu WebSocket client vào hash để quản lý
            @listeners[channel_id] = { thread: thread, client: ws, channel_instance: zalo_channel }
          end

          Rails.logger.info "[ZaloWS Client - Channel #{channel_id}] EventMachine loop stopped."
        end

        @listeners[channel_id] = { thread: thread, channel_instance: zalo_channel }
        Rails.logger.info "[ZaloWSManager] Listener thread created for Zalo Channel ID: #{channel_id}"
      end
    end

    def stop_listener_for(channel_id)
      @lock.synchronize do
        listener_info = @listeners.delete(channel_id)
        if listener_info
          Rails.logger.info "[ZaloWSManager] Stopping listener for Zalo Channel ID: #{channel_id}"
          client = listener_info[:client]
          if client && client.respond_to?(:close)
             # Đóng kết nối WebSocket
             client.close(1000, "Closed by application")
          end
          Rails.logger.info "[ZaloWSManager] Listener commanded to stop for Zalo Channel ID: #{channel_id}"
        end
      end
    end

    def listener_exists?(channel_id)
      @listeners.key?(channel_id)
    end

    def stop_all_listeners
      Rails.logger.info "[ZaloWSManager] Stopping all Zalo listeners..."
      @listeners.keys.each do |channel_id|
        stop_listener_for(channel_id)
      end
      Rails.logger.info "[ZaloWSManager] All Zalo listeners commanded to stop."
    end
    
    # Lấy tin nhắn từ buffer của channel
    def get_messages_for_channel(channel_id, limit = 50)
      buffer = @message_buffers[channel_id] || []
      buffer.last(limit)
    end
    
    # Lấy thông tin các kết nối hiện tại
    def get_active_connections
      @listeners.map do |channel_id, info|
        client = info[:client]
        channel = info[:channel_instance]
        {
          channel_id: channel_id,
          zalo_id: channel&.zalo_id,
          connected: client&.respond_to?(:ready_state) ? client.ready_state == Faye::WebSocket::API::OPEN : false,
          last_activity: channel&.last_activity_at
        }
      end
    end

    # Support for multiple clients connected to the same WebSocket
    def client_connected(user_id, channel_id)
      Rails.logger.debug "[Zalo::WebsocketManagerService] Client connected for user #{user_id} to channel #{channel_id}"
      
      # Keep track of connected clients
      @lock.synchronize do
        @client_connections[channel_id] ||= Set.new
        @client_connections[channel_id].add(user_id)
      end
    end
    
    def client_disconnected(user_id, channel_id)
      Rails.logger.debug "[Zalo::WebsocketManagerService] Client disconnected for user #{user_id} from channel #{channel_id}"
      
      @lock.synchronize do
        if @client_connections.key?(channel_id)
          @client_connections[channel_id].delete(user_id)
          
          # If no clients are connected, stop the WebSocket after a delay
          if @client_connections[channel_id].empty? && @auto_disconnect
            Rails.logger.info "[Zalo::WebsocketManagerService] No clients connected to channel #{channel_id}, scheduling disconnect"
            
            # Cancel any existing disconnect timer
            if @disconnect_timers[channel_id]
              @disconnect_timers[channel_id].cancel
              @disconnect_timers.delete(channel_id)
            end
            
            # Set a new disconnect timer (5 minutes)
            @disconnect_timers[channel_id] = Concurrent::TimerTask.new(execution_interval: 300) do
              check_and_disconnect_if_no_clients(channel_id)
            end
            @disconnect_timers[channel_id].execute
          end
        end
      end
    end
    
    def check_and_disconnect_if_no_clients(channel_id)
      @lock.synchronize do
        if @client_connections.key?(channel_id) && @client_connections[channel_id].empty?
          Rails.logger.info "[Zalo::WebsocketManagerService] Auto-disconnecting WebSocket for channel #{channel_id} due to inactivity"
          stop_listener_for(channel_id)
          @disconnect_timers.delete(channel_id)
        end
      end
    end
    
    def client_count_for_channel(channel_id)
      @lock.synchronize do
        return 0 unless @client_connections.key?(channel_id)
        @client_connections[channel_id].size
      end
    end
    
    def has_clients?(channel_id)
      client_count_for_channel(channel_id) > 0
    end
    
    def auto_disconnect=(value)
      @auto_disconnect = value
    end

    private

    def ensure_eventmachine_running
      return if defined?(@eventmachine_thread) && @eventmachine_thread&.alive? && EM.reactor_running?

      @lock.synchronize do
        return if defined?(@eventmachine_thread) && @eventmachine_thread&.alive? && EM.reactor_running?

        @eventmachine_thread = Thread.new do
          # Nếu EventMachine chưa chạy thì khởi động nó
          unless EM.reactor_running?
            EM.run do
              Rails.logger.info "[ZaloWSManager] EventMachine reactor started."
            end
          else
            Rails.logger.info "[ZaloWSManager] EventMachine reactor already running."
          end
        end

        sleep 0.1 until (EM.reactor_running? rescue false)
        Rails.logger.info "[ZaloWSManager] EventMachine reactor running: #{EM.reactor_running?}"
      end
    end
    
    # Xử lý tin nhắn văn bản (JSON) từ WebSocket
    def process_text_message(zalo_channel, parsed_data)
      Rails.logger.debug "[ZaloWS Client] Received text message: #{parsed_data.to_json}"
      
      # Lưu tin nhắn vào buffer
      @message_buffers[zalo_channel.id] ||= []
      @message_buffers[zalo_channel.id] << parsed_data
      
      # Giới hạn kích thước buffer
      if @message_buffers[zalo_channel.id].size > 100
        @message_buffers[zalo_channel.id].shift # Loại bỏ tin nhắn cũ nhất
      end
      
      # Broadcast tin nhắn đến tất cả client qua ActionCable
      broadcast_message_to_clients(zalo_channel.id, parsed_data)
      
      # Xử lý tin nhắn dựa vào loại
      case parsed_data['event_name']
      when 'chat'
        process_chat_message(zalo_channel, parsed_data)
      when 'presence'
        process_presence_update(zalo_channel, parsed_data)
      when 'delivery'
        process_delivery_receipt(zalo_channel, parsed_data)
      else
        Rails.logger.info "[ZaloWS Client] Unhandled text message type: #{parsed_data['event_name']}"
      end
    end
    
    # Xử lý tin nhắn nhị phân (thường là dữ liệu mã hóa) từ WebSocket
    def process_binary_message(zalo_channel, binary_data)
      Rails.logger.debug "[ZaloWS Client] Received binary message, length: #{binary_data.bytesize}"
      
      begin
        # Giải mã dữ liệu nhị phân với secret key
        decrypted_data = decrypt_binary_message(zalo_channel, binary_data)
        
        if decrypted_data
          # Parse JSON từ dữ liệu giải mã
          parsed_data = JSON.parse(decrypted_data)
          
          # Xử lý tương tự như tin nhắn văn bản
          process_text_message(zalo_channel, parsed_data)
        else
          Rails.logger.error "[ZaloWS Client] Failed to decrypt binary message"
        end
      rescue => e
        Rails.logger.error "[ZaloWS Client] Error processing binary message: #{e.message}\n#{e.backtrace.join("\n")}"
      end
    end
    
    # Giải mã dữ liệu nhị phân từ WebSocket
    def decrypt_binary_message(zalo_channel, binary_data)
      return nil unless zalo_channel.secret_key.present?
      
      begin
        encryption_service = Zalo::EncryptionService.new(zalo_channel)
        decrypted_data = encryption_service.decrypt_websocket_message(binary_data, zalo_channel.secret_key)
        decrypted_data
      rescue => e
        Rails.logger.error "[ZaloWS Client] Decryption error: #{e.message}"
        nil
      end
    end
    
    # Xử lý tin nhắn chat
    def process_chat_message(zalo_channel, message_data)
      Rails.logger.info "[ZaloWS Client] Processing chat message: #{message_data['msg_id']}"
      
      # Kiểm tra xem tin nhắn có phải từ người dùng khác không
      if message_data['from_id'] != zalo_channel.zalo_id
        # Tạo conversation và message trong Chatwoot
        create_chatwoot_conversation(zalo_channel, message_data)
      end
    end
    
    # Xử lý cập nhật trạng thái online/offline
    def process_presence_update(zalo_channel, presence_data)
      Rails.logger.info "[ZaloWS Client] Processing presence update: #{presence_data['user_id']} is #{presence_data['status']}"
      
      # Broadcast trạng thái hiện diện đến tất cả client
      broadcast_status_to_clients(zalo_channel.id, { 
        status: "presence_update", 
        user_id: presence_data['user_id'], 
        presence: presence_data['status'] 
      })
    end
    
    # Xử lý biên nhận tin nhắn đã gửi
    def process_delivery_receipt(zalo_channel, receipt_data)
      Rails.logger.info "[ZaloWS Client] Processing delivery receipt: #{receipt_data['msg_id']} status: #{receipt_data['status']}"
      
      # Cập nhật trạng thái tin nhắn trong Chatwoot nếu cần
      update_chatwoot_message_status(zalo_channel, receipt_data)
    end
    
    # Tạo conversation và message trong Chatwoot
    def create_chatwoot_conversation(zalo_channel, message_data)
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          account_id = zalo_channel.account_id
          sender_id = message_data['from_id']
          message_content = message_data['content']
          message_type = message_data['type'] || 'text'
          
          # Tìm hoặc tạo contact
          contact = Contact.find_or_initialize_by(
            account_id: account_id,
            identifier: sender_id,
            inbox: zalo_channel.inbox
          )
          
          if contact.new_record?
            # Lấy thông tin người dùng từ Zalo API nếu cần
            contact.name = message_data['sender_name'] || "Zalo User #{sender_id}"
            contact.save!
          end
          
          # Tìm hoặc tạo conversation
          conversation = Conversation.find_or_initialize_by(
            account_id: account_id,
            inbox_id: zalo_channel.inbox.id,
            contact_id: contact.id
          )
          
          if conversation.new_record?
            conversation.status = Conversation.statuses[:open]
            conversation.save!
          end
          
          # Tạo message
          case message_type
          when 'text'
            conversation.messages.create!(
              account_id: account_id,
              message_type: :incoming,
              content: message_content,
              sender: contact,
              source_id: message_data['msg_id']
            )
          when 'image'
            attachment_url = message_data['attachment_url']
            attachment_file = nil
            
            # Tải xuống hình ảnh nếu có URL
            if attachment_url.present?
              attachment_file = download_attachment(attachment_url)
            end
            
            message = conversation.messages.new(
              account_id: account_id,
              message_type: :incoming,
              content: message_data['caption'] || '',
              sender: contact,
              source_id: message_data['msg_id']
            )
            
            if attachment_file
              message.attachments.new(
                account_id: account_id,
                file_type: 'image',
                file: attachment_file
              )
            end
            
            message.save!
          when 'file'
            attachment_url = message_data['attachment_url']
            attachment_file = nil
            
            # Tải xuống file nếu có URL
            if attachment_url.present?
              attachment_file = download_attachment(attachment_url)
            end
            
            message = conversation.messages.new(
              account_id: account_id,
              message_type: :incoming,
              content: message_data['caption'] || '',
              sender: contact,
              source_id: message_data['msg_id']
            )
            
            if attachment_file
              message.attachments.new(
                account_id: account_id,
                file_type: 'file',
                file: attachment_file
              )
            end
            
            message.save!
          else
            # Loại tin nhắn khác
            conversation.messages.create!(
              account_id: account_id,
              message_type: :incoming,
              content: "Unsupported message type: #{message_type}",
              sender: contact,
              source_id: message_data['msg_id']
            )
          end
          
          # Cập nhật conversation
          conversation.update!(
            last_activity_at: Time.current,
            updated_at: Time.current
          )
        rescue => e
          Rails.logger.error "[ZaloWS Client] Error creating conversation: #{e.message}\n#{e.backtrace.join("\n")}"
        end
      end
    end
    
    # Cập nhật trạng thái tin nhắn trong Chatwoot
    def update_chatwoot_message_status(zalo_channel, receipt_data)
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          message = Message.find_by(source_id: receipt_data['msg_id'])
          
          if message
            # Cập nhật trạng thái tin nhắn
            case receipt_data['status']
            when 'delivered'
              message.update(status: 'delivered')
            when 'read'
              message.update(status: 'read')
            end
          end
        rescue => e
          Rails.logger.error "[ZaloWS Client] Error updating message status: #{e.message}"
        end
      end
    end
    
    # Tải xuống file đính kèm từ URL
    def download_attachment(url)
      begin
        attachment_response = HTTParty.get(url)
        
        if attachment_response.success?
          # Tạo file tạm
          file = Tempfile.new(['zalo_attachment', File.extname(url)])
          file.binmode
          file.write(attachment_response.body)
          file.rewind
          
          return file
        end
      rescue => e
        Rails.logger.error "[ZaloWS Client] Error downloading attachment: #{e.message}"
      end
      
      nil
    end
    
    # Broadcast tin nhắn đến tất cả client qua ActionCable
    def broadcast_message_to_clients(channel_id, message)
      Rails.logger.debug "[ZaloWS Client] Broadcasting message to clients: #{channel_id}"
      
      begin
        ActionCable.server.broadcast(
          "zalo_channel_#{channel_id}",
          { event: 'message', data: message }
        )
      rescue => e
        Rails.logger.error "[ZaloWS Client] Error broadcasting message: #{e.message}"
      end
    end
    
    # Broadcast trạng thái đến tất cả client qua ActionCable
    def broadcast_status_to_clients(channel_id, status)
      Rails.logger.debug "[ZaloWS Client] Broadcasting status to clients: #{channel_id}"
      
      begin
        ActionCable.server.broadcast(
          "zalo_channel_#{channel_id}",
          { event: 'status', data: status }
        )
      rescue => e
        Rails.logger.error "[ZaloWS Client] Error broadcasting status: #{e.message}"
      end
    end
  end
end