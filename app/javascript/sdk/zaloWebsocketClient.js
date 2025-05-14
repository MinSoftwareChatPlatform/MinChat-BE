import { createConsumer } from '@rails/actioncable';

/**
 * ZaloWebSocketClient - Class để kết nối tới Zalo WebSocket thông qua ActionCable
 * 
 * Cách sử dụng:
 * 
 * const client = new ZaloWebSocketClient({
 *   channelId: '1', // ID của Channel::Zalo
 *   authToken: 'token', // Auth token của người dùng
 *   onMessage: (message) => console.log('Tin nhắn mới:', message),
 *   onStatusChange: (status) => console.log('Thay đổi trạng thái:', status),
 *   onError: (error) => console.error('Lỗi:', error)
 * });
 * 
 * client.connect();
 * 
 * // Gửi tin nhắn
 * client.sendMessage('recipient_id', 'Nội dung tin nhắn')
 *   .then(response => console.log('Kết quả gửi tin:', response))
 *   .catch(error => console.error('Lỗi gửi tin:', error));
 * 
 * // Ngắt kết nối
 * client.disconnect();
 */
class ZaloWebSocketClient {
  /**
   * Khởi tạo client
   * @param {Object} config Cấu hình client
   * @param {string} config.channelId ID của Channel::Zalo
   * @param {string} config.authToken Auth token của người dùng
   * @param {Function} config.onMessage Callback khi nhận được tin nhắn
   * @param {Function} config.onStatusChange Callback khi trạng thái thay đổi
   * @param {Function} config.onError Callback khi có lỗi
   */
  constructor(config = {}) {
    // Hỗ trợ cả cách khởi tạo cũ và mới
    if (typeof config === 'string') {
      // Cách cũ: new ZaloWebSocketClient(channelId, authToken, onMessage, onStatusChange)
      const channelId = config;
      const authToken = arguments[1];
      const onMessage = arguments[2];
      const onStatusChange = arguments[3];
      
      this.channelId = channelId;
      this.authToken = authToken;
      this.onMessage = onMessage || (() => {});
      this.onStatusChange = onStatusChange || (() => {});
      this.onError = () => {};
    } else {
      // Cách mới: new ZaloWebSocketClient({ channelId, authToken, ... })
      this.channelId = config.channelId;
      this.authToken = config.authToken;
      this.onMessage = config.onMessage || (() => {});
      this.onStatusChange = config.onStatusChange || (() => {});
      this.onError = config.onError || (() => {});
    }
    
    this.subscription = null;
    this.consumer = null;
    this.connected = false;
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = config.maxReconnectAttempts || 5;
    this.reconnectInterval = config.reconnectInterval || 3000;
    this.messagesQueue = [];
    this.pendingRequests = new Map();
    this.requestTimeout = config.requestTimeout || 30000; // 30 giây timeout mặc định
    this.debug = config.debug || false;
  }

