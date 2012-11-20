module TentD
  module Model
    class NotificationSubscription < Sequel::Model(:notification_subscriptions)
      include TypeProperties

      many_to_one :app_authorization
      many_to_one :follower

      def before_create
        self.user_id ||= User.current.id
        self.created_at = Time.now
        super
      end

      def before_save
        self.updated_at = Time.now
        super
      end

      def self.notify(subscription_id, post_id)
        subscription = first(:id => subscription_id)
        subscription.notify_about(post_id) if subscription
      end

      def self.notify_all(type, post_id)
        post = Post.select(:id, :original, :public, :user_id).first(:id => post_id)
        return unless post
        if post.original && post.public
          NotificationSubscription.select(
            :id, :app_authorization_id, :follower_id
          ).where(
            :user_id => post.user_id,
            :type_base => [TentType.new(type).base, 'all']
          ).all.each do |subscription|
            next unless post.can_notify?(subscription.subject)
            Notifications.notify(
              :subscription_id => subscription.id,
              :post_id => post_id,
              :view => subscription.type_view
            )
          end
        elsif !post.original
          # TODO needs spec
          # q = NotificationSubscription.select(
          #   :id, :app_authorization_id, :follower_id
          # ).where(
          #   :user_id => post.user_id,
          #   :type_base => [TentType.new(type).base, 'all']
          # ).where(
          #   Sequel.~(:app_authorization_id => nil)
          # ).all.each do |subscription|
          #   next unless post.can_notify?(subscription.subject)
          #   Notifications.notify(
          #     :subscription_id => subscription.id,
          #     :post_id => post_id,
          #     :view => subscription.type_view
          #   )
          # end
        else
          # TODO needs spec
          # SELECT "id", "type_base", "type_view", "type_version", "created_at", "updated_at", "user_id", "app_authorization_id", "follower_id" FROM "notification_subscriptions" WHERE "follower_id" IN (SELECT "id" FROM "followers" WHERE ("deleted_at" IS NULL AND "id" IN (SELECT "follower_access_id" FROM "permissions" WHERE "post_id" = 1))) ORDER BY "id"
          # NotificationSubscription.join(
          #   Follower,
          #   :notification_subscriptions__follower_id => :followers_id
          # ).join(
          #   Permission,
          #   :permissions__follower_access_id => :followers__id
          # ).join(
          #   Post,
          #   :permissions__post_id => :posts__id
          # ).where(
          #   :notification_subscriptions__type_base => [type.base, 'all'],
          #   :permissions__post_id => post.id
          # ).select(
          #   :notification_subscriptions__id,
          #   :notification_subscriptions__app_authorization_id,
          #   :notification_subscriptions__follower_id
          # ).all.each do |subscription|
          #   next unless post.can_notify?(subscription.subject)
          #   Notifications.notify(:subscription_id => subscription.id, :post_id => post_id, :view => subscription.type_view)
          # end
        end
      end

      def self.notify_entity(entity, post_id, view='full')
        post = Post.first(:id => post_id)
        return unless post
        return if post.entity == entity
        entity = 'https://' + entity if !entity.match(%r{\Ahttp})
        follow = Follower.first(:user_id => post.user_id, :entity => entity) ||
                 Following.first(:user_id => post.user_id, :entity => entity)
        if follow
          return unless post.can_notify?(follow)
          client = TentClient.new(follow.notification_servers, follow.auth_details.merge(:faraday_adapter => TentD.faraday_adapter))
          path = follow.notification_path
        else
          return unless post.public
          profile, server_url = TentClient.new(nil, :faraday_adapter => TentD.faraday_adapter).discover(entity).get_profile
          server_urls = API::CoreProfileData.new(profile).servers
          client = TentClient.new(server_urls, :faraday_adapter => TentD.faraday_adapter)
          path = 'posts'
        end
        res = client.post.create(post.as_json(:view => view), :url => path)
        raise NotificationError.new("[#{res.to_hash[:url].to_s}] #{res.status}: #{res.body}") unless (200...300).include?(res.status)
        res
      end

      def notify_about(post_id, view='full')
        post = Post.first(:id => post_id)
        return unless post
        client = TentClient.new(subject.notification_servers, subject.auth_details.merge(:faraday_adapter => TentD.faraday_adapter))
        permissions = subject.respond_to?(:scopes) && subject.scopes.to_a.include?(:read_permissions)
        res = client.post.create(post.as_json(:app => !!app_authorization, :permissions => permissions, :view => view), :url => subject.notification_path)
        raise NotificationError.new("[#{res.to_hash[:url].to_s}] #{res.status}: #{res.body}") unless (200...300).include?(res.status)
        res
      rescue Faraday::Error::ConnectionFailed => e
        url = res ? res.to_hash[:url].to_s : ""
        raise NotificationError.new(:message => "[#{url}] #{e.message}", :backtrace => e.backtrace)
      end

      def subject
        app_authorization || follower
      end
    end                              
  end
end

# module TentD
#   module Model
#     class XNotificationSubscription
#       NotificationError = Class.new(StandardError)
#
#       include DataMapper::Resource
#       include TypeProperties
#       include UserScoped
#
#       storage_names[:default] = 'notification_subscriptions'
#
#       property :id, Serial
#       property :created_at, DateTime
#       property :updated_at, DateTime
#
#       belongs_to :app_authorization, 'TentD::Model::AppAuthorization', :required => false
#       belongs_to :follower, 'TentD::Model::Follower', :required => false
#
#     end
#   end
# end
