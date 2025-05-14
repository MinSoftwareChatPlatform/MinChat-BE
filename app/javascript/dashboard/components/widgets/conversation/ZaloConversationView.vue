<template>
  <div class="zalo-chat-view">
    <div 
      v-if="isConnecting || !isConnected" 
      class="zalo-connection-status"
    >
      <spinner message="Đang kết nối đến Zalo..." />
    </div>
    
    <div v-else class="zalo-chat-container">
      <!-- Header -->
      <div class="zalo-chat-header">
        <div class="zalo-recipient-info">
          <woot-avatar
            v-if="recipientInfo.avatar_url"
            :src="recipientInfo.avatar_url"
            :username="recipientInfo.name || recipientInfo.phone || recipientInfo.id"
            size="32px"
          />
          <div class="recipient-details">
            <h3 class="recipient-name">
              {{ recipientInfo.name || recipientInfo.phone || recipientInfo.id }}
            </h3>
            <span v-if="recipientInfo.status" class="recipient-status">
              {{ recipientInfo.status }}
            </span>
          </div>
        </div>
        
        <div class="zalo-header-actions">
          <woot-button
            variant="clear"
            color-scheme="secondary"
            icon="refresh"
            size="small"
            @click="refreshMessages"
          />
        </div>
      </div>
      
      <!-- Messages -->
      <div 
        class="zalo-chat-messages" 
        ref="messagesContainer"
        @scroll="handleScroll"
      >
        <div v-if="isLoadingMessages" class="zalo-loading-messages">
          <spinner message="Đang tải tin nhắn..." />
        </div>
        
        <div v-else-if="messages.length === 0" class="zalo-empty-messages">
          <div class="empty-state-message">
            <i class="icon-message"></i>
            <p>{{ $t('ZALO.CHAT.NO_MESSAGES') }}</p>
          </div>
        </div>
        
        <template v-else>
          <div 
            v-for="(message, index) in messages" 
            :key="message.id || index"
            class="zalo-message-wrapper"
            :class="{
              'zalo-message-outgoing': message.sender_id === currentUserId,
              'zalo-message-incoming': message.sender_id !== currentUserId
            }"
          >
            <div class="zalo-message">
              <div class="zalo-message-content">
                <!-- Nội dung tin nhắn -->
                <div v-if="message.content" v-html="formatMessageContent(message.content)"></div>
                
                <!-- Đính kèm hình ảnh -->
                <div v-if="message.attachments && message.attachments.length" class="zalo-message-attachments">
                  <div 
                    v-for="attachment in message.attachments" 
                    :key="attachment.id"
                    class="zalo-attachment"
                  >
                    <img 
                      v-if="isImageAttachment(attachment)" 
                      :src="attachment.data_url"
                      :alt="attachment.name || 'Image'"
                      class="zalo-image-attachment"
                      @click="openImagePreview(attachment)"
                    />
                    
                    <div v-else class="zalo-file-attachment">
                      <i class="icon-file"></i>
                      <span class="file-name">{{ attachment.name }}</span>
                      <span class="file-size">{{ formatFileSize(attachment.size) }}</span>
                      <a 
                        :href="attachment.data_url" 
                        target="_blank" 
                        class="download-button"
                      >
                        <i class="icon-download"></i>
                      </a>
                    </div>
                  </div>
                </div>
              </div>
              
              <div class="zalo-message-meta">
                <span class="zalo-message-time">
                  {{ formatTime(message.timestamp || message.created_at) }}
                </span>
                
                <span 
                  v-if="message.sender_id === currentUserId" 
                  class="zalo-message-status"
                >
                  <i 
                    :class="{
                      'icon-check': message.status === 'sent',
                      'icon-check-all': message.status === 'delivered',
                      'icon-check-all delivered': message.status === 'read'
                    }"
                  ></i>
                </span>
              </div>
            </div>
          </div>
        </template>
      </div>
      
      <!-- Input -->
      <div class="zalo-chat-input">
        <div class="zalo-input-attachments">
          <woot-button
            variant="clear"
            color-scheme="secondary"
            icon="attachment"
            size="small"
            @click="triggerFileInput"
          />
          <input 
            type="file" 
            ref="fileInput"
            style="display: none"
            @change="handleFileSelection"
          />
        </div>
        
        <textarea
          ref="messageInput"
          v-model="newMessage"
          class="zalo-message-input"
          :placeholder="$t('ZALO.CHAT.TYPE_MESSAGE')"
          @keydown.enter.prevent="sendMessage"
        ></textarea>
        
        <woot-button
          :disabled="!newMessage.trim() && !selectedFile"
          variant="clear"
          color-scheme="primary"
          icon="paper-plane"
          size="small"
          @click="sendMessage"
        />
      </div>
    </div>
    
    <!-- Image Preview Modal -->
    <woot-modal v-model:show="showImagePreview" :on-close="closeImagePreview">
      <div class="image-preview-container">
        <img :src="previewImageUrl" alt="Preview" class="preview-image" />
      </div>
    </woot-modal>
  </div>
