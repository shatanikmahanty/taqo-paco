#!/bin/bash
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Fail on any error.
set -e

# Code under repo is checked out to ${KOKORO_ARTIFACTS_DIR}/github.
# The final directory name in this path is determined by the scm name specified
# in the job configuration.

cd "${KOKORO_ARTIFACTS_DIR}/github/taqo-paco-kokoro/"

# Read dependencies file to resolve versions
source deps.cfg

#Install java with specified version in the deps.cfg file
printf "\nJava version read from deps.cfg file is: %s \n" "${java_version}"
sudo apt install -y openjdk-"${java_version}"-jdk
export JAVA_HOME="/usr/lib/jvm/java-${java_version}-openjdk-amd64"
export PATH="${JAVA_HOME}/bin:{$PATH}"

printf "\nFlutter version read from deps.cfg file is: %s \n" "${flutter_version}"
# Check if flutter is installed, if yes, remove old local flutter
if [[ -d flutter ]]; then
  rm -rf flutter
fi
# Install the flutter with the specified version if it is not already installed
git clone -b "${flutter_version}" --single-branch https://github.com/flutter/flutter.git
export PATH="$PWD/flutter/bin:$PATH"

printf "\n New java version is: "
java -version

printf "\n New Flutter version is: "
flutter --version

# Clean previous flutter builds
cd taqo_client
flutter clean
cd ..

#  Run the linux build
flutter config --enable-linux-desktop
distribution/create_deb_pkg.sh
result=$?
if [ $result -ne 0 ]; then
    printf "Build failed! Please check the log for the details."
  exit 1
fi

#exit 0