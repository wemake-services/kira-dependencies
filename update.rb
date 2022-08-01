# This script is designed to loop through all dependencies in a GHE or GitLab
# project, creating PRs where necessary.
#
# It is intended to be used as a stop-gap until Dependabot's hosted instance
# supports GitHub Enterprise and GitLab (coming soon!)

require "json"
require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/pull_request_updater"
require "dependabot/omnibus"
require "gitlab"

gitlab_hostname = ENV["GITLAB_HOSTNAME"] || "gitlab.com"
credentials = [
  {
    "type" => "git_source",
    "host" => "github.com",
    "username" => "x-access-token",
    "password" => ENV["KIRA_GITHUB_PERSONAL_TOKEN"] || nil
  }
]

credentials << {
  "type" => "git_source",
  "host" => gitlab_hostname,
  "username" => "x-access-token",
  # A GitLab access token with API permission
  "password" => ENV["KIRA_GITLAB_PERSONAL_TOKEN"]
}

json_credentials = ENV['DEPENDABOT_EXTRA_CREDENTIALS'] || ""
unless json_credentials.to_s.strip.empty?
  json_credentials = JSON.parse(json_credentials)
  credentials.push(*json_credentials)
end

# expected format is {"vendor/package": [">0.1.0", ">0.2.0"]}
ignored_versions_json = ENV["DEPENDABOT_IGNORED_VERSIONS"] || ""
ignored_versions = {}
unless ignored_versions_json.to_s.strip.empty?
  ignored_versions = JSON.parse(ignored_versions_json)
end

# Full name of the repo you want to create pull requests for.
repo_name = ENV["DEPENDABOT_PROJECT_PATH"] # namespace/project

# Directory where the base dependency files are.
directory = ENV["DEPENDABOT_DIRECTORY"] || "/"

# See lists of update strategies here:
# https://github.com/wemake-services/kira-dependencies/issues/39
update_strategy = ENV['DEPENDABOT_UPDATE_STRATEGY']&.to_sym || nil

# See description of requirements here:
# https://github.com/dependabot/dependabot-core/issues/600#issuecomment-407808103
excluded_requirements = ENV['DEPENDABOT_EXCLUDE_REQUIREMENTS_TO_UNLOCK']&.split(" ")&.map(&:to_sym) || []

# stop the job if an exception occurs
fail_on_exception = ENV['KIRA_FAIL_ON_EXCEPTION'] == "true"

# Assignee to be set for this merge request.
# Works best with marge-bot:
# https://github.com/smarkets/marge-bot
assignees = [ENV["DEPENDABOT_ASSIGNEE_GITLAB_ID"]].compact
assignees = nil if assignees.empty?

package_manager = ENV["PACKAGE_MANAGER"] || "bundler"

# Source branch for merge requests
source_branch = ENV["DEPENDABOT_SOURCE_BRANCH"] || nil

source = Dependabot::Source.new(
  provider: "gitlab",
  hostname: gitlab_hostname,
  api_endpoint: "https://#{gitlab_hostname}/api/v4",
  repo: repo_name,
  directory: directory,
  branch: source_branch,
)

##############################
# Fetch the dependency files #
##############################
puts "Fetching #{package_manager} dependency files for #{repo_name}"
fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).new(
  source: source,
  credentials: credentials,
)

files = fetcher.files
commit = fetcher.commit

##############################
# Parse the dependency files #
##############################
puts "Parsing dependencies information"
parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
  dependency_files: files,
  source: source,
  credentials: credentials
)

gitlab_client = Dependabot::Clients::GitlabWithRetries.for_source(
  source: source,
  credentials: credentials
)

data = {}

