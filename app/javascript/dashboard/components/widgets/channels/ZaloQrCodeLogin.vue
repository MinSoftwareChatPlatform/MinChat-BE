<template>
  <div class="zalo-qr-login-container">
    <div v-if="isLoading" class="qr-loading-state">
      <spinner size="medium" />
      <p>{{ $t('ZALO.QR_CODE.GENERATING') }}</p>
    </div>
    
    <div v-else-if="error" class="qr-error-state">
      <span class="icon-alert text-red-400 text-4xl mb-4"></span>
      <p>{{ error }}</p>
      <woot-button 
        class="mt-4"
        size="small"
        variant="primary"
        @click="generateNewQrCode"
      >
        {{ $t('ZALO.QR_CODE.TRY_AGAIN') }}
      </woot-button>
    </div>    <div v-else-if="qrCodeUrl" class="qr-code-display">
      <h3 class="zalo-qr-title">{{ $t('ZALO.QR_CODE.SCAN_TITLE') }}</h3>
      <div class="zalo-qr-code-wrapper">
        <img :src="qrCodeUrl" alt="Zalo Login QR Code" class="zalo-qr-code" />
      </div>
      <p class="zalo-qr-instruction">{{ $t('ZALO.QR_CODE.INSTRUCTION') }}</p>
      
      <div class="zalo-qr-status" :class="statusClass">
        <div v-if="qrCodeStatus === 'pending'" class="status-indicator pending">
          <span class="icon-clock"></span>
          <span>{{ $t('ZALO.QR_CODE.STATUS.PENDING') }}</span>
        </div>
        <div v-else-if="qrCodeStatus === 'scanned'" class="status-indicator scanned">
          <span class="icon-check"></span>
          <span>{{ $t('ZALO.QR_CODE.STATUS.SCANNED') }}</span>
        </div>
        <div v-else-if="qrCodeStatus === 'confirmed'" class="status-indicator confirmed">
          <span class="icon-check-all"></span>
          <span>{{ $t('ZALO.QR_CODE.STATUS.CONFIRMED') }}</span>
        </div>
        <div v-else-if="qrCodeStatus === 'expired'" class="status-indicator expired">
          <span class="icon-alert"></span>
          <span>{{ $t('ZALO.QR_CODE.STATUS.EXPIRED') }}</span>
        </div>
      </div>
      
      <woot-button 
        v-if="qrCodeStatus === 'expired'"
        class="mt-4"
        size="small"
        variant="primary"
        @click="generateNewQrCode"
      >
        {{ $t('ZALO.QR_CODE.REFRESH') }}
      </woot-button>
    </div>
    
    <div v-else-if="isSettingUpChannel" class="zalo-channel-setup">
      <h3 class="zalo-setup-title">{{ $t('ZALO.CHANNEL_SETUP.TITLE') }}</h3>
      
      <div class="setup-status-container">
        <div v-if="setupStatus === 'connecting'" class="setup-status connecting">
          <spinner size="small" />
          <p>{{ $t('ZALO.CHANNEL_SETUP.CONNECTING') }}</p>
        </div>
        
        <div v-else-if="setupStatus === 'connected'" class="setup-status connected">
          <span class="icon-check-circle text-success text-4xl"></span>
          <p>{{ $t('ZALO.CHANNEL_SETUP.CONNECTED') }}</p>
        </div>
        
        <div v-else-if="setupStatus === 'disconnected'" class="setup-status disconnected">
          <span class="icon-alert-circle text-warning text-4xl"></span>
          <p>{{ $t('ZALO.CHANNEL_SETUP.DISCONNECTED') }}</p>
          <woot-button 
            class="mt-2"
            size="small"
            variant="primary"
            @click="handleRetryConnection"
          >
            {{ $t('ZALO.CHANNEL_SETUP.RETRY') }}
          </woot-button>
        </div>
        
        <div v-else-if="setupStatus === 'failed'" class="setup-status failed">
          <span class="icon-close-circle text-error text-4xl"></span>
          <p>{{ $t('ZALO.CHANNEL_SETUP.FAILED') }}</p>
          <p v-if="setupError" class="setup-error">{{ setupError }}</p>
          <woot-button 
            class="mt-2"
            size="small"
            variant="primary"
            @click="handleRetryConnection"
          >
            {{ $t('ZALO.CHANNEL_SETUP.RETRY') }}
          </woot-button>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import { mapGetters } from 'vuex';