  /**
   * Kết nối đến WebSocket
   * @returns {Promise<boolean>} Promise resolves khi kết nối thành công
   */
  connect() {
    return new Promise((resolve, reject) => {
      try {
        if (this.subscription) {
          this.log('Đã kết nối, bỏ qua yêu cầu kết nối mới');
          resolve(true);
          return;
        }

        if (!this.channelId) {
          const error = new Error('Thiếu channelId để kết nối');
          this.onError(error);
          reject(error);
          return;
        }

        if (!this.authToken) {
          const error = new Error('Thiếu authToken để kết nối');
          this.onError(error);
          reject(error);
          return;
        }

        this.log(`Đang kết nối đến channel ${this.channelId}...`);
        
        // Tạo consumer nếu chưa có
        if (!this.consumer) {
          this.consumer = createConsumer(`/cable?auth_token=${this.authToken}`);
        }

        // Thiết lập timeout cho kết nối
        const connectTimeout = setTimeout(() => {
          if (!this.connected) {
            const error = new Error('Timeout khi kết nối đến channel');
            this.onError(error);
            reject(error);
            // Không gọi unsubscribe vì có thể kết nối vẫn đang được thiết lập
          }
        }, this.requestTimeout);

        // Tạo subscription mới
        this.subscription = this.consumer.subscriptions.create(
          {
            channel: 'ApplicationCable::ZaloChannel',
            channel_id: this.channelId,
          },
          {
            connected: () => {
              this.log(`Đã kết nối đến channel ${this.channelId}`);
              this.connected = true;
              this.reconnectAttempts = 0;
              clearTimeout(connectTimeout);
              
              // Thông báo trạng thái kết nối
              this.onStatusChange({ 
                type: 'connection',
                status: 'connected',
                channelId: this.channelId 
              });
              
              // Xử lý hàng đợi tin nhắn
              this.processMessageQueue();
              
              resolve(true);
            },
            
            disconnected: () => {
              this.log(`Ngắt kết nối từ channel ${this.channelId}`);
              this.connected = false;
              clearTimeout(connectTimeout);
              
              // Thông báo trạng thái ngắt kết nối
              this.onStatusChange({ 
                type: 'connection',
                status: 'disconnected',
                channelId: this.channelId 
              });
              
              // Hủy tất cả các request đang chờ
              this.pendingRequests.forEach((request) => {
                clearTimeout(request.timeout);
                request.reject(new Error('Kết nối bị ngắt'));
              });
              this.pendingRequests.clear();
              
              // Thử kết nối lại nếu cần
              this.attemptReconnect();
              
              reject(new Error('Kết nối bị ngắt'));
            },
            
            rejected: () => {
              this.log(`Kết nối đến channel ${this.channelId} bị từ chối`);
              this.connected = false;
              clearTimeout(connectTimeout);
              
              const error = new Error('Kết nối bị từ chối');
              this.onError(error);
              
              // Thông báo trạng thái từ chối
              this.onStatusChange({ 
                type: 'connection',
                status: 'rejected',
                channelId: this.channelId 
              });
              
              reject(error);
            },
            
            received: data => {
              this.log('Đã nhận dữ liệu:', data);
              
              // Xử lý dữ liệu nhận được
              if (data.event === 'message') {
                // Tin nhắn từ Zalo
                this.onMessage({
                  type: 'incoming',
                  data: data.data
                });
              } else if (data.event === 'status') {
                // Cập nhật trạng thái
                this.onStatusChange({
                  type: 'zalo_status',
                  ...data.data
                });
              } else if (data.event === 'connected') {
                // Kết nối thành công
                this.onStatusChange({
                  type: 'zalo_connected',
                  ...data.data
                });
              } else if (data.event === 'message_sent') {
                // Phản hồi từ gửi tin nhắn
                const request = this.pendingRequests.get('send_message');
                if (request) {
                  clearTimeout(request.timeout);
                  this.pendingRequests.delete('send_message');
                  
                  if (data.data.success) {
                    request.resolve(data.data);
                  } else {
                    request.reject(new Error(data.data.error || 'Lỗi gửi tin nhắn'));
                  }
                }
                
                // Cũng gửi đến callback onMessage
                this.onMessage({
                  type: 'send_result',
                  data: data.data
                });
              } else if (data.event === 'recent_messages') {
                // Phản hồi từ yêu cầu tin nhắn gần đây
                const request = this.pendingRequests.get('get_recent_messages');
                if (request) {
                  clearTimeout(request.timeout);
                  this.pendingRequests.delete('get_recent_messages');
                  request.resolve(data.data);
                }
                
                // Cũng gửi đến callback onMessage
                this.onMessage({
                  type: 'recent_messages',
                  data: data.data
                });
              } else {
                // Các loại sự kiện khác
                this.log('Sự kiện không xác định:', data);
                
                // Cũng gửi đến callback onMessage để xử lý
                this.onMessage({
                  type: 'unknown',
                  data
                });
              }
            }
          }
        );
      } catch (error) {
        this.log('Lỗi khi kết nối:', error);
        this.onError(error);
        reject(error);
      }
    });
  }

  /**
   * Ngắt kết nối WebSocket
   */
  disconnect() {
    if (this.subscription) {
      this.log(`Đang ngắt kết nối từ channel ${this.channelId}...`);
      this.subscription.unsubscribe();
      this.subscription = null;
      this.connected = false;
      
      // Hủy tất cả các request đang chờ
      this.pendingRequests.forEach((request) => {
        clearTimeout(request.timeout);
        request.reject(new Error('Kết nối bị ngắt chủ động'));
      });
      this.pendingRequests.clear();
      
      // Xóa consumer nếu cần
      if (this.consumer) {
        this.consumer = null;
      }
    }
  }