dependencies = parser.parse
opened_merge_requests = 0
dependencies.select(&:top_level?).each do |dep|

  begin

    #########################################
    # Get update details for the dependency #
    #########################################
    checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
      dependency: dep,
      dependency_files: files,
      credentials: credentials,
      requirements_update_strategy: update_strategy,
      ignored_versions: ignored_versions[dep.name] || []
    )

    next if checker.up_to_date?
    #####################################
    # Find out if a MR already exists   #
    #####################################
    opened_merge_requests_for_this_dep = []
    loop do
      opened_merge_requests_for_this_dep = gitlab_client.merge_requests(
        repo_name,
        state: "opened",
        search: "Bump \" #{dep.name}\"",
        in: "title",
        with_merge_status_recheck: true
      ).select { |mr| mr.title[/#{dep.name}(\s|,)/] }
      break unless opened_merge_requests_for_this_dep.map(&:merge_status).include?('checking')
    end

    data[checker.dependency.name] = {
        current_version: checker.dependency.version,
        next_version: checker.preferred_resolvable_version.to_s,
        mr_urls: opened_merge_requests_for_this_dep.map(&:web_url)
      }

    if ENV['DEPENDABOT_MAX_MERGE_REQUESTS'] && opened_merge_requests >= ENV['DEPENDABOT_MAX_MERGE_REQUESTS'].to_i
      puts 'Opened merge request limit reached!'
      break unless ENV['KIRA_DEPENDENCIES_DASHBOARD']
      next
    end

    requirements_to_unlock =
      if !checker.requirements_unlocked_or_can_be?
        if !excluded_requirements.include?(:none) && checker.can_update?(requirements_to_unlock: :none) then :none
        else :update_not_possible
        end
      elsif !excluded_requirements.include?(:own) && checker.can_update?(requirements_to_unlock: :own) then :own
      elsif !excluded_requirements.include?(:all) && checker.can_update?(requirements_to_unlock: :all) then :all
      else :update_not_possible
      end

    next if requirements_to_unlock == :update_not_possible

    updated_deps = checker.updated_dependencies(
      requirements_to_unlock: requirements_to_unlock
    )

    #####################################
    # Generate updated dependency files #
    #####################################
    print "\n  - Updating #{dep.name} (from #{dep.version})…"
    updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
      dependencies: updated_deps,
      dependency_files: files,
      credentials: credentials,
    )

    updated_files = updater.updated_dependency_files

    conflict_merge_request_commit_id = nil
    conflict_merge_request_id = nil
    opened_merge_requests_for_this_dep.each do |omr|
      title = omr.title
      if title.include?(dep.name) && title.include?(dep.version)
        if !title.include?(updated_deps[0].version)
          # close old version MR
          gitlab_client.update_merge_request(repo_name, omr.iid, { state_event: "close" })
          gitlab_client.delete_branch(repo_name, omr.source_branch)
          puts " closed merge request ##{omr.iid}"
          next
        end
        if omr.merge_status != "can_be_merged"
          # ignore merge request manually touched
          next if gitlab_client.merge_request_commits(repo_name, omr.iid).length > 1
          # keep merge request
          conflict_merge_request_commit_id = omr.sha
          conflict_merge_request_id = omr.iid
          break
        end
      end
    end

    merge_request_id = nil
    if conflict_merge_request_commit_id && conflict_merge_request_id
      ########################################
      # Update merge request with conflict   #
      ########################################
      pr_updater = Dependabot::PullRequestUpdater.new(
        source: source,
        base_commit: commit,
        old_commit: conflict_merge_request_commit_id,
        files: updated_files,
        credentials: credentials,
        pull_request_number: conflict_merge_request_id,
      )
      pr_updater.update
      merge_request_id = conflict_merge_request_id
      print " merge request ##{conflict_merge_request_id} updated"
    else
      ########################################
      # Create a pull request for the update #
      ########################################
      pr_creator = Dependabot::PullRequestCreator.new(
        source: source,
        base_commit: commit,
        dependencies: updated_deps,
        files: updated_files,
        credentials: credentials,
        label_language: true,
        assignees: assignees
      )
      pull_request = pr_creator.create
      if pull_request
        merge_request_id = pull_request.iid
        mr_urls = data[checker.dependency.name][:mr_urls] << pull_request.web_url
        data[checker.dependency.name][:mr_urls] = mr_urls.uniq
      end

      print " submitted"
    end

    opened_merge_requests += 1
    next unless merge_request_id

    # Auto approve Gitlab merge request with the same user.
    if ENV["DEPENDABOT_GITLAB_APPROVE_MERGE"]
      begin
        gitlab_client.approve_merge_request(source.repo, merge_request_id)
      rescue Exception => e
        print "\nError when trying to approve the merge request\n#{e.message}"
      else
        print " / approved"
      end
    end

    # Enable GitLab "merge when pipeline succeeds" feature.
    # Merge requests created and successfully tested will be merge automatically.
    if ENV["DEPENDABOT_GITLAB_AUTO_MERGE"]
      begin
        gitlab_client.accept_merge_request(
          source.repo,
          merge_request_id,
          merge_when_pipeline_succeeds: true,
          should_remove_source_branch: true
        )
      rescue Exception => e
        print "\nError when trying to merge the merge request\n#{e.message}"
      else
        print " / set to be accepted"
      end
    end
  rescue StandardError => e
    raise e if fail_on_exception
    puts "error updating #{dep.name} (continuing)"
    puts e.full_message
  end
end

if ENV["KIRA_DEPENDENCIES_DASHBOARD"]
  language_name = Dependabot::PullRequestCreator::Labeler.label_details_for_package_manager(package_manager)[:name]

  dashboard_labels = [
    Dependabot::PullRequestCreator::Labeler::DEFAULT_DEPENDENCIES_LABEL,
    language_name
  ]

  dashboard_title = "Dependency Dashboard #{language_name}"
  dashboard_content= <<-MARKDOWN
  #{data.count} of #{dependencies.select(&:top_level?).count} #{package_manager} dependencies are out of date.

  | name | current version | next version | merge request |
  | ---- | --------------- | ------------ | ------------- |
  #{data.map { |name, values| "| #{name} | #{values[:current_version]} | #{values[:next_version]} | #{values[:mr_urls].map {|url| "[MR](#{url})" }.join(', ')}" }.join("\n")}
  MARKDOWN

  dashboard_issue = gitlab_client.issues(
    repo_name,
    state: 'opened',
    search: dashboard_title,
    in: 'title',
    labels: dashboard_labels
  ).first

  if dashboard_issue
    gitlab_client.edit_issue(repo_name, dashboard_issue.iid, description: dashboard_content)
  else
    gitlab_client.create_issue(repo_name, dashboard_title, {
      description: dashboard_content,
      labels: dashboard_labels
    })
  end
end

puts 'Done'
