# Các routes cho tính năng Zalo
Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      namespace :accounts do
        resources :zalo, only: [:index, :show, :create, :update, :destroy] do
          collection do
            post 'generate_qr_code', to: 'zalo#generate_qr_code'
            get 'check_qr_code/:qr_code_id', to: 'zalo#check_qr_code'
            post 'send_message', to: 'zalo#send_message'
            post 'upload_attachment', to: 'zalo#upload_attachment'
            post 'connect_ws', to: 'zalo#connect_ws'
            get 'websocket', to: 'zalo#websocket'
          end
        end

        # Zalo webhook routes
        resources :zalo_webhooks, only: [:create]
      end
    end
  end
end
