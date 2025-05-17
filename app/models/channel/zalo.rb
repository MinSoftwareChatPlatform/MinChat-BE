# == Schema Information
#
# Table name: channel_zalo
#
#  id                 :bigint           not null, primary key
#  api_type           :integer          default(30)
#  api_version        :integer          default(655)
#  avatar_url         :string
#  cookie_data        :text
#  display_name       :string
#  imei               :string
#  language           :string           default("vi")
#  meta               :jsonb
#  phone              :string
#  secret_key         :string
#  status             :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :integer          not null
#  zalo_id            :string
#
# Indexes
#
#  index_channel_zalo_on_account_id  (account_id)
#  index_channel_zalo_on_zalo_id     (zalo_id) UNIQUE
#
class Channel::Zalo < ApplicationRecord
  include Channelable
  # include Reauthorizable # Uncomment if needed for token refreshing

  self.table_name = 'channel_zalo'
  EDITABLE_ATTRS = [:zalo_id, :phone, :display_name, { meta: {} }].freeze

  # Định nghĩa các trạng thái cho kênh Zalo
  enum status: { pending_qr_scan: 0, enabled: 1, authorization_error: 2, disabled: 3 }

  validates :account_id, presence: true
  validates :zalo_id, uniqueness: true, presence: true, if: :enabled?

  # Thiết lập mối quan hệ với Account
  belongs_to :account

  # Thiết lập thời gian hết hạn cho QR Code
  QR_CODE_EXPIRY = 60.seconds

  # Khởi tạo WebSocket nếu cần
  def ensure_websocket_connected
    return if disabled?

    # Khởi tạo WebSocket connection nếu chưa tồn tại
    Zalo::WebsocketManagerService.instance.start_listener_for(self)
  end

  # Gửi tin nhắn văn bản
  def send_text_message(recipient_id, message_content)
    client_service = Zalo::ClientService.new(self)
    client_service.send_text_message(recipient_id, message_content)
  end

  # Lấy secret key được giải mã
  def decoded_secret_key
    return nil if secret_key.blank?

    # Trong trường hợp thực tế, bạn có thể cần mã hóa/giải mã secret key
    secret_key
  end

  # Callback sau khi tạo kênh
  after_create :setup_webhook
  after_update :setup_webhook, if: :saved_change_to_status?

  # Callback để bắt đầu/dừng listener WebSocket khi kênh được kích hoạt/vô hiệu hóa hoặc xóa
  after_commit :start_realtime_listener, on: [:create, :update],
               if: -> { saved_change_to_status? && enabled? }

  after_commit :stop_realtime_listener, on: [:update],
               if: -> { saved_change_to_status? && (disabled? || authorization_error?) }

  before_destroy :stop_realtime_listener

  def name
    display_name.presence || 'Zalo'
  end

  # Phương thức này sẽ được gọi bởi Chatwoot để tạo ContactInbox
  # khi có tin nhắn đầu tiên từ một người dùng Zalo mới.
  def create_contact_inbox(identifier, profile_info = {})
    ::ContactInboxWithContactBuilder.new(
      source_id: identifier,
      inbox: inbox,
      contact_attributes: {
        name: profile_info[:name] || "Zalo User #{identifier.last(6)}",
        avatar_url: profile_info[:avatar_url],
        additional_attributes: {
          'zalo_id': identifier
        }
      }
    ).perform
  end
  # Phương thức để bắt đầu quá trình đăng nhập QR
  def initiate_qr_login
    service = Zalo::LoginService.new(self)
    result = service.generate_qr_code

    if result[:success]
      update(meta: meta.merge(qr_code_id: result[:qr_code_id], qr_status: 'pending_scan'))
      { success: true, qr_code_id: result[:qr_code_id], qr_image_url: result[:qr_image_url] }
    else
      { success: false, error: result[:error] }
    end
  end

  # Phương thức kiểm tra trạng thái đăng nhập QR
  def check_qr_login_status(qr_code_id)
    service = Zalo::LoginService.new(self)
    result = service.poll_qr_status(qr_code_id)

    if result[:status] == :success
      # Thông tin xác thực đã được service cung cấp, cần cập nhật model
      # Nhưng không lưu ở đây, controller sẽ làm việc đó
      self.assign_attributes(
        zalo_id: result.dig(:user_info, :zalo_id),
        phone: result.dig(:user_info, :phone),
        display_name: result.dig(:user_info, :display_name),
        avatar_url: result.dig(:user_info, :avatar_url),
        cookie_data: result.dig(:user_info, :cookie_data),
        secret_key: result.dig(:user_info, :secret_key),
        imei: result.dig(:user_info, :imei),
        language: result.dig(:user_info, :language) || language,
        api_type: result.dig(:user_info, :api_type) || api_type,
        api_version: result.dig(:user_info, :api_version) || api_version,
        meta: meta.except('qr_code_id', 'qr_status', 'error_message')
      )
    end

    result
  end

  # Phương thức gửi tin nhắn
  def send_platform_message(message_content, recipient_platform_id)
    client_service.send_text_message(recipient_platform_id, message_content)
  end

  # Callback từ WebsocketManagerService khi có tin nhắn mới
  def process_incoming_message(zalo_message_payload)
    update_column(:last_activity_at, Time.current)

    # 1. Parse payload, tìm hoặc tạo conversation, lưu message vào DB
    sender_id = zalo_message_payload['sender_id'] || zalo_message_payload['from']
    content = zalo_message_payload['content'] || zalo_message_payload['message']
    timestamp = zalo_message_payload['timestamp'] || zalo_message_payload['created_at'] || Time.current.to_i * 1000
    conversation = find_or_create_conversation(sender_id)
    message = conversation.messages.create!(
      content: content,
      sender_id: sender_id,
      sent_at: Time.at(timestamp.to_i / 1000)
    )

    # 2. Broadcast message đã lưu/chuẩn hóa qua ActionCable
    ActionCable.server.broadcast("zalo_channel_#{id}", {
      id: message.id,
      conversation_id: conversation.id,
      content: message.content,
      sender_id: message.sender_id,
      sent_at: message.sent_at,
      raw: zalo_message_payload
    })

    # 3. Gọi job phụ trợ nếu cần
    Zalo::IncomingMessageProcessingJob.perform_later(account_id, inbox.id, zalo_message_payload)
  end

  def find_or_create_conversation(sender_id)
    # Tìm hoặc tạo conversation theo sender_id (user/group)
    # Tuỳ vào schema, bạn có thể mở rộng logic này
    inbox.conversations.find_or_create_by!(source_id: sender_id)
  end

  # For ActiveJob serialization
  def client_service
    @client_service ||= Zalo::ClientService.new(self)
  end

  def setup_webhook
    return unless enabled?

    # Đảm bảo webhook và websocket được thiết lập
    ensure_websocket_connected
  end

  private

  def start_realtime_listener
    return unless enabled? && zalo_id.present? && cookie_data.present?
    Rails.logger.info "[Channel::Zalo ID: #{id}] Starting WebSocket listener"
    Zalo::WebsocketManagerService.instance.start_listener_for(self)
  end

  def stop_realtime_listener
    Rails.logger.info "[Channel::Zalo ID: #{id}] Stopping WebSocket listener"
    Zalo::WebsocketManagerService.instance.stop_listener_for(id)
  end

  # Tạo IMEI nếu chưa có
  def ensure_imei
    self.imei ||= "chatwoot_#{SecureRandom.uuid}"
  end
  end
