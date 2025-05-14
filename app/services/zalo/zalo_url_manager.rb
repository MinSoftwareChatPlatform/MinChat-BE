module Zalo
  module URLManager
    module Login
      BASE_URL = 'https://wpa.chat.zalo.me/api/login'
      GET_LOGIN_INFO = "#{BASE_URL}/getLoginInfo"
    end

    module Message
      BASE_USER = 'https://tt-chat2-wpa.chat.zalo.me/api/message'
      BASE_GROUP = 'https://tt-group-wpa.chat.zalo.me/api/group'
      USER = "#{BASE_USER}/sms"
      UNDO_USER = "#{BASE_USER}/undo"
      GROUP = "#{BASE_GROUP}/sendmsg"
      UNDO_GROUP = "#{BASE_GROUP}/undomsg"
      MENTION = "#{BASE_GROUP}/mention"

      def self.text_message(is_group)
        is_group ? GROUP : USER
      end

      def self.undo_message(is_group)
        is_group ? UNDO_GROUP : UNDO_USER
      end
    end

    module File
      BASE_URL = 'https://tt-files-wpa.chat.zalo.me/api'
      UPLOAD_TO_GROUP = "#{BASE_URL}/group/"
      UPLOAD_TO_USER = "#{BASE_URL}/message/"

      def self.upload(is_group)
        is_group ? UPLOAD_TO_GROUP : UPLOAD_TO_USER
      end
    end

    module Friend
      BASE_URL = 'https://tt-friend-wpa.chat.zalo.me/api/friend'
      SEND_REQUEST = "#{BASE_URL}/sendreq"
      GET_STATUS = "#{BASE_URL}/reqstatus"
      GET_RECOMMENDATIONS = "#{BASE_URL}/recommendsv2/list"
      GET_PROFILE = "#{BASE_URL}/profile/get"
      ACCEPT = "#{BASE_URL}/accept"
      REMOVE = "#{BASE_URL}/remove"
      UNDO = "#{BASE_URL}/undo"
    end

    module Profile
      BASE_PROFILE = 'https://tt-profile-wpa.chat.zalo.me/api/social/profile'
      BASE_FRIEND = 'https://tt-profile-wpa.chat.zalo.me/api/social/friend'
      BASE_GET_FRIENDS = 'https://profile-wpa.chat.zalo.me/api/social/friend'
      GET_MY_INFO = "#{BASE_PROFILE}/me-v2"
      UPDATE = "#{BASE_PROFILE}/update"
      GET_AVATAR = "#{BASE_PROFILE}/avatar"
      GET_PROFILES_V2 = "#{BASE_FRIEND}/getprofiles/v2"
      GET_FRIENDS = "#{BASE_GET_FRIENDS}/getfriends"
    end

    module Group
      BASE_URL = 'https://tt-group-wpa.chat.zalo.me/api/group'
      GET_ALL = "#{BASE_URL}/getlg/v4"
      GET_INFO = "#{BASE_URL}/getmg-v2"
      LINK_INFO = "#{BASE_URL}/link/ginfo"
      JOIN_BY_LINK = "#{BASE_URL}/link/join"
      GET_LINK_DETAIL = "#{BASE_URL}/link/detail"
      LEAVE = "#{BASE_URL}/leave"
      INVITE = "#{BASE_URL}/invite"
    end
  end
end