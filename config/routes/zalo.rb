# Các routes cho tính năng Zalo
Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      namespace :accounts do
        resources :zalo, only: [:index, :show, :create, :update, :destroy] do
          collection do
            post :check_qr_code
            post :send_message
            get :websocket_status
          end
          
          member do
            post :upload_attachment
            post :send_message 
            post :check_friend_status
            post :send_friend_request
            post :accept_friend_request
          end
        end
        
        # Zalo webhook routes
        resources :zalo_webhooks, only: [:create]
      end
    end
  end
end