</template>

<script>
import { mapGetters } from 'vuex';
import ZaloWebSocketClient from 'sdk/zaloWebsocketClient';

export default {
  name: 'ZaloConversationView',
  
  props: {
    conversation: {
      type: Object,
      required: true,
    },
    inboxId: {
      type: [Number, String],
      required: true,
    },
  },
  
  data() {
    return {
      messages: [],
      newMessage: '',
      isConnecting: true,
      isConnected: false,
      isLoadingMessages: false,
      client: null,
      recipientInfo: {
        id: '',
        name: '',
        phone: '',
        avatar_url: '',
        status: '',
      },
      wsClient: null,
      selectedFile: null,
      showImagePreview: false,
      previewImageUrl: '',
      hasMoreMessages: true,
      isLoadingMoreMessages: false,
    };
  },
  
  computed: {
    ...mapGetters({
      currentUser: 'getCurrentUser',
      globalConfig: 'globalConfig/get',
    }),
    
    currentUserId() {
      return this.currentUser?.id;
    },
    
    zaloChannel() {
      return this.conversation?.meta?.zalo || {};
    },
    
    recipientId() {
      return this.conversation?.meta?.recipient_id || '';
    },
    
    zaloChannelId() {
      return this.zaloChannel?.id;
    },
    
    authToken() {
      return this.globalConfig?.token;
    },
  },
  
  watch: {
    conversation: {
      immediate: true,
      handler(newVal) {
        if (newVal?.id) {
          this.loadConversationDetails();
        }
      },
    },
  },
  
  async mounted() {
    await this.initZaloWebSocket();
  },
  
  beforeDestroy() {
    this.disconnectWebSocket();
  },
  
  methods: {
    // Kết nối WebSocket
    async initZaloWebSocket() {
      if (!this.zaloChannelId || !this.authToken) {
        this.isConnecting = false;
        return;
      }
      
      this.isConnecting = true;
      
      try {
        this.wsClient = new ZaloWebSocketClient({
          channelId: this.zaloChannelId,
          authToken: this.authToken,
          debug: true,
          onMessage: this.handleWebSocketMessage,
          onStatusChange: this.handleStatusChange,
          onError: this.handleWebSocketError,
        });
        
        await this.wsClient.connect();
        
        // Lấy tin nhắn gần đây
        this.loadMessages();
        
      } catch (error) {
        this.$store.dispatch('notifications/create', {
          type: 'error',
          message: this.$t('ZALO.ERRORS.SOCKET_CONNECTION', { error: error.message }),
        });
        this.isConnecting = false;
      }
    },
    
    // Ngắt kết nối WebSocket
    disconnectWebSocket() {
      if (this.wsClient) {
        this.wsClient.disconnect();
        this.wsClient = null;
      }
    },
    
    // Xử lý tin nhắn từ WebSocket
    handleWebSocketMessage(event) {
      console.log('Nhận được tin nhắn từ WebSocket:', event);
      
      if (event.type === 'incoming') {
        // Thêm tin nhắn mới từ Zalo
        const message = event.data;
        
        if (this.isFromCurrentConversation(message)) {
          this.addMessage(message);
          this.scrollToBottom();
        }
      } else if (event.type === 'recent_messages') {
        // Cập nhật danh sách tin nhắn
        this.isLoadingMessages = false;
        
        if (event.data && event.data.messages) {
          this.processReceivedMessages(event.data.messages);
        }
      } else if (event.type === 'send_result') {
        // Kết quả gửi tin nhắn
        const result = event.data;
        
        if (result.success) {
          // Nếu gửi thành công, cập nhật trạng thái tin nhắn đã gửi
          this.updateMessageStatus(result.message_id, 'sent');
        } else {
          // Nếu gửi thất bại, hiển thị thông báo lỗi
          this.$store.dispatch('notifications/create', {
            type: 'error',
            message: this.$t('ZALO.ERRORS.MESSAGE_SEND_FAILED', { error: result.error }),
          });
        }
      }
    },
    
    // Xử lý thay đổi trạng thái WebSocket
    handleStatusChange(status) {
      console.log('Trạng thái WebSocket thay đổi:', status);
      
      if (status.type === 'connection') {
        this.isConnecting = status.status !== 'connected';
        this.isConnected = status.status === 'connected';
      } else if (status.type === 'zalo_connected') {
        // Đã kết nối đến Zalo WebSocket
        if (status.zalo_id) {
          // Cập nhật thông tin channel
          this.loadZaloChannelInfo();
        }
      } else if (status.type === 'zalo_status' && status.status === 'presence_update') {
        // Cập nhật trạng thái người dùng Zalo
        if (status.user_id === this.recipientId) {
          this.recipientInfo.status = status.presence;
        }
      }
    },
    
    // Xử lý lỗi WebSocket
    handleWebSocketError(error) {
      console.error('Lỗi WebSocket:', error);
      
      this.$store.dispatch('notifications/create', {
        type: 'error',
        message: this.$t('ZALO.ERRORS.SOCKET_ERROR', { error: error.message }),
      });
    },
    
    // Tải chi tiết cuộc hội thoại
    async loadConversationDetails() {
      try {
        // Lấy thông tin người nhận từ API nếu chưa có
        if (!this.recipientInfo.id && this.recipientId) {
          await this.loadRecipientInfo();
        }
      } catch (error) {
        console.error('Lỗi khi tải thông tin cuộc hội thoại:', error);
      }
    },
    
    // Tải thông tin người nhận
    async loadRecipientInfo() {
      try {
        // Gọi API để lấy thông tin người nhận
        const url = `/api/v1/accounts/${this.$store.getters.getCurrentAccountId}/zalo/recipient_info`;
        const { data } = await this.$axios.get(url, {
          params: {
            recipient_id: this.recipientId,
            channel_id: this.zaloChannelId,
          },
        });
        
        if (data && data.recipient) {
          this.recipientInfo = {
            id: data.recipient.id || this.recipientId,
            name: data.recipient.name,
            phone: data.recipient.phone,
            avatar_url: data.recipient.avatar_url,
            status: data.recipient.status || 'offline',
          };
        }
      } catch (error) {
        console.error('Lỗi khi tải thông tin người nhận:', error);
      }
    },
    
    // Tải thông tin kênh Zalo
    async loadZaloChannelInfo() {
      try {
        // Gọi API để lấy thông tin kênh Zalo
        const url = `/api/v1/accounts/${this.$store.getters.getCurrentAccountId}/zalo/${this.zaloChannelId}`;
        const { data } = await this.$axios.get(url);
        
        if (data) {
          // Cập nhật thông tin kênh
          this.$store.dispatch('conversations/updateConversation', {
            id: this.conversation.id,
            data: {
              meta: {
                ...this.conversation.meta,
                zalo: data,
              },
            },
          });
        }
      } catch (error) {
        console.error('Lỗi khi tải thông tin kênh Zalo:', error);
      }
    },
    
    // Tải tin nhắn
    async loadMessages() {
      if (!this.wsClient || !this.wsClient.isConnected()) {
        return;
      }
      
      this.isLoadingMessages = true;
      
      try {
        // Lấy tin nhắn gần đây thông qua WebSocket
        await this.wsClient.getRecentMessages(50);
      } catch (error) {
        console.error('Lỗi khi tải tin nhắn:', error);
        this.isLoadingMessages = false;
        
        this.$store.dispatch('notifications/create', {
          type: 'error',
          message: this.$t('ZALO.ERRORS.LOAD_MESSAGES_FAILED', { error: error.message }),
        });
      }
    },
    
    // Refresh tin nhắn
    refreshMessages() {
      this.messages = [];
      this.loadMessages();
    },
    
    // Xử lý tin nhắn nhận được
    processReceivedMessages(messages) {
      if (!Array.isArray(messages) || messages.length === 0) {
        this.hasMoreMessages = false;
        return;
      }
      
      // Lọc các tin nhắn của cuộc hội thoại hiện tại
      const filteredMessages = messages
        .filter(msg => this.isFromCurrentConversation(msg))
        .map(msg => this.normalizeMessage(msg));
      
      // Sắp xếp tin nhắn theo thời gian
      const sortedMessages = filteredMessages.sort((a, b) => {
        const timeA = a.timestamp || a.created_at || 0;
        const timeB = b.timestamp || b.created_at || 0;
        return timeA - timeB;
      });
      
      // Cập nhật danh sách tin nhắn
      this.messages = sortedMessages;
      
      // Cuộn xuống dưới cùng
      this.$nextTick(() => {
        this.scrollToBottom();
      });
    },
    
    // Thêm tin nhắn mới
    addMessage(message) {
      if (!message || !this.isFromCurrentConversation(message)) {
        return;
      }
      
      const normalizedMessage = this.normalizeMessage(message);
      
      // Kiểm tra xem tin nhắn đã tồn tại chưa
      const exists = this.messages.some(msg => msg.id === normalizedMessage.id);
      
      if (!exists) {
        this.messages.push(normalizedMessage);
        
        // Cập nhật thời gian hoạt động cuối cùng của cuộc hội thoại
        this.$store.dispatch('conversations/updateConversation', {
          id: this.conversation.id,
          data: {
            last_activity_at: new Date().toISOString(),
          },
        });
      }
    },
    
    // Chuẩn hóa cấu trúc tin nhắn
    normalizeMessage(message) {
      return {
        id: message.id || message.msg_id || `temp_${Date.now()}`,
        sender_id: message.sender_id || message.from_id || (message.is_outgoing ? this.currentUserId : this.recipientId),
        content: message.content || message.message || message.text || '',
        timestamp: message.timestamp || message.created_at || Date.now(),
        status: message.status || 'sent',
        attachments: Array.isArray(message.attachments) ? message.attachments : [],
        is_outgoing: message.is_outgoing || message.sender_id === this.currentUserId,
      };
    },
    
    // Kiểm tra xem tin nhắn có thuộc cuộc hội thoại hiện tại không
    isFromCurrentConversation(message) {
      if (!message) return false;
      
      const senderId = message.sender_id || message.from_id;
      const recipientId = message.recipient_id || message.to_id;
      
      return (
        (senderId === this.recipientId) || 
        (recipientId === this.recipientId)
      );
    },
    
    // Cập nhật trạng thái tin nhắn
    updateMessageStatus(messageId, status) {
      const messageIndex = this.messages.findIndex(msg => msg.id === messageId);
      
      if (messageIndex !== -1) {
        this.messages[messageIndex].status = status;
      }
    },
    
    // Gửi tin nhắn
    async sendMessage() {
      if (!this.wsClient || !this.wsClient.isConnected()) {
        this.$store.dispatch('notifications/create', {
          type: 'error',
          message: this.$t('ZALO.ERRORS.NOT_CONNECTED'),
        });
        return;
      }
      
      const messageContent = this.newMessage.trim();
      
      // Kiểm tra xem có nội dung hoặc tệp đính kèm không
      if (!messageContent && !this.selectedFile) {
        return;
      }
      
      // Tạo tin nhắn tạm thời
      const tempMessageId = `temp_${Date.now()}`;
      const tempMessage = {
        id: tempMessageId,
        sender_id: this.currentUserId,
        content: messageContent,
        timestamp: Date.now(),
        status: 'sending',
        attachments: [],
        is_outgoing: true,
      };
      
      // Thêm file đính kèm nếu có
      if (this.selectedFile) {
        tempMessage.attachments.push({
          id: `temp_file_${Date.now()}`,
          name: this.selectedFile.name,
          size: this.selectedFile.size,
          type: this.selectedFile.type,
          data_url: URL.createObjectURL(this.selectedFile),
        });
      }
      
      // Thêm tin nhắn vào danh sách
      this.messages.push(tempMessage);
      
      // Cuộn xuống dưới cùng
      this.$nextTick(() => {
        this.scrollToBottom();
      });
      
      // Xóa nội dung tin nhắn và file đính kèm
      this.newMessage = '';
      this.selectedFile = null;
      
      try {
        // Gửi tin nhắn văn bản
        if (messageContent) {
          await this.wsClient.sendMessage(this.recipientId, messageContent);
        }
        
        // Gửi file đính kèm nếu có
        if (tempMessage.attachments.length > 0) {
          // TODO: Implement file upload and sending
        }
      } catch (error) {
        console.error('Lỗi khi gửi tin nhắn:', error);
        
        // Cập nhật trạng thái tin nhắn thành lỗi
        this.updateMessageStatus(tempMessageId, 'error');
        
        this.$store.dispatch('notifications/create', {
          type: 'error',
          message: this.$t('ZALO.ERRORS.MESSAGE_SEND_FAILED', { error: error.message }),
        });
      }
    },
    
    // Mở input chọn file
    triggerFileInput() {
      this.$refs.fileInput.click();
    },
    
    // Xử lý khi chọn file
    handleFileSelection(event) {
      const files = event.target.files;
      
      if (files && files.length > 0) {
        this.selectedFile = files[0];
        
        // Kiểm tra kích thước file
        if (this.selectedFile.size > 10 * 1024 * 1024) { // 10MB
          this.$store.dispatch('notifications/create', {
            type: 'error',
            message: this.$t('ZALO.ERRORS.FILE_TOO_LARGE'),
          });
          this.selectedFile = null;
          return;
        }
        
        // Auto focus vào input tin nhắn
        this.$nextTick(() => {
          this.$refs.messageInput.focus();
        });
      }
    },
    
    // Kiểm tra xem đính kèm có phải là hình ảnh không
    isImageAttachment(attachment) {
      return attachment && attachment.type && attachment.type.startsWith('image/');
    },
    
    // Mở preview hình ảnh
    openImagePreview(attachment) {
      this.previewImageUrl = attachment.data_url;
      this.showImagePreview = true;
    },
    
    // Đóng preview hình ảnh
    closeImagePreview() {
      this.showImagePreview = false;
      this.previewImageUrl = '';
    },
    
    // Format nội dung tin nhắn
    formatMessageContent(content) {
      if (!content) return '';
      
      // Escape HTML
      let result = content
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
      
      // Convert URLs to links
      const urlRegex = /(https?:\/\/[^\s]+)/g;
      result = result.replace(urlRegex, url => {
        return `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`;
      });
      
      // Convert line breaks to <br>
      result = result.replace(/\n/g, '<br>');
      
      return result;
    },
    
    // Format kích thước file
    formatFileSize(bytes) {
      if (!bytes || bytes === 0) return '0 Bytes';
      
      const k = 1024;
      const sizes = ['Bytes', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      
      return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    },
    
    // Format thời gian
    formatTime(timestamp) {
      if (!timestamp) return '';
      
      const date = new Date(timestamp);
      
      // Nếu là hôm nay, chỉ hiển thị giờ
      const today = new Date();
      if (date.getDate() === today.getDate() && 
          date.getMonth() === today.getMonth() && 
          date.getFullYear() === today.getFullYear()) {
        return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      }
      
      // Nếu là năm hiện tại, hiển thị ngày và giờ
      if (date.getFullYear() === today.getFullYear()) {
        return date.toLocaleDateString([], { month: 'short', day: 'numeric' }) + 
               ' ' + 
               date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      }
      
      // Hiển thị đầy đủ ngày tháng năm và giờ
      return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    },
    
    // Cuộn xuống dưới cùng
    scrollToBottom() {
      if (this.$refs.messagesContainer) {
        this.$refs.messagesContainer.scrollTop = this.$refs.messagesContainer.scrollHeight;
      }
    },
    
    // Xử lý sự kiện cuộn
    handleScroll(event) {
      // Kiểm tra nếu cuộn lên đầu và còn tin nhắn để tải
      if (event.target.scrollTop === 0 && this.hasMoreMessages && !this.isLoadingMoreMessages) {
        this.loadMoreMessages();
      }
    },
    
    // Tải thêm tin nhắn cũ
    async loadMoreMessages() {
      if (!this.wsClient || !this.wsClient.isConnected() || this.isLoadingMoreMessages) {
        return;
      }
      
      this.isLoadingMoreMessages = true;
      
      try {
        // TODO: Implement loading older messages
        // Cần API hỗ trợ tải tin nhắn cũ hơn với pagination
        
        this.isLoadingMoreMessages = false;
      } catch (error) {
        console.error('Lỗi khi tải thêm tin nhắn:', error);
        this.isLoadingMoreMessages = false;
      }
    },
  },
};
</script>

<style lang="scss" scoped>
.zalo-chat-view {
  display: flex;
  flex-direction: column;
  height: 100%;
  background-color: var(--white);
}

.zalo-connection-status {
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100%;
}

.zalo-chat-container {
  display: flex;
  flex-direction: column;
  height: 100%;
}

.zalo-chat-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: var(--space-small);
  border-bottom: 1px solid var(--color-border);
  background-color: var(--white);
  height: 64px;
}

