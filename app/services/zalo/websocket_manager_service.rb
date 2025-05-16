require 'faye/websocket'
require 'eventmachine'
require 'json'
require 'logger'
require 'redis'

module Zalo
  class WebSocketService
    WS_URL = 'wss://ws2-msg.chat.zalo.me/?zpw_ver=655&zpw_type=30&t='
    TIMEOUT_SECONDS = 5
    MAX_CONNECTIONS = 50
    INACTIVITY_TIMEOUT = 600 # 10 phút
    PING_INTERVAL = 120 # 2 phút

    attr_reader :logger, :redis, :connections, :connection_start_times

    def initialize
      @logger = Logger.new(STDOUT)
      @logger.level = Logger::INFO
      @redis = Redis.new
      @connections = {} # Registry cho các kết nối WebSocket
      @connection_start_times = {} # Thời gian bắt đầu kết nối
      @lock = Mutex.new
    end

    def start_listening(zalo_account)
      return "Thông tin Zalo không được để trống" unless zalo_account

      account_id = zalo_account.zalo_id
      @logger.info "[Zalo::WebSocketService] Bắt đầu lắng nghe cho tài khoản: #{account_id}"

      @lock.synchronize do
        return "WebSocket cho tài khoản #{account_id} đã đang chạy" if connections[account_id]
        return "Đã đạt giới hạn số lượng kết nối tối đa" if connections.size >= MAX_CONNECTIONS
      end

      begin
        ws_url = "#{WS_URL}#{Time.now.to_i}"
        ws = Faye::WebSocket::Client.new(ws_url, [],
                                         headers: { 'Cookie' => zalo_account.cookie, 'Origin' => 'https://chat.zalo.me' }
        )
        ws.keep_alive_interval = 15 # Giữ kết nối sống

        @lock.synchronize do
          connections[account_id] = ws
          connection_start_times[account_id] = Time.now
        end

        EM.run do
          ws.on :open do
            @logger.info "[Zalo::WebSocketService] Kết nối WebSocket mở cho tài khoản: #{account_id}"
            Thread.new { monitor_connection(account_id) }
            Thread.new { send_periodic_ping(account_id, ws) }
          end

          ws.on :message do |event|
            process_message(account_id, zalo_account.secret_key, event.data)
          end

          ws.on :close do |event|
            handle_disconnect(account_id)
            @logger.info "[Zalo::WebSocketService] Kết nối WebSocket đóng cho tài khoản: #{account_id}, mã: #{event.code}, lý do: #{event.reason}"
          end

          ws.on :error do |event|
            @logger.error "[Zalo::WebSocketService] Lỗi WebSocket cho tài khoản: #{account_id}: #{event.message}"
            handle_disconnect(account_id)
          end
        end

        "Bắt đầu lắng nghe WebSocket Zalo thành công"
      rescue => e
        @logger.error "[Zalo::WebSocketService] Lỗi khi khởi động WebSocket cho tài khoản: #{account_id}: #{e.message}"
        handle_disconnect(account_id)
        "Lỗi khi khởi động WebSocket Zalo: #{e.message}"
      end
    end

    def stop_listening(account_id)
      @lock.synchronize do
        if ws = connections.delete(account_id)
          close_web_socket(ws, account_id)
          connection_start_times.delete(account_id)
          @logger.info "[Zalo::WebSocketService] Đã dừng WebSocket cho tài khoản: #{account_id}"
          return "Đã dừng WebSocket Zalo cho tài khoản #{account_id}"
        end
        "Không tìm thấy WebSocket để dừng cho tài khoản #{account_id}"
      end
    end

    def is_web_socket_running?(account_id)
      @lock.synchronize { connections[account_id]&.open? }
    end

    private

    def process_message(account_id, secret_key, raw_message)
      @logger.info "[Zalo::WebSocketService] Nhận tin nhắn thô cho tài khoản: #{account_id}: #{raw_message}"

      begin
        key = extract_key(raw_message)
        if key.nil? || raw_message.include?('zpw_sek')
          @logger.warn "[Zalo::WebSocketService] Mất kết nối hoặc khóa không hợp lệ cho tài khoản: #{account_id}"
          handle_disconnect(account_id)
          return
        end

        decoded = decode_zalo_message(raw_message, key)
        return unless decoded

        if is_valid_message?(decoded)
          handle_message(account_id, decoded)
        elsif is_valid_typing?(decoded)
          handle_typing(account_id, decoded)
        elsif is_send_file?(decoded)
          handle_file_event(account_id, decoded)
        elsif is_valid_friend?(decoded)
          handle_friend_event(account_id, decoded)
        end
      rescue => e
        @logger.error "[Zalo::WebSocketService] Lỗi xử lý tin nhắn cho tài khoản: #{account_id}: #{e.message}"
      end
    end

    def handle_message(account_id, response)
      messages = response['data']['messages'] || response['data']['group_msgs'] || []
      messages.each do |msg|
        begin
          conversation_id = msg['uid_from'] == '0' ? msg['id_to'] : msg['uid_from']
          sender_id = msg['uid_from'] == '0' ? account_id : msg['uid_from']
          content = parse_message_content(msg)
          message_type = msg['msg_type']&.downcase || 'unknown'
          display_name = msg['display_name'] || 'Không xác định'
          msg_id = msg['cli_msg_id'] || (Time.now.to_f * 1000).to_i.to_s
          timestamp = msg['timestamp']&.to_i || (Time.now.to_f * 1000).to_i
          conversation_type = response['data']['group_msgs'] ? 'group' : 'client'
          is_seen = msg['uid_from'] == '0'

          ws_message = {
            sender_id: sender_id,
            conversation_id: conversation_id,
            sender_name: display_name,
            content: content,
            message_type: message_type,
            conversation_type: conversation_type,
            msg_id: msg_id,
            timestamp: timestamp,
            is_seen: is_seen
          }

          broadcast_message(account_id, ws_message)
        rescue => e
          @logger.error "[Zalo::WebSocketService] Lỗi xử lý tin nhắn cho tài khoản: #{account_id}: #{e.message}"
        end
      end
    end

    def handle_file_event(account_id, response)
      file_id = response['data']['controls'][0]['content']['file_id'].to_s
      @logger.info "[Zalo::WebSocketService] Sự kiện file_done cho tài khoản: #{account_id}, FileId: #{file_id}"
      ws_message = {
        type: 'FileEvent',
        file_id: file_id,
        timestamp: (Time.now.to_f * 1000).to_i
      }
      broadcast_message(account_id, ws_message)
    end

    def handle_friend_event(account_id, response)
      @logger.info "[Zalo::WebSocketService] Sự kiện kết bạn cho tài khoản: #{account_id}"
      control = response['data']['controls'][0]['content']
      act = control['act']
      action_display = { 'add' => 'Accept', 'remove' => 'Remove', 'undo_req' => 'Undo', 'req' => 'AddFr', 'req_v2' => 'AddFr' }[act] || act
      data = control['data']
      conversation_id = data['value'] || account_id
      from_uid = data['from_uid'] || ''
      to_uid = data['to_uid'] || ''
      message = data['message'] || ''

      ws_message = {
        type: 'FriendEvent',
        action: action_display,
        from_uid: from_uid,
        to_uid: to_uid,
        message: message,
        conversation_id: conversation_id,
        timestamp: (Time.now.to_f * 1000).to_i
      }

      broadcast_message(account_id, ws_message)
    end

    def handle_typing(account_id, response)
      @logger.info "[Zalo::WebSocketService] Sự kiện đang nhập cho tài khoản: #{account_id}"
      action = response['data']['actions'][0]
      gid, uid = extract_gid_and_uid(action['data'])
      uid = uid == '0' ? account_id : uid

      ws_message = {
        type: gid.empty? ? 'Typing' : 'GTyping',
        gid: gid,
        uid: uid,
        timestamp: (Time.now.to_f * 1000).to_i.to_s
      }

      broadcast_message(account_id, ws_message)
    end

    def broadcast_message(account_id, ws_message)
      conversation = Conversation.find_by(zalo_conversation_id: ws_message[:conversation_id])
      return unless conversation

      ActionCable.server.broadcast("conversation_#{conversation.id}", ws_message)
      @logger.info "[Zalo::WebSocketService] Đã phát tin nhắn cho tài khoản: #{account_id}: #{ws_message}"
    end

    def parse_message_content(msg)
      content = msg['content'].is_a?(Hash) ? msg['content'].to_json : msg['content'].to_s
      if msg['msg_type'] == 'chat.group_photo' && msg['content'].is_a?(Hash) && msg['content']['images']
        msg['content']['images'].join(',')
      else
        content
      end
    end

    def extract_key(response)
      idx = response.index('{')
      return nil if idx == -1
      obj = JSON.parse(response[idx..-1])
      obj['key']
    end

    def decode_zalo_message(message, key)
      idx = message.index('{')
      return nil if idx < 0
      decoded = Zalo::CryptoHelper.zws_decode(message[idx..-1], key)
      JSON.parse(decoded) if decoded
    rescue => e
      @logger.error "[Zalo::WebSocketService] Lỗi giải mã tin nhắn: #{e.message}"
      nil
    end

    def is_valid_message?(response)
      response && response['data'] && (
        response['data']['messages']&.any? { |m| m['msg_type'] || m['content'] } ||
          response['data']['group_msgs']&.any? { |m| m['msg_type'] || m['content'] }
      )
    end

    def is_valid_typing?(response)
      response && response['data'] && response['data']['actions']&.any?
    end

    def is_send_file?(response)
      response && response['data'] && response['data']['controls']&.any? &&
        response['data']['controls'][0]['content']['act_type'] == 'file_done'
    end

    def is_valid_friend?(response)
      response && response['data'] && (
        response['data']['controls']&.any? { |c| c['content']['act_type'] == 'fr' } ||
          response['data']['messages']&.any? { |m| m['content'].to_s.include?('msginfo.actionlist') }
      )
    end

    def extract_gid_and_uid(data_str)
      return ['', ''] if data_str.empty?

      begin
        json = data_str.start_with?('{') ? data_str : "{#{data_str}}"
        data = JSON.parse(json)
        [data['gid'] || '', data['uid'] || '']
      rescue
        gid = data_str[/\"gid\":\"([^\"]*)\"/, 1] || ''
        uid = data_str[/\"uid\":\"([^\"]*)\"/, 1] || ''
        [gid, uid]
      end
    end

    def monitor_connection(account_id)
      while connections[account_id]
        unless connections[account_id].open?
          @logger.warn "[Zalo::WebSocketService] Phát hiện kết nối đóng cho tài khoản: #{account_id}"
          handle_disconnect(account_id)
          break
        end
        sleep 2
      end
      @logger.info "[Zalo::WebSocketService] Kết thúc giám sát kết nối cho tài khoản: #{account_id}"
    end

    def send_periodic_ping(account_id, ws)
      loop do
        break unless ws.open?
        ws.send('') # Gửi ping rỗng
        @logger.info "[Zalo::WebSocketService] Đã gửi ping giữ kết nối cho tài khoản: #{account_id}"
        sleep PING_INTERVAL
      end
    end

    def handle_disconnect(account_id)
      @lock.synchronize do
        if start_time = connection_start_times.delete(account_id)
          duration = (Time.now - start_time).to_i
          @logger.info "[Zalo::WebSocketService] Kết nối WebSocket cho tài khoản: #{account_id} kéo dài #{duration} giây"
        end
        stop_listening(account_id)
      end
    end

    def close_web_socket(ws, account_id)
      begin
        if ws.open?
          ws.close(1000, 'Kết nối đóng bởi server')
          @logger.info "[Zalo::WebSocketService] Đã đóng WebSocket cho tài khoản: #{account_id}"
        else
          @logger.info "[Zalo::WebSocketService] WebSocket cho tài khoản: #{account_id} đã đóng hoặc không hợp lệ"
        end
      rescue => e
        @logger.error "[Zalo::WebSocketService] Lỗi khi đóng WebSocket cho tài khoản: #{account_id}: #{e.message}"
      end
    end
  end
end
