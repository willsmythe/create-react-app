#!/bin/bash
# Copyright (c) 2015-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# ******************************************************************************
# This is an end-to-end kitchensink test intended to run on CI.
# You can also run it locally but it's slow.
# ******************************************************************************

# Start in tasks/ even if run from root directory
cd "$(dirname "$0")"

# CLI, app, and test module temporary locations
# http://unix.stackexchange.com/a/84980
temp_app_path=`mktemp -d 2>/dev/null || mktemp -d -t 'temp_app_path'`
temp_module_path=`mktemp -d 2>/dev/null || mktemp -d -t 'temp_module_path'`

# Load Verdaccio-related functions
source verdaccio.sh

function cleanup {
  echo 'Cleaning up.'
  unset BROWSERSLIST
  ps -ef | grep 'verdaccio' | grep -v grep | awk '{print $2}' | xargs kill -9
  ps -ef | grep 'react-scripts' | grep -v grep | awk '{print $2}' | xargs kill -9
  cd "$root_path"
  # TODO: fix "Device or resource busy" and remove ``|| $CI`
  rm -rf "$temp_app_path" "$temp_module_path" || $CI
  # Restore the original NPM and Yarn registry URLs
  restoreRegistryUrls
}

# Error messages are redirected to stderr
function handle_error {
  echo "$(basename $0): ERROR! An error was encountered executing line $1." 1>&2;
  cleanup
  echo 'Exiting with error.' 1>&2;
  exit 1
}

function handle_exit {
  cleanup
  echo 'Exiting without error.' 1>&2;
  exit
}

# Check for the existence of one or more files.
function exists {
  for f in $*; do
    test -e "$f"
  done
}

# Exit the script with a helpful error message when any error is encountered
trap 'set +x; handle_error $LINENO $BASH_COMMAND' ERR

# Cleanup before exit on any termination signal
trap 'set +x; handle_exit' SIGQUIT SIGTERM SIGINT SIGKILL SIGHUP

# Echo every command being executed
set -x

# Go to root
cd ..
root_path=$PWD

if hash npm 2>/dev/null
then
  npm i -g npm@latest
fi

# Bootstrap monorepo
yarn

# ******************************************************************************
# First, publish the monorepo.
# ******************************************************************************

# Start the local NPM registry
startVerdaccio "$root_path"/tasks/verdaccio.yaml

# Publish the monorepo
git clean -df
./tasks/publish.sh --yes --force-publish=* --skip-git --cd-version=prerelease --exact --npm-tag=latest

# ******************************************************************************
# Now that we have published them, create a clean app folder and install them.
# ******************************************************************************

# Install the app in a temporary location
cd $temp_app_path
npx create-react-app test-kitchensink --internal-testing-template="$root_path"/packages/react-scripts/fixtures/kitchensink

# Install the test module
cd "$temp_module_path"
yarn add test-integrity@^2.0.1

# ******************************************************************************
# Now that we used create-react-app to create an app depending on react-scripts,
# let's make sure all npm scripts are in the working state.
# ******************************************************************************

# Enter the app directory
cd "$temp_app_path/test-kitchensink"

# In kitchensink, we want to test all transforms
export BROWSERSLIST='ie 9'

# Link to test module
npm link "$temp_module_path/node_modules/test-integrity"

# ******************************************************************************
# Finally, let's check that everything still works after ejecting.
# ******************************************************************************

# Eject...
echo yes | npm run eject

# Link to test module
npm link "$temp_module_path/node_modules/test-integrity"

# Temporary workaround for https://github.com/facebook/create-react-app/issues/6099
yarn add @babel/plugin-transform-react-jsx

# Test the build
REACT_APP_SHELL_ENV_MESSAGE=fromtheshell \
  NODE_PATH=src \
  PUBLIC_URL=http://www.example.org/spa/ \
  yarn build

# Check for expected output
exists build/*.html
exists build/static/js/main.*.js

# Unit tests
REACT_APP_SHELL_ENV_MESSAGE=fromtheshell \
  CI=true \
  NODE_PATH=src \
  NODE_ENV=test \
  yarn test --no-cache --runInBand --testPathPattern=src

# Test "development" environment
tmp_server_log=`mktemp`
PORT=3002 \
  REACT_APP_SHELL_ENV_MESSAGE=fromtheshell \
  NODE_PATH=src \
  nohup yarn start &>$tmp_server_log &
grep -q 'You can now view' <(tail -f $tmp_server_log)
E2E_URL="http://localhost:3002" \
  REACT_APP_SHELL_ENV_MESSAGE=fromtheshell \
  CI=true NODE_PATH=src \
  NODE_ENV=development \
  BABEL_ENV=test \
  node_modules/.bin/jest --no-cache --runInBand --config='jest.integration.config.js'

# Test "production" environment
E2E_FILE=./build/index.html \
  CI=true \
  NODE_ENV=production \
  BABEL_ENV=test \
  NODE_PATH=src \
  PUBLIC_URL=http://www.example.org/spa/ \
  node_modules/.bin/jest --no-cache --runInBand --config='jest.integration.config.js'

# Cleanup
cleanup
