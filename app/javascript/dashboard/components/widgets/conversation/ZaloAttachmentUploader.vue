<template>
  <div class="zalo-attachment-uploader">
    <label 
      class="zalo-file-upload-button"
      :class="{ 'disabled': isUploading }"
      @dragover.prevent
      @drop.prevent="handleFilesDrop"
    >
      <input 
        type="file" 
        ref="fileInput"
        multiple
        :accept="accept"
        @change="handleFilesSelected"
        :disabled="isUploading"
      />
      <span class="icon-upload-stroke"></span>
      <span class="upload-text">{{ $t('ZALO.ATTACHMENT.UPLOAD_BUTTON') }}</span>
    </label>
    
    <div v-if="isUploading" class="upload-progress">
      <spinner size="small" />
      <p>{{ $t('ZALO.ATTACHMENT.UPLOADING', { progress: uploadProgress }) }}</p>
    </div>
    
    <div v-if="error" class="upload-error">
      <span class="icon-close"></span>
      <p>{{ error }}</p>
    </div>
    
    <div v-if="previewItems.length > 0" class="attachment-previews">
      <div
        v-for="(preview, index) in previewItems"
        :key="index"
        class="attachment-preview-item"
      >
        <img 
          v-if="preview.type === 'image'"
          :src="preview.dataUrl"
          class="attachment-preview-image"
          :alt="preview.name"
        />
        <div v-else class="attachment-preview-file">
          <span class="icon-file-document"></span>
          <span class="file-name">{{ preview.name }}</span>
        </div>
        
        <button 
          class="remove-attachment-button"
          @click="removeAttachment(index)"
        >
          <span class="icon-close"></span>
        </button>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  name: 'ZaloAttachmentUploader',
  
  props: {
    recipientId: {
      type: String,
      required: true,
    },
    channelId: {
      type: [Number, String],
      required: true,
    },
    maxFileSize: {
      type: Number,
      default: 20 * 1024 * 1024, // 20MB default
    },
    accept: {
      type: String,
      default: '*/*', // All file types by default
    },
  },
  
  data() {
    return {
      isUploading: false,
      uploadProgress: 0,
      error: null,
      files: [],
      previewItems: [],
    };
  },
  
  methods: {
    handleFilesSelected(event) {
      const selectedFiles = event.target.files;
      if (!selectedFiles.length) return;
      
      this.processFiles([...selectedFiles]);
    },
    
    handleFilesDrop(event) {
      const droppedFiles = event.dataTransfer.files;
      if (!droppedFiles.length) return;
      
      this.processFiles([...droppedFiles]);
    },
    
    processFiles(fileList) {
      // Check file size
      const oversizedFiles = fileList.filter(file => file.size > this.maxFileSize);
      if (oversizedFiles.length > 0) {
        const oversizedFileNames = oversizedFiles.map(f => f.name).join(', ');
        this.error = this.$t('ZALO.ATTACHMENT.FILE_SIZE_ERROR', { 
          files: oversizedFileNames, 
          maxSize: this.formatFileSize(this.maxFileSize) 
        });
        return;
      }
      
      // Add files to the list
      this.files = [...this.files, ...fileList];
      
      // Create previews
      fileList.forEach(file => {
        const isImage = file.type.startsWith('image/');
        
        if (isImage) {
          const reader = new FileReader();
          reader.onload = e => {
            this.previewItems.push({
              type: 'image',
              file,
              name: file.name,
              dataUrl: e.target.result
            });
          };
          reader.readAsDataURL(file);
        } else {
          this.previewItems.push({
            type: 'file',
            file,
            name: file.name
          });
        }
      });
      
      // Clear the file input
      this.$refs.fileInput.value = '';
    },
    
    removeAttachment(index) {
      // Remove preview and file
      this.previewItems.splice(index, 1);
      this.files.splice(index, 1);
    },
    
    clearAttachments() {
      this.files = [];
      this.previewItems = [];
      this.isUploading = false;
      this.uploadProgress = 0;
      this.error = null;
    },
    
    uploadAttachments() {
      if (!this.files.length) {
        return Promise.resolve([]);
      }
      
      this.isUploading = true;
      this.uploadProgress = 0;
      this.error = null;
      
      const uploadPromises = this.files.map(file => this.uploadFile(file));
      
      return Promise.all(uploadPromises)
        .then(results => {
          this.clearAttachments();
          return results.filter(result => result.success);
        })
        .catch(error => {
          this.error = error.message || this.$t('ZALO.ATTACHMENT.UPLOAD_ERROR');
          this.isUploading = false;
          throw error;
        });
    },
    
    uploadFile(file) {
      return new Promise((resolve, reject) => {
        const formData = new FormData();
        formData.append('file', file);
        formData.append('recipient_id', this.recipientId);
        
        this.$axios.post(
          `/api/v1/accounts/${this.$route.params.accountId}/zalo/${this.channelId}/upload_attachment`,
          formData,
          {
            headers: {
              'Content-Type': 'multipart/form-data'
            },
            onUploadProgress: progressEvent => {
              const percentCompleted = Math.round(
                (progressEvent.loaded * 100) / progressEvent.total
              );
              this.uploadProgress = percentCompleted;
            }
          }
        )
        .then(response => {
          if (response.data.success) {
            resolve({
              success: true,
              attachment_id: response.data.attachment_id,
              file_type: response.data.file_type,
              name: file.name,
              size: file.size
            });
          } else {
            reject(new Error(response.data.message || this.$t('ZALO.ATTACHMENT.UPLOAD_FAILED')));
          }
        })
        .catch(error => {
          reject(error);
        });
      });
    },
    
    formatFileSize(bytes) {
      if (bytes === 0) return '0 Bytes';
      
      const k = 1024;
      const sizes = ['Bytes', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      
      return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }
  }
};
</script>

