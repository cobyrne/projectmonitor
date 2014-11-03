class TeamCityProject < Project

  validates_presence_of :ci_build_name, :ci_base_url, unless: ->(project) { project.webhooks_enabled }
  validates :ci_build_name, format: {with: /\Abt\d+\Z/, message: 'must begin with bt'}, unless: ->(project) { project.webhooks_enabled }

  alias_attribute :build_status_url, :feed_url
  alias_attribute :project_name, :feed_url

  def self.project_specific_attributes
    ['ci_base_url', 'ci_build_name']
  end

  def feed_url
    url_with_scheme "#{ci_base_url}/guestAuth/cradiator.html?buildTypeId=#{ci_build_name}"
  end

  def fetch_payload
    LegacyTeamCityXmlPayload.new
  end

  def webhook_payload
    LegacyTeamCityXmlPayload.new
  end

end
