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

      DEFAULT_TRACKER = Tracker.find_by_name('Issue')

      USER_MAPPING = {
        "admin@archshift.com" => "archshift",
      }

      opsys_cf = IssueCustomField.find_by_name('Operating system')
      type_cf = IssueCustomField.find_by_name('Issue type')
      milestone_cf = IssueCustomField.find_by_name('Milestone')
      regression_cf = IssueCustomField.find_by_name('Regression')
      usability_cf = IssueCustomField.find_by_name('Relates to usability')
      performance_cf = IssueCustomField.find_by_name('Relates to performance')
      maintainability_cf = IssueCustomField.find_by_name('Relates to maintainability')
      easy_cf = IssueCustomField.find_by_name('Easy')
      LABELS_MAPPING = {
        "opsys" => [opsys_cf, "N/A", {
          "android" => "Android",
          "windows" => "Windows",
          "osx" => "OS X",
          "bsd" => "FreeBSD"
        }],
        "type" => [type_cf, "Other", {
          "defect" => "Bug",
          "enhancement" => "Feature request",
          "task" => "Task",
        }],
        "milestone" => [milestone_cf, nil, nil],
        "regression" => [regression_cf, nil, nil],
        "usability" => [usability_cf, nil, nil],
        "performance" => [performance_cf, nil, nil],
        "maintainability" => [maintainability_cf, nil, nil],
        "easy" => [easy_cf, nil, nil],
      }

      class FakeComponentMapping
        def [](key)
          GCodeMigrate.find_or_create_category(key)
        end
      end
      SPECIAL_LABELS = {
        'priority' => ['priority_id', DEFAULT_PRIORITY, PRIORITY_MAPPING],
        'component' => ['category_id', nil, FakeComponentMapping.new],
      }

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

        if USER_MAPPING[username]
          mail = username
          username = USER_MAPPING[username]
        elsif username.include?("@")
          mail = username
          username = username.gsub(/^([^+@]+).*$/, '\1')
        else
          mail = "#{username}@gmail.com"
        end

        return User.anonymous if username == 'admin'

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

      def self.find_or_create_category(category)
        c = IssueCategory.find_by_name(category)
        if !c
          c = IssueCategory.new :project => @target_project, :name => category
          c.save!
        end
        c
      end

      def self.ts(str)
        return Time.iso8601(str)
      end

      def self.cut_label(lbl)
        lbl.gsub(/^(-?[^-]+)(?:-(.*))?$/) do |m|
          lbl, value = $1, $2
          if value.blank?
            value = "Yes"
          end
          return [lbl, value]
        end
      end

      def self.find_label(labels, prefix)
        return nil unless labels
        labels.each do |l|
          label, value = cut_label(l)
          label.downcase!
          if label == prefix
            return value
          end
        end
        nil
      end

      def self.compute_label_diff(labels)
        diff = {}
        labels.each do |l|
          label, value = cut_label(l)
          label.downcase!
          if label[0] == '-'
            label = label[1..-1]
            if diff[label]
              diff[label] = [:mod, diff[label][1], value]
            else
              diff[label] = [:del, value, nil]
            end
          else
            if diff[label]
              diff[label] = [:mod, value, diff[label][1]]
            else
              diff[label] = [:add, value, nil]
            end
          end
        end
        diff
      end

      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end

      def self.migrate
        print 'Migrating issues '
        @takeout_project['issues']['items'].each do |issue|
          print '|', issue['id'], '|'
          Issue.find(issue['id']).destroy if Issue.exists?(issue['id'])
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
          i.tracker = DEFAULT_TRACKER
          i.status = STATUS_MAPPING[issue['status'].downcase] || DEFAULT_STATUS
          i.id = issue['id']
          if issue['owner']
            i.assigned_to = find_or_create_user(issue['owner']['name'])
          end
          category = find_label(issue['labels'], 'component')
          if category
            i.category = find_or_create_category(category)
          end
          next unless Time.fake(ts(issue['published'])) { i.save! }

          # Comments and fields/status changes.
          prev_status = DEFAULT_STATUS
          issue['comments']['items'][1..-1].each do |comment|
            print '.'
            next if comment['deletedBy']
            n = Journal.new :notes => comment['content'],
                            :created_on => ts(comment['published'])
            n.user = find_or_create_user(comment['author']['name'])
            n.journalized = i
            if comment['updates']['status']
              new_status = STATUS_MAPPING[comment['updates']['status'].downcase]
              if new_status
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => 'status_id',
                                               :old_value => prev_status.id,
                                               :value => new_status.id)
                prev_status = new_status
              end
            end
            if comment['updates']['labels']
              compute_label_diff(comment['updates']['labels']).each do |label, (type, value, prev)|
                if SPECIAL_LABELS[label]
                  property = 'attr'
                  prop_key, default, value_remap = SPECIAL_LABELS[label]
                else
                  property = 'cf'
                  next unless LABELS_MAPPING[label]
                  cf, default, value_remap = LABELS_MAPPING[label]
                  prop_key = cf.id
                end
                if value_remap && value_remap[value.downcase]
                  value = value_remap[value.downcase]
                elsif default
                  value = default
                end
                if prev
                  if value_remap && value_remap[prev.downcase]
                    prev = value_remap[prev.downcase]
                  elsif default
                    prev = default
                  end
                end
                if SPECIAL_LABELS[label]
                  default = default && default.id
                  value = value.id
                  prev = prev && prev.id
                end
                if type == :add
                  old_value, value = default, value
                elsif type == :mod
                  old_value, value = prev, value
                else
                  old_value, value = value, default
                end
                n.details << JournalDetail.new(
                  :property => property,
                  :prop_key => prop_key,
                  :old_value => old_value,
                  :value => value)
              end
            end
            n.save!
          end

          # Custom fields
          custom_values = {}
          if issue['labels']
            issue['labels'].each do |lbl|
              lbl, value = cut_label(lbl)
              lbl.downcase!
              next unless LABELS_MAPPING[lbl]
              custom_field, default, value_remap = LABELS_MAPPING[lbl]
              if value_remap && value_remap[value.downcase]
                value = value_remap[value.downcase]
              elsif default
                value = default
              end
              custom_values[custom_field.id] = value
            end
            i.custom_field_values = custom_values
            i.save_custom_field_values
          end
        end
        puts

        print 'Migrating issue relations '
        @takeout_project['issues']['items'].each do |issue|
          if issue['status'].downcase == 'duplicate'
            print 'D'
            last_mergedinto = nil
            issue['comments']['items'].each do |comment|
              next unless comment['updates']['mergedInto']
              last_mergedinto = comment['updates']['mergedInto'].to_i
            end
            r = IssueRelation.new :relation_type => IssueRelation::TYPE_DUPLICATES
            r.issue_from = Issue.find_by_id(issue['id'])
            r.issue_to = Issue.find_by_id(last_mergedinto)
            next unless r.issue_to
            r.save!
          end
          if issue['blocking']
            issue['blocking'].each do |b|
              print 'B'
              r = IssueRelation.new :relation_type => IssueRelation::TYPE_BLOCKS
              r.issue_from = Issue.find_by_id(issue['id'])
              r.issue_to = Issue.find_by_id(b['issueId'])
              next unless r.issue_to
              r.save!
            end
          end
        end
        puts
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