<style lang="scss" scoped>
.zalo-attachment-uploader {
  margin-bottom: var(--space-small);
}

.zalo-file-upload-button {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--space-smaller) var(--space-normal);
  border: 1px dashed var(--color-border-dark);
  border-radius: var(--border-radius-normal);
  background-color: var(--s-25);
  color: var(--s-700);
  cursor: pointer;
  transition: all 0.2s ease;
  width: 100%;
  
  &:hover {
    background-color: var(--s-50);
    border-color: var(--s-400);
  }
  
  &.disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }
  
  input[type="file"] {
    display: none;
  }
  
  .icon-upload-stroke {
    margin-right: var(--space-smaller);
  }
}

.upload-progress {
  display: flex;
  align-items: center;
  margin-top: var(--space-smaller);
  font-size: var(--font-size-small);
  color: var(--b-600);
  
  p {
    margin-left: var(--space-smaller);
  }
}

.upload-error {
  display: flex;
  align-items: center;
  margin-top: var(--space-smaller);
  padding: var(--space-smaller) var(--space-normal);
  background-color: var(--r-50);
  border-radius: var(--border-radius-normal);
  font-size: var(--font-size-small);
  color: var(--r-600);
  
  .icon-close {
    margin-right: var(--space-smaller);
    color: var(--r-500);
  }
}

.attachment-previews {
  display: flex;
  flex-wrap: wrap;
  margin-top: var(--space-smaller);
  gap: var(--space-smaller);
}

.attachment-preview-item {
  position: relative;
  width: 80px;
  height: 80px;
  border-radius: var(--border-radius-normal);
  border: 1px solid var(--color-border);
  overflow: hidden;
  
  .attachment-preview-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  
  .attachment-preview-file {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    width: 100%;
    height: 100%;
    background-color: var(--s-25);
    padding: var(--space-smaller);
    
    .icon-file-document {
      font-size: var(--font-size-big);
      color: var(--s-600);
      margin-bottom: var(--space-micro);
    }
    
    .file-name {
      font-size: var(--font-size-micro);
      color: var(--s-800);
      width: 100%;
      text-align: center;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
  }
  
  .remove-attachment-button {
    position: absolute;
    top: 2px;
    right: 2px;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    background-color: rgba(0, 0, 0, 0.5);
    color: white;
    display: flex;
    align-items: center;
    justify-content: center;
    border: none;
    cursor: pointer;
    padding: 0;
    font-size: var(--font-size-micro);
    
    &:hover {
      background-color: rgba(0, 0, 0, 0.7);
    }
  }
}
</style>
