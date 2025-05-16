class Api::V1::Accounts::Zalo::ZaloController < Api::V1::Accounts::BaseController
  def show
    render json: @zalo_channel
  end

  def generate_qr
    account = Account.find_by(id: params[:id])
    unless account
      render json: { error: 'Account not found' }, status: :not_found and return
    end

    Current.account = account

    # Initialize login service without a channel
    login_service = Zalo::LoginService.new
    qr_result = login_service.generate_qr_code

    if qr_result[:success]
      # Store temporary data in Redis using login_service's Redis instance
      temp_data = {
        account_id: account.id,
        name: params[:name] || 'Zalo',
        api_type: params[:api_type] || 30,
        api_version: params[:api_version] || 655,
        language: params[:language] || 'vi',
        qr_code_id: qr_result[:qr_code_id]
      }
      login_service.redis.setex("zalo_temp_#{qr_result[:qr_code_id]}", 300, temp_data.to_json)

      render json: {
        qr_code_id: qr_result[:qr_code_id],
        qr_image_url: qr_result[:base64_image],
        status: 'pending_qr_scan'
      }, status: :created
    else
      render json: { error: qr_result[:error] }, status: :unprocessable_entity
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    @zalo_channel.inbox.destroy!
    head :ok
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def check_qr_code
    qr_code_id = params[:qr_code_id]
    render json: { error: 'QR code ID is required' }, status: :bad_request and return unless qr_code_id.present?

    # Initialize login service to access Redis
    login_service = Zalo::LoginService.new

    # Retrieve temporary data
    temp_data_json = login_service.redis.get("zalo_temp_#{qr_code_id}")
    unless temp_data_json
      render json: { error: 'QR session not found or expired' }, status: :unprocessable_entity and return
    end
    temp_data = JSON.parse(temp_data_json)

    result = login_service.check_qr_code_scan(qr_code_id)

    if result[:success] && result[:event_type] == Zalo::LoginEventType::GOT_LOGIN_INFO
      ActiveRecord::Base.transaction do
        # Create the Zalo channel
        zalo_channel = Channel::Zalo.create!(
          account_id: temp_data['account_id'],
          imei: login_service.imei,
          zalo_id: result[:user_info][:account_id], # Assuming account_id is included
          display_name: result[:user_info][:name],
          phone: result[:user_info][:phone],
          avatar_url: result[:user_info][:avatar],
          cookie_data: login_service.cookie,
          secret_key: result[:user_info][:secret_key], # Assuming secret_key is included
          status: :enabled,
          api_type: temp_data['api_type'],
          api_version: temp_data['api_version'],
          language: temp_data['language'],
          last_activity_at: Time.current
        )

        # Create the inbox
        inbox = Current.account.inboxes.create!(
          name: temp_data['name'],
          channel_type: 'Channel::Zalo',
          channel: zalo_channel
        )

        # Start WebSocket listener
        Zalo::WebSocketService.start(zalo_channel)

        # Clean up temporary data
        login_service.redis.del("zalo_temp_#{qr_code_id}")

        render json: {
          success: true,
          id: zalo_channel.id,
          inbox_id: inbox.id,
          user_info: result[:user_info],
          status: zalo_channel.status
        }
      end
    else
      render json: result, status: :unprocessable_entity
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def send_message
    # Kiểm tra tham số đầu vào
    channel_id = params[:channel_id]
    recipient_id = params[:recipient_id]
    content = params[:content]

    render json: { error: 'Missing required parameters' }, status: :bad_request and return unless channel_id.present? && recipient_id.present? && content.present?

    # Tìm kênh Zalo
    zalo_channel = Channel::Zalo.find_by(id: channel_id)
    render json: { error: 'Channel not found' }, status: :not_found and return unless zalo_channel.present?
    render json: { error: 'You are not authorized to perform this action' }, status: :forbidden and return unless Current.account.id == zalo_channel.account_id

    # Chuẩn bị dữ liệu yêu cầu cho ClientService
    request = {
      conversation_id: recipient_id,
      content: content,
      is_group: false # Giả định mặc định là tin nhắn cá nhân, có thể thêm params[:is_group] nếu cần
    }

    # Gửi tin nhắn qua ClientService
    client_service = Zalo::ClientService.new
    result = client_service.send_message(zalo_channel, request)

    if result[:success]
      # Tìm hoặc tạo conversation
      conversation = find_or_create_conversation(zalo_channel, recipient_id)

      # Lưu tin nhắn
      message = conversation.messages.create!(
        account_id: Current.account.id,
        message_type: :outgoing,
        content: content,
        sender: Current.user,
        source_id: result[:platform_message_id] # Giả định ClientService trả về platform_message_id
      )

      render json: {
        success: true,
        message_id: message.id,
        platform_message_id: result[:platform_message_id] || SecureRandom.uuid # Nếu không có, tạo ID tạm
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  rescue StandardError => e
    render json: { error: "Error sending message: #{e.message}" }, status: :internal_server_error
  end

  def upload_attachment
    # Kiểm tra tham số đầu vào
    channel_id = params[:channel_id]
    recipient_id = params[:recipient_id]
    file = params[:file]
    content = params[:content] # Nội dung tin nhắn đi kèm file (nếu có)

    render json: { error: 'Missing required parameters' }, status: :bad_request and return unless channel_id.present? && recipient_id.present? && file.present?

    # Tìm kênh Zalo
    zalo_channel = Channel::Zalo.find_by(id: channel_id)
    render json: { error: 'Channel not found' }, status: :not_found and return unless zalo_channel.present?
    render json: { error: 'You are not authorized to perform this action' }, status: :forbidden and return unless Current.account.id == zalo_channel.account_id

    # Chuẩn bị dữ liệu yêu cầu cho ClientService
    request = {
      conversation_id: recipient_id,
      content: content || '', # Nếu không có content, gửi chuỗi rỗng
      files: [file], # Gửi một mảng chứa file
      is_group: false # Giả định mặc định là tin nhắn cá nhân
    }

    # Gửi tin nhắn với file qua ClientService
    client_service = Zalo::ClientService.new
    result = client_service.send_message(zalo_channel, request)

    if result[:success]
      # Tìm hoặc tạo conversation
      conversation = find_or_create_conversation(zalo_channel, recipient_id)

      # Xác định nội dung tin nhắn dựa trên file đính kèm
      message_content = content.present? ? content : "Attachment sent"

      # Lưu tin nhắn
      message = conversation.messages.create!(
        account_id: Current.account.id,
        message_type: :outgoing,
        content: message_content,
        sender: Current.user,
        source_id: result[:platform_message_id] # Giả định ClientService trả về platform_message_id
      )

      render json: {
        success: true,
        message_id: message.id,
        platform_message_id: result[:platform_message_id] || SecureRandom.uuid,
        attachment_url: result[:attachment_url] # Giả định ClientService trả về URL nếu có
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  rescue StandardError => e
    render json: { error: "Error uploading attachment: #{e.message}" }, status: :internal_server_error
  end

  def websocket_status
    channel_id = params[:channel_id]
    render json: { error: 'Channel ID is required' }, status: :bad_request and return unless channel_id.present?

    zalo_channel = Channel::Zalo.find_by(id: channel_id)
    render json: { error: 'Channel not found' }, status: :not_found and return unless zalo_channel.present?
    render json: { error: 'You are not authorized to perform this action' }, status: :forbidden and return unless Current.account.id == zalo_channel.account_id

    active = Zalo::WebsocketManagerService.instance.listener_exists?(channel_id)

    render json: {
      active: active,
      channel_id: channel_id,
      last_activity_at: zalo_channel.last_activity_at
    }
  end

  private

  def fetch_channel
    @zalo_channel = Current.account.zalo.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Zalo channel not found' }, status: :not_found
  end

  def zalo_channel_params
    params.permit(Channel::Zalo::EDITABLE_ATTRS)
  end

  def find_or_create_conversation(zalo_channel, recipient_id)
    inbox = zalo_channel.inbox

    # Tìm hoặc tạo contact
    contact = Current.account.contacts.find_or_initialize_by(identifier: recipient_id)
    if contact.new_record?
      contact.name = "Zalo User #{recipient_id}"
      contact.save!
      ContactInbox.find_or_create_by!(
        contact_id: contact.id,
        inbox_id: inbox.id,
        source_id: recipient_id
      )
    end

    # Tìm hoặc tạo conversation
    conversation = Conversation.find_or_initialize_by(
      account_id: Current.account.id,
      inbox_id: inbox.id,
      contact_id: contact.id
    )
    if conversation.new_record?
      conversation.status = :open
      conversation.save!
    end

    conversation
  end
end
