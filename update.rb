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

# Full name of the repo you want to create pull requests for.
repo_name = ENV["DEPENDABOT_PROJECT_PATH"] # namespace/project

# Directory where the base dependency files are.
directory = ENV["DEPENDABOT_DIRECTORY"] || "/"

# See lists of update strategies here:
# https://github.com/wemake-services/kira-dependencies/issues/39
update_strategy = ENV['DEPENDABOT_UPDATE_STRATEGY']&.to_sym || nil

# Assignee to be set for this merge request.
# Works best with marge-bot:
# https://github.com/smarkets/marge-bot
assignee = ENV["DEPENDABOT_ASSIGNEE_GITLAB_ID"]
package_manager = ENV["PACKAGE_MANAGER"] || "bundler"

# Source branch for merge requests
source_branch = ENV["DEPENDABOT_SOURCE_BRANCH"] || "master"

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

dependencies.select(&:top_level?).each do |dep|
  #########################################
  # Get update details for the dependency #
  #########################################
  checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
    dependency: dep,
    dependency_files: files,
    credentials: credentials,
    requirements_update_strategy: update_strategy
  )

  next if checker.up_to_date?

  requirements_to_unlock =
    if !checker.requirements_unlocked_or_can_be?
      if checker.can_update?(requirements_to_unlock: :none) then :none
      else :update_not_possible
      end
    elsif checker.can_update?(requirements_to_unlock: :own) then :own
    elsif checker.can_update?(requirements_to_unlock: :all) then :all
    else :update_not_possible
    end

  next if requirements_to_unlock == :update_not_possible

  updated_deps = checker.updated_dependencies(
    requirements_to_unlock: requirements_to_unlock
  )

  #####################################
  # Generate updated dependency files #
  #####################################
  print "  - Updating #{dep.name} (from #{dep.version})…"
  updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
    dependencies: updated_deps,
    dependency_files: files,
    credentials: credentials,
  )

  updated_files = updater.updated_dependency_files

  g = Gitlab.client(
    endpoint: source.api_endpoint,
    private_token: ENV["KIRA_GITLAB_PERSONAL_TOKEN"]
  )

  # Is there an open MR for this dependency version, then close it
  open_merge_requests = g.merge_requests(repo_name, state: "opened")
  open_merge_requests.each do |omr|
    title = omr.title
    if title.include?(dep.name) && title.include?(dep.version) && !title.include?(updated_deps.first.version)

      # close the merge request
      g.update_merge_request(repo_name, omr.iid, {state_event: "close"})
      puts "closed ##{omr.iid}"

      # delete the branch
      g.delete_branch(repo_name, omr.source_branch)
    end
  end

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
    assignees: [assignee].compact
  )
  pull_request = pr_creator.create
  puts " submitted"

  next unless pull_request

  # Auto approve Gitlab merge request with the same user.
  if ENV["DEPENDABOT_GITLAB_APPROVE_MERGE"]
    g.approve_merge_request(source.repo, pull_request.iid)
    puts " approved"
  end

  # Enable GitLab "merge when pipeline succeeds" feature.
  # Merge requests created and successfully tested will be merge automatically.
  if ENV["DEPENDABOT_GITLAB_AUTO_MERGE"]
    g.accept_merge_request(
      source.repo,
      pull_request.iid,
      merge_when_pipeline_succeeds: true,
      should_remove_source_branch: true
    )

    puts " set to be accepted"
  end
end

puts "Done"