.zalo-recipient-info {
  display: flex;
  align-items: center;
  gap: var(--space-small);
}

.recipient-details {
  display: flex;
  flex-direction: column;
}

.recipient-name {
  font-size: var(--font-size-default);
  font-weight: var(--font-weight-medium);
  margin: 0;
}

.recipient-status {
  font-size: var(--font-size-small);
  color: var(--color-light-gray);
}

.zalo-chat-messages {
  flex-grow: 1;
  overflow-y: auto;
  padding: var(--space-small);
  background-color: var(--color-background-light);
}

.zalo-loading-messages,
.zalo-empty-messages {
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100%;
}

.empty-state-message {
  display: flex;
  flex-direction: column;
  align-items: center;
  color: var(--color-light-gray);
  
  i {
    font-size: 48px;
    margin-bottom: var(--space-small);
  }
  
  p {
    text-align: center;
  }
}

.zalo-message-wrapper {
  display: flex;
  margin-bottom: var(--space-small);
  
  &.zalo-message-outgoing {
    justify-content: flex-end;
    
    .zalo-message {
      background-color: var(--w-400);
      color: var(--white);
      border-radius: 16px 16px 4px 16px;
    }
    
    .zalo-message-meta {
      color: rgba(255, 255, 255, 0.7);
    }
  }
  
  &.zalo-message-incoming {
    justify-content: flex-start;
    
    .zalo-message {
      background-color: var(--color-background);
      color: var(--color-body);
      border-radius: 16px 16px 16px 4px;
    }
  }
}

