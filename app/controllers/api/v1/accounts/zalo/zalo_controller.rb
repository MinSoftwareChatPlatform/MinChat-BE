class Api::V1::Accounts::ZaloController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_channel, only: [:show, :update, :destroy]

  def index
    @zalo_channels = Current.account.zalo
    render json: @zalo_channels
  end

  def show
    render json: @zalo_channel
  end

  def create
    ActiveRecord::Base.transaction do
      # Tạo Inbox cho Zalo
      @inbox = Current.account.inboxes.build(
        name: params[:name] || 'Zalo',
        channel_type: 'Channel::Zalo'
      )

      # Lưu Inbox
      @inbox.save!

      # Tạo Channel::Zalo
      @zalo_channel = Channel::Zalo.new(
        account_id: Current.account.id,
        imei: "chatwoot_#{SecureRandom.uuid}",
        status: :pending_qr_scan,
        api_type: params[:api_type] || 30,
        api_version: params[:api_version] || 655,
        language: params[:language] || 'vi'
      )

      # Liên kết Inbox với Channel
      @inbox.channel = @zalo_channel
      @zalo_channel.save!

      # Khởi tạo QR code
      login_service = Zalo::LoginService.new(@zalo_channel)
      qr_result = login_service.generate_qr_code

      if qr_result[:success]
        render json: {
          id: @zalo_channel.id,
          inbox_id: @inbox.id,
          qr_code_id: qr_result[:qr_code_id],
          qr_image_url: qr_result[:qr_image_url],
          status: @zalo_channel.status
        }, status: :created
      else
        raise ActiveRecord::Rollback
        render json: { error: qr_result[:error] }, status: :unprocessable_entity
      end
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    if @zalo_channel.update(zalo_channel_params)
      render json: @zalo_channel
    else
      render json: { error: @zalo_channel.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
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

    login_service = Zalo::LoginService.new
    result = login_service.check_qr_code_scan(qr_code_id, Current.user.id)

    if result[:success]
      # Nếu đăng nhập thành công, cập nhật channel
      if result[:account_data].present?
        zalo_channel = Channel::Zalo.find_by(id: params[:channel_id])

        if zalo_channel
          zalo_channel.update(
            zalo_id: result[:account_data][:uid],
            display_name: result[:account_data][:display_name],
            phone: result[:account_data][:phone],
            avatar_url: result[:account_data][:avatar_url],
            cookie_data: result[:account_data][:cookie],
            secret_key: result[:account_data][:secret_key],
            status: :enabled,
            last_activity_at: Time.current
          )

          # Khởi tạo WebSocket
          Zalo::WebsocketManagerService.instance.start_listener_for(zalo_channel)
        end
      end

      render json: result
    else
      render json: result, status: :unprocessable_entity
    end
  end

  def send_message
    recipient_id = params[:recipient_id]
    content = params[:content]
    channel_id = params[:channel_id]

    render json: { error: 'Missing required parameters' }, status: :bad_request and return unless recipient_id.present? && content.present? && channel_id.present?

    zalo_channel = Channel::Zalo.find_by(id: channel_id)
    render json: { error: 'Channel not found' }, status: :not_found and return unless zalo_channel.present?
    render json: { error: 'You are not authorized to perform this action' }, status: :forbidden and return unless Current.account.id == zalo_channel.account_id

    client_service = Zalo::ClientService.new(zalo_channel)
    result = client_service.send_text_message(recipient_id, content)

    if result[:success]
      # Tạo tin nhắn trong Chatwoot
      conversation = find_or_create_conversation(zalo_channel, recipient_id)

      message = conversation.messages.create!(
        account_id: Current.account.id,
        message_type: :outgoing,
        content: content,
        sender: Current.user,
        source_id: result[:platform_message_id]
      )

      render json: {
        success: true,
        message_id: message.id,
        platform_message_id: result[:platform_message_id]
      }
    else
      render json: result, status: :unprocessable_entity
    end
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

  # File attachment upload endpoint
  def upload_attachment
    begin
      # Validate parameters
      render json: { success: false, message: 'Missing recipient_id parameter' }, status: :bad_request and return unless params[:recipient_id].present?
      render json: { success: false, message: 'Missing file attachment' }, status: :bad_request and return unless params[:file].present?

      # Fetch the Zalo channel
      @zalo_channel = ::Channel::Zalo.find(params[:id])

      # Create a temporary file from the uploaded file
      temp_file = params[:file].tempfile.path

      # Upload the file
      client_service = Zalo::ClientService.new(@zalo_channel)

      # Determine file type and use appropriate method
      mime_type = params[:file].content_type

      if mime_type.start_with?('image/')
        result = client_service.send_image_message(params[:recipient_id], temp_file)
      else
        result = client_service.send_file_message(params[:recipient_id], temp_file)
      end

      if result[:success]
        render json: {
          success: true,
          attachment_id: result[:platform_message_id],
          file_type: mime_type.start_with?('image/') ? 'image' : 'file'
        }
      else
        render json: { success: false, message: result[:error] }, status: :unprocessable_entity
      end
    rescue StandardError => e
      Rails.logger.error "Error uploading attachment: #{e.message}\n#{e.backtrace.join("\n")}"
      render json: { success: false, message: "Error: #{e.message}" }, status: :internal_server_error
    end
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
    contact = Current.account.contacts.find_or_initialize_by(
      identifier: recipient_id
    )

    if contact.new_record?
      contact.name = "Zalo User #{recipient_id}"
      contact.save!

      # Liên kết contact với inbox
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
      conversation.status = Conversation.statuses[:open]
      conversation.save!
    end

    conversation
  end
end
