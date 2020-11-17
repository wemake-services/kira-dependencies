# Kira Dependencies Bot

[![wemake.services](https://img.shields.io/badge/%20-wemake.services-green.svg?label=%20&logo=data%3Aimage%2Fpng%3Bbase64%2CiVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAABGdBTUEAALGPC%2FxhBQAAAAFzUkdCAK7OHOkAAAAbUExURQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP%2F%2F%2F5TvxDIAAAAIdFJOUwAjRA8xXANAL%2Bv0SAAAADNJREFUGNNjYCAIOJjRBdBFWMkVQeGzcHAwksJnAPPZGOGAASzPzAEHEGVsLExQwE7YswCb7AFZSF3bbAAAAABJRU5ErkJggg%3D%3D)](https://wemake.services)
[![kira-family](https://img.shields.io/badge/kira-family-pink.svg)](https://github.com/wemake-services/kira)

Gitlab bot to continuously update your dependency versions.
Friendly fork of [`dependabot-script`](https://github.com/dependabot/dependabot-script).
The main difference is that the script's source is adjusted to work with [`RSDP`](https://wemake.services/meta/rsdp) process.

Part of the [`@kira`](https://github.com/wemake-services/kira) bots family.

## Installation

We recommend to copy this project to your Gitlab.
And then setup individual CI schedules
for each project that you want to enable.

## Configuration

### Global

This is a global configuration that you should setup inside your CI variables.

- `KIRA_GITLAB_PERSONAL_TOKEN` - personal access token for your bot user
- `GITLAB_HOSTNAME` - (optional) Gitlab domain name, defaults to `gitlab.com`
- `KIRA_GITHUB_PERSONAL_TOKEN` - Github personal access token to avoid hitting rate limit

### Per schedule

This configuration is best to be setup inside CI schedule's environment.

- `PACKAGE_MANAGER_SET` - magic variable, package managers to be updated, eg: `npm pip docker`
- `DEPENDABOT_PROJECT_PATH` - project to be updated, eg: `wemake-services/kira-dependencies`
- `DEPENDABOT_DIRECTORY` - directory to look for package file, defaults to `/`
- `DEPENDABOT_SOURCE_BRANCH` - (optional) Source branch for merge requests, defaults to project default branch
- `DEPENDABOT_ASSIGNEE_GITLAB_ID` - (optional) Gitlab user id to assign to merge requests
- `DEPENDABOT_GITLAB_APPROVE_MERGE` - (optional) setup to `true` if you want our bot to approve your merge requests
- `DEPENDABOT_GITLAB_AUTO_MERGE` - (optional) setup to `true` if you want to auto merge this request
- `DEPENDABOT_MAX_MERGE_REQUESTS` - (optional) setup the number of max openened merge requests you want.
- `DEPENDABOT_EXTRA_CREDENTIALS` - (optional) JSON of extra credential config, for example a private registry authentication (For example FontAwesome Pro: `[{"type":"npm_registry","token":"<redacted>","registry":"npm.fontawesome.com"}]`)

### Per package manager

- `DEPENDABOT_UPDATE_STRATEGY` - (optional) change how each package manager updates your dependency versions, see list of allowed values [here](https://github.com/wemake-services/kira-dependencies/issues/39)
- `DEPENDABOT_EXCLUDE_REQUIREMENTS_TO_UNLOCK` - (optional) exclude certain dependency updates requirements for each package manager, see list of allowed values [here](https://github.com/dependabot/dependabot-core/issues/600#issuecomment-407808103). Useful if you have lots of dependencies and the update script too slow
