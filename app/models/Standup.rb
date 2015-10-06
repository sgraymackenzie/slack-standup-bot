class Standup < ActiveRecord::Base

  class << self
    def check_registration(client, data, first_user)
      unless User.registered?(data['user'])
        full_name = client.users.find { |what| what['id'] == data['user'] }["profile"]["real_name_normalized"]
        User.create(user_id: data['user'], full_name: full_name)
      end
      being_standup(client, data, first_user)
    end

    def being_standup(client, data, first_user)
      Standup.create(user_id: data['user'], created_at: Time.now)
      unless first_user
        client.message channel: data['channel'], text: "Goodmorning <@#{data['user']}>, Welcome to daily standup! Are you ready to begin?  ('yes', or 'skip')"
      else
        User.find_by_user_id(data['user']).update_attributes(admin_user: true)
      end
    end

    def skip_until_last_standup(client, data, standup)
      user = User.find_by_user_id(data['user'])
      user.update_attributes(sort_order: user.sort_order + 1)
      client.message channel: data['channel'], text: "I'll get back to you at the end of standup."
      standup.delete
      next_user
    end

    def question_1(client, data, user)
      day_string = Time.now.wday
      day = ->num { Date::DAYNAMES[num] }
      if day.(day_string) == "Monday"
        client.message channel: data['channel'], text: "1. What did you do on Friday?"
      else
        client.message channel: data['channel'], text: "1. What did you do yesterday?"
      end
      user.update_attributes(standup_status: "ready")
    end

    def check_for_standup(data)
      Standup.where(created_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day, user_id: data['user'])
    end

    def first_standup?
      Standup.where(created_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day).empty?
    end

    def check_question(client, data, current_standup)
      if current_standup.yesterday.nil?
        yesterday(current_standup, client, data)
      elsif current_standup.today.nil?
        today(current_standup, client, data)
      elsif current_standup.conflicts.nil?
        conflicts(current_standup, client, data)
      end
    end

    def get_channel(client)
      if @settings.channel_type == "group"
        channel = client.groups_list['groups'].detect { |c| c['name'] == 'standup-test' }
      else
        channel = client.channels_list['channels'].detect { |c| c['name'] == 'standup-test' }
      end
    end

    def get_web_client_channel(client)
      if @settings.channel_type == "group"
        client.groups.detect { |c| c['name'] == 'standup-test' }
      else
        client.channels.detect { |c| c['name'] == 'standup-test' }
      end
    end

    def next_user
      client = Slack::Web::Client.new
      channel = client.groups_list['groups'].detect { |c| c['name'] == 'standup-test' }
      users = channel['members']
      non_complete_users = []
      users.each do |user_id|
        unless user_id == @settings.bot_id
          non_complete_users << user_id if Standup.where(created_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day, user_id: user_id).empty?
        end
      end
      non_complete_users = User.sort_users(non_complete_users)
      client = Slack::RealTime::Client.new
      unless non_complete_users.empty?
        data = {}
        data['channel'] = channel['id']
        data['user'] = non_complete_users.first
        client = Slack::RealTime::Client.new
        client.start!
        User.check_name(client, data['user'])
        check_registration(client, data, false)
      else
        client.start!
        client.message channel: channel, text: "That concludes our standup. For a recap visit http://quiet-shore-3330.herokuapp.com/"
        client.stop!
      end
    end

    def complete?(client)
      channel = client.groups.detect { |c| c['name'] == 'standup-test' }
      users = channel['members']
      standups = Standup.where(created_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day, status: ["vacation", "complete"])
      users.count - 1 == standups.count
    end

    def yesterday(standup, client, data)
      standup.update_attributes(yesterday: data['text'])
      client.message channel: data['channel'], text: "2. What are you working on today?"
    end

    def today(standup, client, data)
      standup.update_attributes(today: data['text'])
      client.message channel: data['channel'], text: "3. Is there anything standing in your way?"
    end

    def conflicts(standup, client, data)
      standup.update_attributes(conflicts: data['text'], status: "complete")
      client = Slack::Web::Client.new
      channel = client.groups_list['groups'].detect { |c| c['name'] == 'standup-test' }
      client.chat_postMessage(channel: channel['id'], text: 'Good Luck Today!', as_user: true)
      User.find_by_user_id(data['user']).update_attributes(standup_status: "not_ready", sort_order: 1)
      next_user
    end


    def admin_skip(data, client)
      user_id = data['text'][/\<.*?\>/].gsub(/[<>@]/, "")
      standup = Standup.where(user_id: user_id, created_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day).first
      if User.find_by_user_id(data['user']).nil? || User.find_by_user_id(data['user']).admin_user == false
        client.message channel: data['channel'], text: "You don't have permission to skip a user"
      else
        user = User.find_by_user_id(user_id)
        user.update_attributes(sort_order: user.sort_order + 1)
        client.message channel: data['channel'], text: "I'll get back to you at the end of standup."
        standup.delete
        Standup.next_user
      end
    end

    def vacation(data, client)
      user_id = data['text'][/\<.*?\>/].gsub(/[<>@]/, "")
      unless User.find_by_user_id(user_id)
        User.create(user_id: user_id)
        User.check_name(client, user_id)
      end
      standup = Standup.where(user_id: user_id, created_at: Time.zone.now.beginning_of_day..Time.zone.now.end_of_day).first
      if User.find_by_user_id(data['user']).nil? || User.find_by_user_id(data['user']).admin_user == false
        client.message channel: data['channel'], text: "You don't have permission to vacation a user"
      elsif standup && standup.status == "complete"
        client.message channel: data['channel'], text: "<@#{user_id}> has already completed standup today."
      elsif standup
        standup.update_attributes(yesterday: "Vacation", status: "vacation")
        client.message channel: data['channel'], text: "<@#{user_id}> has been put on vacation."
        if Standup.complete?(client)
<<<<<<< HEAD
=======
          channel = client.groups.detect { |c| c['name'] == 'standup-test' }['id']
>>>>>>> 014949c... test
          client.message channel: data['channel'], text: "That concludes our standup. For a recap visit http://quiet-shore-3330.herokuapp.com/"
          client.stop!
        else
          Standup.next_user
        end
      else
        Standup.create(user_id: user_id, status: "vacation", yesterday: "Vacation")
        client.message channel: data['channel'], text: "<@#{user_id}> has been put on vacation."
        client.message channel: data['channel'], text: " <@#{data['user']}>, Welcome to daily standup! Are you ready to begin?  ('yes', or 'skip')"
      end
    end
  end

  def not_complete?
    status != "complete"
  end

  def complete?
    status == "complete"
  end
end