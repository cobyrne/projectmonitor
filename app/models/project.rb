require 'acts-as-taggable-on'

class Project < ActiveRecord::Base

  RECENT_STATUS_COUNT = 8
  DEFAULT_POLLING_INTERVAL = 30
  MAX_STATUS = 15

  has_many :statuses,
    class_name: 'ProjectStatus',
    dependent: :destroy,
    before_add: :update_refreshed_at

  has_many :payload_log_entries
  belongs_to :aggregate_project
  belongs_to :creator, class_name: "User"

  serialize :last_ten_velocities, Array
  serialize :iteration_story_state_counts, JSON
  serialize :tracker_validation_status, Hash

  scope :enabled, -> { where(enabled: true) }
  scope :standalone, -> { where(aggregate_project_id: nil) }
  scope :with_statuses, -> { joins(:statuses).uniq }

  scope :updateable, -> {
    enabled.where(webhooks_enabled: [nil, false])
  }

  scope :tracker_updateable, -> {
    enabled
    .where('tracker_auth_token is NOT NULL').where('tracker_auth_token != ?', '')
    .where('tracker_project_id is NOT NULL').where('tracker_project_id != ?', '')
  }

  scope :displayable, lambda { |tags|
    scope = enabled.order('code ASC')
    return scope.tagged_with(tags, :any => true) if tags
    scope
  }

  scope :tagged, lambda { |tags|
    return Project.tagged_with(tags, :any => true) if tags
    all
  }

  acts_as_taggable

  validates :name, presence: true
  validates :type, presence: true

  before_create :generate_guid
  before_create :populate_iteration_story_state_counts

  def populate_iteration_story_state_counts
    self.iteration_story_state_counts = []
  end

  attr_writer :feed_url

  def self.project_specific_attributes
    columns.map(&:name).grep(/#{project_attribute_prefix}_/)
  end

  def self.with_aggregate_project(aggregate_project_id, &block)
    where(aggregate_project_id: aggregate_project_id).scoping(&block)
  end

  def code
    super.presence || name.downcase.gsub(" ", '')[0..3]
  end

  def latest_status
    statuses.latest
  end

  def recent_statuses(count = RECENT_STATUS_COUNT)
    ProjectStatus.recent(self, count)
  end

  def status
    latest_status || ProjectStatus.new(project: self)
  end

  def requires_branch_name?
    false
  end

  def green?
    online? && status.success?
  end

  def yellow?
    online? && !red? && !green?
  end

  def red?
    online? && latest_status.try(:success?) == false
  end

  def status_in_words
    if red?
      'failure'
    elsif green?
      'success'
    elsif yellow?
      'indeterminate'
    else
      'offline'
    end
  end

  def color
    return "white" unless online?
    return "green" if green?
    return "red" if red?
    return "yellow" if yellow?
  end

  def tracker_configured?
    tracker_project_id.present? && tracker_auth_token.present?
  end

  def red_since
    breaking_build.try(:published_at)
  end

  def red_build_count
    return 0 if breaking_build.nil? || !online?
    statuses.where(success: false).where("id >= ?", breaking_build.id).count
  end

  def feed_url
    raise NotImplementedError, "Must implement feed_url in subclasses"
  end

  def build_status_url
    raise NotImplementedError, "Must implement build_status_url in subclasses"
  end

  def tracker_project_url
    "https://www.pivotaltracker.com/services/v3/projects/#{tracker_project_id}"
  end

  def tracker_iterations_url
    "https://www.pivotaltracker.com/services/v3/projects/#{tracker_project_id}/iterations/done?offset=-10"
  end

  def tracker_current_iteration_url
    "https://www.pivotaltracker.com/services/v3/projects/#{tracker_project_id}/iterations/current"
  end

  def to_s
    name
  end

  def building?
    super
  end

  def current_build_url
  end

  def last_green
    @last_green ||= recent_statuses.green.first
  end

  def breaking_build
    @breaking_build ||= if last_green.nil?
                          recent_statuses.red.last
                        else
                          recent_statuses.red.where(["build_id > ?", last_green.build_id]).first
                        end
  end

  def has_auth?
    auth_username.present? || auth_password.present?
  end

  def tracker_project?
    tracker_project_id.present? &&  tracker_auth_token.present?
  end

  def payload
    raise NotImplementedError, "Must implement payload in subclasses"
  end

  def has_status?(status)
    statuses.where(build_id: status.build_id).any?
  end

  def has_dependencies?
    false
  end

  def generate_guid
    self.guid = SecureRandom.uuid
  end

  def volatility
    @volatility ||= Volatility.calculate(last_ten_velocities)
  end

  def published_at
    latest_status.try(:published_at)
  end

  def accept_mime_types
    nil
  end

  # Returns a string identifying the path associated with the object.
  # ActionPack uses this to find a suitable partial to represent the object.
  # To know more about this method, see:
  #   http://api.rubyonrails.org/classes/ActiveModel/Conversion.html#method-i-to_partial_path
  def to_partial_path
    "projects/project"
  end

  private

  def self.project_attribute_prefix
    name.match(/(.*)Project/)[1].underscore
  end

  def update_refreshed_at(status)
    self.last_refreshed_at = Time.now if online?
  end

  def fetch_statuses
    Delayed::Job.enqueue(StatusFetcher::Job.new(self), priority: 0)
  end

  def simple_statuses
    statuses.map(&:success)
  end

  def url_with_scheme url
    if url =~ %r{\Ahttps?://}
      url
    else
      "http://#{url}"
    end
  end
end
