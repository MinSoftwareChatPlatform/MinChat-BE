class Api::V1::Accounts::ZaloWebhooksController < Api::V1::Accounts::BaseController
  skip_before_action :authenticate_user_from_token!, only: [:create]
  skip_before_action :check_authorization, only: [:create]
  before_action :validate_zalo_webhook_signature, only: [:create]
  before_action :find_zalo_channel, only: [:create]

  def create
    # Handle the Zalo webhook callback
    if @zalo_channel
      process_webhook_data
      head :ok
    else
      Rails.logger.error "Zalo webhook: Couldn't find Zalo channel with id: #{params[:channel_id]}"
      head :not_found
    end
  rescue StandardError => e
    Rails.logger.error "Zalo webhook processing error: #{e.message}\n#{e.backtrace.join("\n")}"
    head :unprocessable_entity
  end

  private

  def validate_zalo_webhook_signature
    # Zalo webhook signature validation (if applicable)
    # This depends on how Zalo implements webhook security
    # For now, we'll leave this as a placeholder
    true
  end

  def find_zalo_channel
    @zalo_channel = Channel::Zalo.find_by(zalo_id: params[:app_id])
  end

  def process_webhook_data
    case params[:event_name]
    when 'message'
      process_message_event
    when 'follow'
      process_follow_event
    when 'unfollow'
      process_unfollow_event
    else
      Rails.logger.info "Unhandled Zalo webhook event: #{params[:event_name]}"
    end
  end

  def process_message_event
    # Process incoming message
    message_data = params[:message] || {}
    sender_id = message_data[:sender_id] || params[:sender_id]
    
    return if sender_id.blank?

    # Find or create contact
    sender_profile = {
      name: message_data[:sender_name] || params[:sender_name],
      avatar_url: message_data[:sender_avatar] || params[:sender_avatar]
    }
    
    contact_inbox = @zalo_channel.create_contact_inbox(sender_id, sender_profile)
    conversation = contact_inbox.find_or_create_conversation

    # Create message
    if message_data[:text].present?
      conversation.messages.create!(
        content: message_data[:text],
        account_id: @zalo_channel.account_id,
        inbox_id: @zalo_channel.inbox.id,
        message_type: :incoming,
        sender: contact_inbox.contact
      )
    end

    # Handle attachments
    if message_data[:attachments].present?
      process_attachments(conversation, contact_inbox.contact, message_data[:attachments])
    end
  end

  def process_follow_event
    sender_id = params[:follower][:id]
    return if sender_id.blank?

    # Find or create contact
    sender_profile = {
      name: params[:follower][:display_name],
      avatar_url: params[:follower][:avatar]
    }
    
    contact_inbox = @zalo_channel.create_contact_inbox(sender_id, sender_profile)
    conversation = contact_inbox.find_or_create_conversation

    # Create a system message for follow event
    conversation.messages.create!(
      content: I18n.t('zalo.notifications.followed'),
      account_id: @zalo_channel.account_id,
      inbox_id: @zalo_channel.inbox.id,
      message_type: :activity,
      sender: nil
    )
  end

  def process_unfollow_event
    sender_id = params[:follower][:id]
    return if sender_id.blank?

    contact_inbox = @zalo_channel.contact_inboxes.find_by(source_id: sender_id)
    return unless contact_inbox

    conversation = contact_inbox.conversations.last
    return unless conversation

    # Create a system message for unfollow event
    conversation.messages.create!(
      content: I18n.t('zalo.notifications.unfollowed'),
      account_id: @zalo_channel.account_id,
      inbox_id: @zalo_channel.inbox.id,
      message_type: :activity,
      sender: nil
    )
  end

  def process_attachments(conversation, contact, attachments)
    attachments.each do |attachment|
      case attachment[:type]
      when 'image'
        attachment_url = attachment[:payload][:url]
        attachment_file = Down.download(attachment_url)
        
        conversation.messages.create!(
          content: attachment[:payload][:caption],
          account_id: @zalo_channel.account_id,
          inbox_id: @zalo_channel.inbox.id,
          message_type: :incoming,
          sender: contact,
          attachments: [
            {
              file: attachment_file,
              file_type: 'image'
            }
          ]
        )
      when 'file'
        attachment_url = attachment[:payload][:url]
        attachment_file = Down.download(attachment_url)
        
        conversation.messages.create!(
          content: attachment[:payload][:caption] || attachment[:payload][:name],
          account_id: @zalo_channel.account_id,
          inbox_id: @zalo_channel.inbox.id,
          message_type: :incoming,
          sender: contact,
          attachments: [
            {
              file: attachment_file,
              file_type: 'file'
            }
          ]
        )
      end
    end
  end
end