export default {
  name: 'ZaloQrCodeLogin',
  
  props: {
    accountId: {
      type: [Number, String],
      required: true,
    },
  },
    data() {
    return {
      isLoading: true,
      error: null,
      qrCodeUrl: null,
      qrCodeId: null,
      qrCodeStatus: 'pending', // pending, scanned, confirmed, expired
      checkInterval: null,
      isSettingUpChannel: false, // For the channel setup process after QR code is confirmed
      setupStatus: null, // connecting, connected, disconnected, failed
      setupError: null,
      wsClient: null, // WebSocket client instance
    };
  },
  
  computed: {
    ...mapGetters({
      globalConfig: 'globalConfig/get',
    }),
    
    statusClass() {
      return `status-${this.qrCodeStatus}`;
    },
  },
  
  mounted() {
    this.generateQrCode();
  },  
  beforeDestroy() {
    this.clearCheckInterval();
    this.disconnectWebSocket();
  },
  
  methods: {
    generateQrCode() {
      this.isLoading = true;
      this.error = null;
      this.qrCodeUrl = null;
      this.qrCodeId = null;
      this.qrCodeStatus = 'pending';
      
      const url = `/api/v1/accounts/${this.accountId}/zalo/generate_qr_code`;
      
      this.$axios.post(url)
        .then(response => {
          if (response.data && response.data.success) {
            this.qrCodeUrl = response.data.qr_code_url;
            this.qrCodeId = response.data.qr_code_id;
            this.startCheckingQrCodeStatus();
          } else {
            this.error = response.data?.message || this.$t('ZALO.QR_CODE.ERRORS.GENERATION_FAILED');
          }
        })
        .catch(error => {
          this.error = error.response?.data?.message || this.$t('ZALO.QR_CODE.ERRORS.GENERATION_FAILED');
          this.$store.dispatch('notifications/create', {
            type: 'error',
            message: this.error,
          });
        })
        .finally(() => {
          this.isLoading = false;
        });
    },
    
    generateNewQrCode() {
      this.clearCheckInterval();
      this.generateQrCode();
    },
    
    startCheckingQrCodeStatus() {
      // Clear any existing interval
      this.clearCheckInterval();
      
      // Check every 3 seconds
      this.checkInterval = setInterval(() => {
        this.checkQrCodeStatus();
      }, 3000);
    },
    
    clearCheckInterval() {
      if (this.checkInterval) {
        clearInterval(this.checkInterval);
        this.checkInterval = null;
      }
    },
    
    checkQrCodeStatus() {
      if (!this.qrCodeId) return;
      
      const url = `/api/v1/accounts/${this.accountId}/zalo/check_qr_code/${this.qrCodeId}`;
      
      this.$axios.get(url)
        .then(response => {
          if (response.data && response.data.success) {
            const { status } = response.data;
            this.qrCodeStatus = status;
            
            // Handle status changes
            if (status === 'confirmed') {
              this.clearCheckInterval();
              this.handleQrCodeConfirmed(response.data);
            } else if (status === 'expired') {
              this.clearCheckInterval();
            }
          }
        })
        .catch(error => {
          console.error('Error checking QR code status:', error);
          // Don't stop checking on errors
        });
    },    
    handleQrCodeConfirmed(data) {
      // Emit event to notify parent
      this.$emit('logged-in', data);
      
      // Show success notification
      this.$store.dispatch('notifications/create', {
        type: 'success',
        message: this.$t('ZALO.QR_CODE.SUCCESS'),
      });
      
      // If we have channel data, update UI to show connecting status
      if (data.channel_id) {
        // Wait for 1 second to let user see the confirmed status before showing connecting
        setTimeout(() => {
          this.handleChannelSetupProcess(data.channel_id);
        }, 1000);
      }
    },
    
    handleChannelSetupProcess(channelId) {
      this.isSettingUpChannel = true;
      this.setupStatus = 'connecting';
      
      // Create a WebSocket connection to monitor the setup process
      const wsClient = new this.$zaloWs({
        channelId,
        authToken: this.$store.getters['auth/getAuthCredentials'].authToken,
        onStatusChange: this.handleWebSocketStatus,
        onMessage: this.handleWebSocketMessage,
        onError: this.handleWebSocketError,
        debug: false
      });
      
      this.wsClient = wsClient;
      wsClient.connect()
        .then(() => {
          this.setupStatus = 'connected';
          setTimeout(() => {
            this.isSettingUpChannel = false;
            // Notify parent component that setup is complete
            this.$emit('setup-complete', {
              channel_id: channelId,
              status: 'success'
            });
          }, 2000);
        })
        .catch(error => {
          this.setupStatus = 'failed';
          this.setupError = error.message;
          this.isSettingUpChannel = false;
          console.error('Failed to connect to Zalo WebSocket:', error);
        });
    },
    
    handleWebSocketStatus(status) {
      console.log('Zalo WebSocket status change:', status);
      if (status.type === 'connection') {
        if (status.status === 'connected') {
          this.setupStatus = 'connected';
        } else if (status.status === 'disconnected') {
          this.setupStatus = 'disconnected';
        }
      }
    },
    
    handleWebSocketMessage(message) {
      console.log('Zalo WebSocket message:', message);
    },
    
    handleWebSocketError(error) {
      console.error('Zalo WebSocket error:', error);
      this.setupStatus = 'failed';
      this.setupError = error.message;
    },
    
    handleRetryConnection() {
      if (!this.wsClient) return;
      
      this.setupStatus = 'connecting';
      this.setupError = null;
      
      this.wsClient.connect()
        .then(() => {
          this.setupStatus = 'connected';
        })
        .catch(error => {
          this.setupStatus = 'failed';
          this.setupError = error.message;
          console.error('Failed to retry connection:', error);
        });
    },
    
    disconnectWebSocket() {
      if (this.wsClient) {
        this.wsClient.disconnect();
        this.wsClient = null;
      }
    },
  },
};
</script>