.zalo-message {
  max-width: 70%;
  padding: var(--space-one);
  border-radius: 8px;
  position: relative;
}

.zalo-message-content {
  word-wrap: break-word;
  
  a {
    color: inherit;
    text-decoration: underline;
  }
}

.zalo-message-meta {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  font-size: var(--font-size-mini);
  color: var(--color-light-gray);
  margin-top: var(--space-micro);
}

.zalo-message-time {
  margin-right: var(--space-micro);
}

.zalo-message-status i {
  font-size: var(--font-size-mini);
  
  &.delivered {
    color: var(--g-400);
  }
}

.zalo-message-attachments {
  margin-top: var(--space-smaller);
}

.zalo-image-attachment {
  max-width: 100%;
  max-height: 300px;
  border-radius: 8px;
  cursor: pointer;
}

.zalo-file-attachment {
  display: flex;
  align-items: center;
  background-color: rgba(0, 0, 0, 0.05);
  padding: var(--space-smaller);
  border-radius: 8px;
  
  i {
    margin-right: var(--space-smaller);
  }
  
  .file-name {
    flex-grow: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-right: var(--space-smaller);
  }
  
  .file-size {
    font-size: var(--font-size-mini);
    color: var(--color-light-gray);
    margin-right: var(--space-smaller);
  }
  
  .download-button {
    color: inherit;
  }
}

.zalo-chat-input {
  display: flex;
  align-items: center;
  padding: var(--space-small);
  border-top: 1px solid var(--color-border);
  background-color: var(--white);
}

.zalo-message-input {
  flex-grow: 1;
  border: 1px solid var(--color-border);
  border-radius: 20px;
  padding: var(--space-smaller) var(--space-small);
  margin: 0 var(--space-smaller);
  resize: none;
  max-height: 100px;
  min-height: 40px;
  font-family: inherit;
  font-size: var(--font-size-default);
  
  &:focus {
    outline: none;
    border-color: var(--w-500);
  }
}

.image-preview-container {
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100%;
}

.preview-image {
  max-width: 90%;
  max-height: 90%;
}
</style>
