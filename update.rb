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
  credentials: credentials,
)

dependencies = parser.parse
opened_merge_requests = 0
dependencies.select(&:top_level?).each do |dep|
  if ENV["DEPENDABOT_MAX_MERGE_REQUESTS"] && opened_merge_requests >= ENV["DEPENDABOT_MAX_MERGE_REQUESTS"].to_i
    puts "Opened merge request limit reached!"
    break
  end

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

    #####################################
    # Find out if a MR already exists   #
    #####################################
    gitlab_client = Dependabot::Clients::GitlabWithRetries.for_source(
      source: source,
      credentials: credentials
    )

    opened_merge_requests_for_this_dep = []
    # Ensures that at most 20 requests are sent to gitlab before ignoring merge_status as MR is stuck in checking state
    # See https://gitlab.com/gitlab-org/gitlab/-/issues/263390
    counter = 0
    loop do
      opened_merge_requests_for_this_dep = gitlab_client.merge_requests(
        repo_name,
        state: "opened",
        search: "\"Bump #{dep.name} \"",
        in: "title",
        with_merge_status_recheck: counter == 0
      )
      
      if counter != 0
        # Sleep 500ms to prevent too much requests sent to server
        sleep 0.5
      end
      counter += 1
      shouldRetry = opened_merge_requests_for_this_dep.map(&:merge_status).include?('checking')
      if counter == 20
        print "\n  - Merge request for {dep.name} is stuck in checking state"
        shouldRetry = false
      end
      break unless shouldRetry
    end

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
      merge_request_id = pull_request.iid if pull_request
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

puts "Done"