<style lang="scss" scoped>
.zalo-qr-login-container {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: var(--space-normal);
  text-align: center;
  min-height: 360px;
}

.qr-loading-state,
.qr-error-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 300px;
}

.zalo-qr-title {
  font-size: var(--font-size-large);
  font-weight: var(--font-weight-medium);
  margin-bottom: var(--space-normal);
  color: var(--color-heading);
}

.zalo-qr-code-wrapper {
  width: 240px;
  height: 240px;
  padding: var(--space-normal);
  border: 1px solid var(--color-border);
  border-radius: var(--border-radius-normal);
  margin: 0 auto var(--space-normal);
  background: white;
  
  .zalo-qr-code {
    width: 100%;
    height: 100%;
    object-fit: contain;
  }
}

.zalo-qr-instruction {
  font-size: var(--font-size-small);
  color: var(--color-body);
  margin-bottom: var(--space-normal);
  max-width: 300px;
}

.zalo-qr-status {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--space-smaller) var(--space-normal);
  border-radius: var(--border-radius-normal);
  font-size: var(--font-size-small);
  font-weight: var(--font-weight-medium);
  
  &.status-pending {
    background-color: var(--y-50);
    color: var(--y-800);
  }
  
  &.status-scanned {
    background-color: var(--b-50);
    color: var(--b-800);
  }
  
  &.status-confirmed {
    background-color: var(--g-50);
    color: var(--g-800);
  }
  
  &.status-expired {
    background-color: var(--r-50);
    color: var(--r-800);
  }
  
  .status-indicator {
    display: flex;
    align-items: center;
    
    span:first-child {
      margin-right: var(--space-smaller);
    }
  }
}

.zalo-channel-setup {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 300px;
  width: 100%;
  max-width: 400px;
  margin: 0 auto;
}

.zalo-setup-title {
  font-size: var(--font-size-large);
  font-weight: var(--font-weight-medium);
  margin-bottom: var(--space-large);
  color: var(--color-heading);
}

.setup-status-container {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  width: 100%;
  padding: var(--space-normal);
  border-radius: var(--border-radius-normal);
  background-color: var(--s-50);
}

.setup-status {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: var(--space-normal);
  
  p {
    margin: var(--space-normal) 0;
    font-size: var(--font-size-normal);
    font-weight: var(--font-weight-medium);
  }
  
  &.connecting {
    color: var(--b-800);
  }
  
  &.connected {
    color: var(--g-800);
  }
  
  &.disconnected {
    color: var(--y-800);
  }
  
  &.failed {
    color: var(--r-800);
  }
}

.setup-error {
  font-size: var(--font-size-small);
  color: var(--r-500);
  margin-bottom: var(--space-normal);
  background-color: var(--r-50);
  padding: var(--space-smaller) var(--space-normal);
  border-radius: var(--border-radius-normal);
  max-width: 300px;
  word-break: break-word;
}
</style>
