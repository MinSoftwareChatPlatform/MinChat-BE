<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
// import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import PageHeader from '../../SettingsSubPageHeader.vue';
// import router from '../../../../index';
import NextButton from 'dashboard/components-next/button/Button.vue';

import { isPhoneE164OrEmpty } from 'shared/helpers/Validators';

export default {
  components: {
    NextButton,
    PageHeader,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      isLoading: false,
      isShow: false,
      showQRButton: true,
      showCountdown: false,
      countdown: 60,
      countdownTimer: null,
    };
  },
  computed: {
    ...mapGetters({ uiFlags: 'inboxes/getUIFlags' }),
  },
  validations: {
    inboxName: { required },
    phoneNumber: { required, isPhoneE164OrEmpty },
    apiKey: { required },
  },
  beforeUnmount() {
    if (this.countdownTimer) {
      clearInterval(this.countdownTimer);
    }
  },
  methods: {
    // async createChannel() {
    //   this.v$.$touch();
    //   if (this.v$.$invalid) {
    //     return;
    //   }

    //   try {
    //     const zaloChannel = await this.$store.dispatch(
    //       'inboxes/createChannel',
    //       {
    //         name: this.inboxName,
    //         channel: {
    //           type: 'zalo',
    //           phone_number: this.phoneNumber,
    //           provider_config: {
    //             api_key: this.apiKey,
    //           },
    //         },
    //       }
    //     );

    //     router.replace({
    //       name: 'settings_inboxes_add_agents',
    //       params: {
    //         page: 'new',
    //         inbox_id: zaloChannel.id,
    //       },
    //     });
    //   } catch (error) {
    //     useAlert(
    //       error.message || this.$t('INBOX_MGMT.ADD.ZALO.API.ERROR_MESSAGE')
    //     );
    //   }
    // },
    generateQRCode() {
      this.showQRButton = false;
      this.showCountdown = true;
      this.countdown = 60;

      // Show loading state in the QR square
      this.isLoading = true;

      // Simulate API call with 3 second delay
      setTimeout(() => {
        // Hide loading, show fake QR
        this.isLoading = false;
        this.qrImageUrl = '/assets/images/qrcode.png';

        // Start the countdown
        this.startCountdown();
      }, 3000);
    },

    startCountdown() {
      this.countdownTimer = setInterval(() => {
        this.countdown -= 1;
        if (this.countdown <= 0) {
          clearInterval(this.countdownTimer);
          this.showCountdown = false;
          this.showQRButton = true;
        }
      }, 1000);
    },
  },
};
</script>

<template>
  <div
    class="border border-n-weak bg-n-solid-1 rounded-t-lg border-b-0 h-full w-full p-6 col-span-6 overflow-auto"
  >
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.ZALO.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.ZALO.DESC')"
    />
    <NextButton
      v-if="showQRButton"
      :label="$t('INBOX_MGMT.ADD.ZALO.QR_CODE.GENERATE_BUTTON')"
      :is-loading="uiFlags.isCreating"
      @click="generateQRCode"
    />

    <div v-if="showCountdown" class="qr-countdown-container">
      <div class="qr-code-square">
        <div v-if="isLoading" class="loading-spinner" />
        <img
          v-else-if="qrImageUrl"
          :src="qrImageUrl"
          alt="QR Code"
          class="qr-image"
        />
        <div v-else class="countdown-number" />
      </div>
      <span class="mt-2"
        >{{ countdown }}{{ $t('INBOX_MGMT.ADD.ZALO.TIMER_SECONDS') }}</span
      >
    </div>
  </div>
</template>

<style scoped>
.qr-countdown-container {
  display: flex;
  justify-content: center;
  margin-bottom: 16px;
  align-items: start;
  flex-direction: column;
}

.qr-code-square {
  width: 200px;
  height: 200px;
  background-color: #f0f0f0;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 8px;
}

.countdown-number {
  font-size: 24px;
  font-weight: bold;
}
.loading-spinner {
  width: 40px;
  height: 40px;
  border: 4px solid rgba(0, 0, 0, 0.1);
  border-radius: 50%;
  border-top-color: #3490dc;
  animation: spin 1s ease-in-out infinite;
}

@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

.qr-image {
  width: 80%;
  height: 80%;
}
</style>
