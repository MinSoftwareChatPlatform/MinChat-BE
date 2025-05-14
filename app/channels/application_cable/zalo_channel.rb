module ApplicationCable
  class ZaloChannel < ApplicationCable::Channel
    def subscribed
      # Xác thực người dùng
      return reject unless current_user.present?
      
      # Kiểm tra tham số channel_id
      channel_id = params[:channel_id]
      return reject unless channel_id.present?
      
      # Kiểm tra quyền truy cập vào kênh Zalo
      zalo_channel = ::Channel::Zalo.find_by(id: channel_id)
      return reject unless zalo_channel.present?
      
      # Kiểm tra người dùng có quyền với account chứa kênh Zalo
      account = Account.find_by(id: zalo_channel.account_id)
      return reject unless current_user.accounts.include?(account)
      
      # Đăng ký stream từ kênh Zalo
      stream_from "zalo_channel_#{channel_id}"
      
      # Đảm bảo Zalo WebSocket đang chạy
      ensure_zalo_websocket_running(zalo_channel)
      
      # Đăng ký client mới
      Zalo::WebsocketManagerService.instance.client_connected(current_user.id)
      
      # Gửi thông báo kết nối thành công
      transmit({ 
        event: 'connected', 
        data: { 
          channel_id: channel_id,
          zalo_id: zalo_channel.zalo_id,
          status: zalo_channel.online? ? 'online' : 'offline',
          last_activity: zalo_channel.last_activity_at
        } 
      })
    end

    def unsubscribed
      # Báo cho WebsocketManagerService biết client đã ngắt kết nối
      channel_id = params[:channel_id]
      if channel_id.present? && current_user.present?
        Zalo::WebsocketManagerService.instance.client_disconnected(current_user.id)
      end
      
      # Ngừng stream từ ActionCable
      stop_all_streams
    end
    
    # Client có thể gửi tin nhắn để gửi đến Zalo
    def send_message(data)
      # Xác thực người dùng
      return unless current_user.present?
      
      # Kiểm tra tham số channel_id
      channel_id = params[:channel_id]
      return unless channel_id.present?
      
      # Kiểm tra quyền truy cập vào kênh Zalo
      zalo_channel = ::Channel::Zalo.find_by(id: channel_id)
      return unless zalo_channel.present?
      
      # Kiểm tra người dùng có quyền với account chứa kênh Zalo
      account = Account.find_by(id: zalo_channel.account_id)
      return unless current_user.accounts.include?(account)
      
      # Kiểm tra dữ liệu tin nhắn
      recipient_id = data['recipient_id']
      message_content = data['content']
      
      return unless recipient_id.present? && message_content.present?
      
      # Gửi tin nhắn qua Zalo API
      client = Zalo::ClientService.new(zalo_channel)
      result = client.send_text_message(recipient_id, message_content)
      
      # Trả về kết quả
      transmit({ event: 'message_sent', data: result })
    end
    
    # Client có thể yêu cầu lấy tin nhắn gần đây
    def get_recent_messages(data)
      # Xác thực người dùng
      return unless current_user.present?
      
      # Kiểm tra tham số channel_id
      channel_id = params[:channel_id]
      return unless channel_id.present?
      
      # Kiểm tra quyền truy cập vào kênh Zalo
      zalo_channel = ::Channel::Zalo.find_by(id: channel_id)
      return unless zalo_channel.present?
      
      # Kiểm tra người dùng có quyền với account chứa kênh Zalo
      account = Account.find_by(id: zalo_channel.account_id)
      return unless current_user.accounts.include?(account)
      
      # Lấy tin nhắn gần đây từ buffer
      limit = data['limit'] || 50
      messages = Zalo::WebsocketManagerService.instance.get_messages_for_channel(channel_id, limit)
      
      # Trả về kết quả
      transmit({ event: 'recent_messages', data: { messages: messages } })
    end
    
    # Kiểm tra trạng thái bạn bè
    def check_friend_status(data)
      # Xác thực người dùng
      return unless current_user.present?
      
      # Kiểm tra tham số channel_id
      channel_id = params[:channel_id]
      return unless channel_id.present?
      
      # Kiểm tra quyền truy cập vào kênh Zalo
      zalo_channel = ::Channel::Zalo.find_by(id: channel_id)
      return unless zalo_channel.present?
      
      # Kiểm tra người dùng có quyền với account chứa kênh Zalo
      account = Account.find_by(id: zalo_channel.account_id)
      return unless current_user.accounts.include?(account)
      
      # Kiểm tra dữ liệu user_id
      zalo_user_id = data['user_id']
      return unless zalo_user_id.present?
      
      # Kiểm tra trạng thái bạn bè
      client = Zalo::ClientService.new(zalo_channel)
      result = client.check_friend_status(zalo_user_id)
      
      # Trả về kết quả
      transmit({ event: 'friend_status', data: result })
    end
    
    # Gửi lời mời kết bạn
    def send_friend_request(data)
      # Xác thực người dùng
      return unless current_user.present?
      
      # Kiểm tra tham số channel_id
      channel_id = params[:channel_id]
      return unless channel_id.present?
      
      # Kiểm tra quyền truy cập vào kênh Zalo
      zalo_channel = ::Channel::Zalo.find_by(id: channel_id)
      return unless zalo_channel.present?
      
      # Kiểm tra người dùng có quyền với account chứa kênh Zalo
      account = Account.find_by(id: zalo_channel.account_id)
      return unless current_user.accounts.include?(account)
      
      # Kiểm tra dữ liệu user_id
      zalo_user_id = data['user_id']
      message = data['message']
      return unless zalo_user_id.present?
      
      # Gửi lời mời kết bạn
      client = Zalo::ClientService.new(zalo_channel)
      result = client.send_friend_request(zalo_user_id, message)
      
      # Trả về kết quả
      transmit({ event: 'friend_request_sent', data: result })
    end
    
    private
    
    def ensure_zalo_websocket_running(zalo_channel)
      unless Zalo::WebsocketManagerService.instance.listener_exists?(zalo_channel.id)
        Zalo::WebsocketManagerService.instance.start_listener_for(zalo_channel)
      end
    end
  end
end