  /**
   * Gửi tin nhắn đến người dùng Zalo
   * @param {string} recipientId ID người nhận
   * @param {string} content Nội dung tin nhắn
   * @returns {Promise<Object>} Kết quả gửi tin nhắn
   */
  sendMessage(recipientId, content) {
    return new Promise((resolve, reject) => {
      if (!this.isConnected()) {
        this.log('Chưa kết nối, thêm tin nhắn vào hàng đợi');
        this.messagesQueue.push({
          type: 'send_message',
          data: { recipientId, content },
          resolve,
          reject
        });
        
        // Thử kết nối lại
        this.connect().catch(error => {
          this.log('Không thể kết nối lại để gửi tin nhắn:', error);
          // Không reject ở đây, vì tin nhắn đã được đưa vào hàng đợi
        });
        
        return;
      }
      
      try {
        // Kiểm tra dữ liệu
        if (!recipientId) {
          throw new Error('Thiếu recipientId để gửi tin nhắn');
        }
        
        if (!content) {
          throw new Error('Thiếu nội dung tin nhắn');
        }
        
        this.log(`Đang gửi tin nhắn đến ${recipientId}...`);
        
        // Tạo timeout cho request
        const timeoutId = setTimeout(() => {
          if (this.pendingRequests.has('send_message')) {
            this.pendingRequests.delete('send_message');
            reject(new Error('Timeout khi gửi tin nhắn'));
          }
        }, this.requestTimeout);
        
        // Lưu request vào danh sách đang chờ
        this.pendingRequests.set('send_message', {
          resolve,
          reject,
          timeout: timeoutId
        });
        
        // Gửi tin nhắn
        this.subscription.send({
          action: 'send_message',
          recipient_id: recipientId,
          content
        });
      } catch (error) {
        this.log('Lỗi khi gửi tin nhắn:', error);
        this.onError(error);
        reject(error);
      }
    });
  }

  /**
   * Lấy tin nhắn gần đây
   * @param {number} limit Số lượng tin nhắn tối đa
   * @returns {Promise<Object>} Danh sách tin nhắn gần đây
   */
  getRecentMessages(limit = 50) {
    return new Promise((resolve, reject) => {
      if (!this.isConnected()) {
        const error = new Error('Chưa kết nối');
        this.onError(error);
        reject(error);
        return;
      }
      
      try {
        this.log(`Đang lấy ${limit} tin nhắn gần đây...`);
        
        // Tạo timeout cho request
        const timeoutId = setTimeout(() => {
          if (this.pendingRequests.has('get_recent_messages')) {
            this.pendingRequests.delete('get_recent_messages');
            reject(new Error('Timeout khi lấy tin nhắn gần đây'));
          }
        }, this.requestTimeout);
        
        // Lưu request vào danh sách đang chờ
        this.pendingRequests.set('get_recent_messages', {
          resolve,
          reject,
          timeout: timeoutId
        });
        
        // Gửi yêu cầu
        this.subscription.send({
          action: 'get_recent_messages',
          limit
        });
      } catch (error) {
        this.log('Lỗi khi lấy tin nhắn gần đây:', error);
        this.onError(error);
        reject(error);
      }
    });
  }

  /**
   * Kiểm tra xem client đã kết nối chưa
   * @returns {boolean} Trạng thái kết nối
   */
  isConnected() {
    return this.connected && this.subscription !== null;
  }

  /**
   * Tự động kết nối lại khi mất kết nối
   * @private
   */
  attemptReconnect() {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      this.log(`Đã đạt đến số lần thử kết nối lại tối đa (${this.maxReconnectAttempts})`);
      return;
    }
    
    this.reconnectAttempts++;
    const delay = this.reconnectInterval * Math.pow(2, this.reconnectAttempts - 1);
    this.log(`Thử kết nối lại lần ${this.reconnectAttempts} sau ${delay}ms`);
    
    setTimeout(() => {
      if (!this.connected) {
        this.log('Đang thử kết nối lại...');
        this.connect().catch(error => {
          this.log('Kết nối lại thất bại:', error);
        });
      }
    }, delay);
  }

  /**
   * Xử lý hàng đợi tin nhắn
   * @private
   */
  processMessageQueue() {
    if (this.messagesQueue.length === 0 || !this.isConnected()) {
      return;
    }
    
    this.log(`Xử lý ${this.messagesQueue.length} tin nhắn trong hàng đợi`);
    
    const queue = [...this.messagesQueue];
    this.messagesQueue = [];
    
    queue.forEach(item => {
      try {
        if (item.type === 'send_message') {
          const { recipientId, content } = item.data;
          this.sendMessage(recipientId, content)
            .then(item.resolve)
            .catch(item.reject);
        }
      } catch (error) {
        this.log('Lỗi khi xử lý tin nhắn trong hàng đợi:', error);
        item.reject(error);
      }
    });
  }

  /**
   * Ghi log nếu debug được bật
   * @private
   */
  log(...args) {
    if (this.debug) {
      console.log('[ZaloWS]', ...args);
    }
  }
}

export default ZaloWebSocketClient;
