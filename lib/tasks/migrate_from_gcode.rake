# Redmine - project management software
# Copyright (C) 2006-2015  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'active_record'
require 'json'
require 'securerandom'
require 'time'

namespace :redmine do
  desc 'Google Code migration script'
  task :migrate_from_gcode => :environment do
    module GCodeMigrate
      # Note: This does not map to the "standard" Redmine initial data. This is
      # a custom set of statuses, priorities, and custom fields used by
      # Dolphin's instance of Redmine.
      new_status = IssueStatus.find_by_name("New")
      questionable_status = IssueStatus.find_by_name("Questionable")
      accepted_status = IssueStatus.find_by_name("Accepted")
      started_status = IssueStatus.find_by_name("Work started")
      fix_pending_status = IssueStatus.find_by_name("Fix pending")
      fixed_status = IssueStatus.find_by_name("Fixed")
      invalid_status = IssueStatus.find_by_name("Invalid")
      wontfix_status = IssueStatus.find_by_name("Won't fix")
      wai_status = IssueStatus.find_by_name("Working as intended")
      duplicate_status = IssueStatus.find_by_name("Duplicate")
      DEFAULT_STATUS = new_status
      STATUS_MAPPING = {
        "new" => new_status,
        "questionable" => questionable_status,
        "accepted" => accepted_status,
        "started" => started_status,
        "fixedinpr" => fix_pending_status,
        "fixed" => fixed_status,
        "invalid" => invalid_status,
        "wontfix" => wontfix_status,
        "userisbadatgames" => wai_status,
        "duplicate" => duplicate_status,
      }

      priorities = IssuePriority.all
      DEFAULT_PRIORITY = priorities[1]
      PRIORITY_MAPPING = {
        'low' => priorities[0],
        'medium' => priorities[1],
        'high' => priorities[2],
        'critical' => priorities[3]
      }

      DEFAULT_TRACKER = Tracker.find_by_name('Bug')

      class ::Time
        class << self
          alias :real_now :now
          def now
            real_now - @fake_diff.to_i
          end
          def fake(time)
            @fake_diff = real_now - time
            res = yield
            @fake_diff = 0
           res
          end
        end
      end

      def self.set_takeout_file(path)
        @takeout_data = JSON.parse(File.read(path))
      end

      def self.set_gcode_project_name(name)
        @takeout_data['projects'].each do |project|
          if project['name'] == name
            @takeout_project = project
            return @takeout_project
          end
        end
        puts "Project name not present in the takeout data."
      end

      def self.set_target_project_name(identifier)
        project = Project.find_by_identifier(identifier)
        if !project
          # create the target project
          project = Project.new :name => identifier.humanize,
                                :description => ''
          project.identifier = identifier
          puts "Unable to create a project with identifier '#{identifier}'!" unless project.save
          # enable issues and wiki for the created project
          project.enabled_module_names = ['issue_tracking', 'wiki']
        else
          puts
          puts "This project already exists in your Redmine database."
          print "Are you sure you want to append data to this project ? [Y/n] "
          STDOUT.flush
          exit if STDIN.gets.match(/^n$/i)
        end
        project.trackers << DEFAULT_TRACKER unless project.trackers.include?(DEFAULT_TRACKER)
        @target_project = project.new_record? ? nil : project
        @target_project.reload
      end

      def self.find_or_create_user(username)
        return User.anonymous if (!username || username.blank?)

        if username.include?("@")
          mail = username
          username = username.gsub(/^([^+@]+).*$/, '\1')
        else
          mail = "#{username}@gmail.com"
        end

        u = User.find_by_login(username)
        if !u
          u = User.new :mail => mail,
                       :firstname => username,
                       :lastname => "-"
          u.login = username
          u.password = SecureRandom.hex
          u.admin = false
          u = User.anonymous unless u.save
        end
        u
      end

      def self.ts(str)
        return Time.iso8601(str)
      end

      def self.find_label(labels, prefix)
        return nil unless labels
        labels.each do |l|
          l.downcase!
          if l.start_with? (prefix + '-')
            l.slice! (prefix + "-")
            return l
          end
        end
        nil
      end

      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end

      def self.migrate
        print 'Migrating issues'
        @takeout_project['issues']['items'].each do |issue|
          print '.'
          Issue.find(issue['id']).delete if Issue.exists?(issue['id'])
          title = issue['title']
          if title.blank?
            title = '[No title]'
          end
          i = Issue.new :project => @target_project,
                        :subject => title[0, 255],
                        :description => issue['comments']['items'][0]['content'],
                        :priority => PRIORITY_MAPPING[find_label(issue['labels'], 'priority')] || DEFAULT_PRIORITY,
                        :created_on => ts(issue['published'])
          i.author = find_or_create_user(issue['author']['name'])
          # TODO: Component and other labels.
          i.tracker = DEFAULT_TRACKER
          i.status = STATUS_MAPPING[issue['status'].downcase] || DEFAULT_STATUS
          i.id = issue['id']
          if issue['owner']
            i.assigned_to = find_or_create_user(issue['owner']['name'])
          end
          next unless Time.fake(ts(issue['updated'])) { i.save! }
        end
      end
    end

    puts
    if Redmine::DefaultData::Loader.no_data?
      puts "Redmine configuration need to be loaded before importing data."
      puts "Please, run this first:"
      puts
      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    end

    puts "WARNING: a new project will be added to Redmine during this process."
    print "Are you sure you want to continue ? [y/N] "
    STDOUT.flush
    break unless STDIN.gets.match(/^y$/i)
    puts

    def prompt(text, options = {}, &block)
      default = options[:default] || ''
      while true
        print "#{text} [#{default}]: "
        STDOUT.flush
        value = STDIN.gets.chomp!
        value = default if value.blank?
        break if yield value
      end
    end

    prompt('Takeout JSON file') {|path| GCodeMigrate.set_takeout_file path}
    prompt('Project name') {|name| GCodeMigrate.set_gcode_project_name name}
    prompt('Target project name') {|name| GCodeMigrate.set_target_project_name name}
    puts

    old_notified_events = Setting.notified_events
    old_password_min_length = Setting.password_min_length
    begin
      # Turn off email notifications temporarily
      Setting.notified_events = []
      Setting.password_min_length = 4
      # Run the migration
      GCodeMigrate.migrate
    ensure
      # Restore previous settings
      Setting.notified_events = old_notified_events
      Setting.password_min_length = old_password_min_length
    end
  end
end
