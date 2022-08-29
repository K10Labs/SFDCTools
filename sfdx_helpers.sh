# Functions for working with salesforce
# Includes sfpowerkit for easy auth

function install_salesforce_cli() {
    export SFDX_AUTOUPDATE_DISABLE=false
    export SFDX_USE_GENERIC_UNIX_KEYCHAIN=true
    export SFDX_DOMAIN_RETRY=300
    export SFDX_PROJECT_AUTOUPDATE_DISABLE_FOR_PACKAGE_CREATE=true
    export SFDX_PROJECT_AUTOUPDATE_DISABLE_FOR_PACKAGE_VERSION_CREATE=true
    mkdir sfdx
    CLIURL=https://developer.salesforce.com/media/salesforce-cli/sfdx-linux-amd64.tar.xz
    wget -qO- $CLIURL | tar xJ -C sfdx --strip-components 1
    "./sfdx/install"
    export PATH=./sfdx/$(pwd):$PATH
    if [[ ! -e "$HOME/.config/sfdx/unsignedPluginAllowList.json" ]]; then
        mkdir -p $HOME/.config/sfdx
    fi
    echo '["sfpowerkit"]' > $HOME/.config/sfdx/unsignedPluginAllowList.json
    sfdx plugins:install sfpowerkit
    npm install -g typescript
    sfdx --version
    sfdx plugins --core
}

function install_jq() {
    apt update && apt -y install jq
}

function install_lwc_jest() {
    if [ ! -f "package.json" ]; then
        npm init -y
    fi
    local scriptValue=$(jq -r '.scripts["test:lwc"]' < package.json)
    if [[ -z "$scriptValue" || $scriptValue == null ]]; then
        local tmp=$(mktemp)
        jq '.scripts["test:lwc"]="lwc-jest"' package.json > $tmp
        mv $tmp package.json
        echo "added test:lwc script property to package.json" >&2
        cat package.json >&2
    fi
    npm install
    npm install @salesforce/lwc-jest --save-dev
}

function check_has_jest_tests() {
    local hasJestTests=false
    for pkgDir in $(jq -r '.packageDirectories[].path' < sfdx-project.json)
    do
        if [ -f $pkgDir ]; then
        local fileCnt=$(find $pkgDir -type f -path "**/__tests__/*.test.js" | wc -l);
        if [ $fileCnt -gt 0 ]; then
            hasJestTests=true
        fi
        fi
    done
    echo $hasJestTests
}

function test_lwc_jest() {
    local hasJestTests=$(check_has_jest_tests)
    if [ $hasJestTests ]; then
        npm run test:lwc
    else
        echo 'Skipping lwc tests, found no jest tests in any package directories' >&2
    fi
}

function test_scratch_org() {
    local org_username=$1
    if [ ! $org_username ]; then
        echo "ERROR No org username provided to 'test_scratch_org' function" >&2
        exit 1;
    fi
    if [ ! -f "package.json" ]; then
        npm init -y
    fi
    mkdir -p ./tests/apex
    local scriptValue=$(jq -r '.scripts["test:scratch"]' < package.json)
    if [[ -z "$scriptValue" || $scriptValue == null ]]; then
        local tmp=$(mktemp)
        jq '.scripts["test:scratch"]="sfdx force:apex:test:run --codecoverage --resultformat junit --wait 10 --outputdir ./tests/apex"' package.json > $tmp
        mv $tmp package.json
        echo "added test:scratch script property to package.json" >&2
        cat package.json >&2
    fi
    local old_org_username=$(jq -r '.result[].value' <<< $(sfdx force:config:get defaultusername --json))
    sfdx force:config:set defaultusername=$org_username
    npm run test:scratch
    sfdx force:config:set defaultusername=$old_org_username
}

function authenticate() {
    local alias_to_set=$1
    local sfdc_username=$2
    local sfdc_password=$3
    local sfdc_security_token=$4
    local sfdc_domain=$5
    local cmd=$(sfdx sfpowerkit:auth:login -u $sfdc_username -p $sfdc_password -s $sfdc_security_token -r "https://$sfdc_domain.salesforce.com" -a $alias_to_set --json)
    echo $cmd | jq '.'
    sfdx force:config:set defaultusername=$alias_to_set
    sfdx force:config:set defaultdevhubusername=$alias_to_set
}

function get_org_auth_url() {
    local org_username=$1
    echo "org_username=$org_username" >&2
    local cmd="sfdx force:org:display --verbose --targetusername $org_username --json" && (echo $cmd >&2)
    local output=$($cmd)
    org_auth_url="$(jq -r '.result.sfdxAuthUrl' <<< $output)"
    if [ ! $org_auth_url ]; then
        echo "ERROR No SFDX Auth URL available for org $org_username" >&2
        exit 1
    fi
    echo $org_auth_url
}

function assert_within_limits() {
    export local org_username=$1
    export local limit_name=$2
    echo "org_username=$org_username" >&2
    echo "limit_name=$limit_name" >&2
    local cmd="sfdx force:limits:api:display --targetusername $org_username --json" && (echo $cmd >&2)
    local limits=$($cmd) && (echo $limits | jq '.' >&2)
    local limit=$(jq -r '.result[] | select(.name == env.limit_name)' <<< $limits)
    if [ -n "$limit" ]; then
        local limit_max=$(jq -r '.max' <<< $limit)
        local limit_rem=$(jq -r '.remaining' <<< $limit)
        if [[ ( -z "$limit_rem" ) || ( $limit_rem == null ) || ( $limit_rem -le 0 ) ]]; then
        echo "ERROR Max of $limit_max reached for limit $limit_name" >&2
        exit 1
        else
        echo "$limit_rem of $limit_max remaining for limit $limit_name" >&2
        fi
    else
        echo "No limits found for name $limit_name" >&2
    fi
}

function get_package_id() {
    export local devhub_username=$1
    export local package_name=$2
    echo "devhub_username=$devhub_username" >&2
    echo "package_name=$package_name" >&2
    if [ ! $package_name ]; then
        echo "no package name argument provided, defaulting to environment variable PACKAGE_NAME" >&2
        package_name=$PACKAGE_NAME
    fi
    if [ ! $package_name ]; then
        echo "no PACKAGE_NAME environment variable set, defaulting to default package directory in sfdx-project.json" >&2
        cat sfdx-project.json >&2
        package_name=$(cat sfdx-project.json | jq -r '.packageDirectories[] | select(.default==true) | .package')
    fi
    if [ ! $package_name ]; then
        echo "no package name found, defaulting to first package directory listed in sfdx-project.json" >&2
        cat sfdx-project.json >&2
        package_name=$(cat sfdx-project.json | jq -r '.packageDirectories | .[0] | .package')
    fi
    if [ ! $package_name ]; then
        echo "ERROR Package name not specified. Set the PACKAGE_NAME environment variable or specify a default package directory in sfdx-project.json." >&2
        exit 1
    fi
    local cmd="sfdx force:package:list --targetdevhubusername $devhub_username --json" && (echo $cmd >&2)
    local output=$($cmd) && (echo $output | jq '.' >&2)
    package_id=$(jq -r '.result[] | select(.Name == env.package_name) | .Id' <<< $output)
    if [ ! $package_id ]; then
        echo "ERROR We could not find a package with name '$package_name' owned by this Dev Hub org." >&2
        exit 1
    fi
    echo "package_name=$package_name" >&2
    echo "package_id=$package_id" >&2
    echo $package_id
}

function add_package_alias() {
    export local devhub_username=$1
    export local package_id=$2
    local cmd="sfdx force:package:list --targetdevhubusername $devhub_username --json" && (echo $cmd >&2)
    local output=$($cmd) && (echo $output | jq '.' >&2)
    package_name=$(jq -r '.result[] | select(.Id == env.package_id) | .Name' <<< $output)
    if [[ -z "$package_name" || $package_name == null ]]; then
        echo "ERROR We could not find a package with id '$package_id' owned by this Dev Hub org." >&2
        exit 1
    fi
    cat sfdx-project.json >&2
    local packageAlias=$(jq -r '.packageAliases["'$package_name'"]' < sfdx-project.json)
    if [[ -z "$packageAlias" || $packageAlias == null ]]; then
        local tmp=$(mktemp)
        jq '.packageAliases["'$package_name'"]="'$package_id'"' sfdx-project.json > $tmp
        mv $tmp sfdx-project.json
        echo "added package alias property to sfdx-project.json" >&2
        cat sfdx-project.json >&2
    fi
}

function build_package_version() {
    export local devhub_username=$1
    export local package_id=$2
    echo "devhub_username=$devhub_username" >&2
    echo "package_id=$package_id" >&2
    local cmd="sfdx force:package:version:list --targetdevhubusername $devhub_username --packages $package_id --concise --released --json" && (echo $cmd >&2)
    local output=$($cmd) && (echo $output | jq '.' >&2)
    local last_package_version=$(jq '.result | sort_by(-.MajorVersion, -.MinorVersion, -.PatchVersion, -.BuildNumber) | .[0]' <<< $output)
    local is_released=$(jq -r '.IsReleased' <<< $last_package_version)
    local major_version=$(jq -r '.MajorVersion' <<< $last_package_version)
    local minor_version=$(jq -r '.MinorVersion' <<< $last_package_version)
    local patch_version=$(jq -r '.PatchVersion' <<< $last_package_version)
    local build_version="NEXT"
    if [ -z $major_version ]; then major_version=1; fi;
    if [ -z $minor_version ]; then minor_version=0; fi;
    if [ -z $patch_version ]; then patch_version=0; fi;
    if [ $is_released == true ]; then minor_version=$(($minor_version+1)); fi;
    local version_number=$major_version.$minor_version.$patch_version.$build_version
    echo "version_number=$version_number" >&2
    cmd="sfdx force:package:version:create --targetdevhubusername $devhub_username --package $package_id --versionnumber $version_number --installationkeybypass --wait 10 --json" && (echo $cmd >&2)
    output=$($cmd) && (echo $output | jq '.' >&2)
    local subscriber_package_version_id=$(jq -r '.result.SubscriberPackageVersionId' <<< $output)
    if [[ -z "$subscriber_package_version_id" || $subscriber_package_version_id == null ]]; then
        echo "ERROR No subscriber package version found for package id '$package_id'" >&2
        exit 1
    fi
    echo $subscriber_package_version_id
}

function install_package_version() {
    local org_username=$1
    local package_version_id=$2
    echo "org_username=$org_username" >&2
    echo "package_version_id=$package_version_id" >&2
    if [[ -z "$org_username" || $org_username == null ]]; then
        echo "ERROR No org username provided to 'install_package_version' function" >&2
        exit 1
    fi
    if [[ -z "$package_version_id" || $package_version_id == null ]]; then
        echo "ERROR No package version id provided to 'install_package_version' function" >&2
        exit 1
    fi
    local cmd="sfdx force:package:install --targetusername $org_username --package $package_version_id --wait 10 --publishwait 10 --noprompt --json" && (echo $cmd >&2)
    local output=$($cmd) && (echo $output | jq '.' >&2)
    local exit_code=$(jq -r '.exitCode' <<< $output) && (echo $exit_code >&2)
    if [[ ( -n "$exit_code" ) && ( $exit_code -gt 0 ) ]]; then
        exit 1
    fi
}

function promote_package_version() {
    local devhub_username=$1
    local package_version_id=$2
    echo "devhub_username=$devhub_username" >&2
    echo "package_version_id=$package_version_id" >&2
    local cmd="sfdx force:package:version:promote --targetdevhubusername $devhub_username --package $package_version_id --noprompt --json" && (echo $cmd >&2)
    local output=$($cmd) && (echo $output | jq '.' >&2)
}

function populate_scratch_org_redirect_html() {
    local org_username=$1
    if [ ! $org_username ]; then
        echo "ERROR No org username provided to 'populate_scratch_org_redirect_html' function" >&2
        exit 1;
    fi
    local cmd="sfdx force:org:open --targetusername $org_username --urlonly --json" && (echo $cmd >&2)
    local output=$($cmd) # don't echo/expose the output which contains the auth url
    local url=$(jq -r ".result.url" <<< $output)
    local environment_html="<script>window.onload=function(){window.location.href=\"$url\"}</script>"
    echo "$environment_html" > ENVIRONMENT.html
    echo "To browse the scratch org, click 'Browse' under 'Job artifacts' and select 'ENVIRONMENT.html'"
}

function deploy_scratch_org() {
    local devhub=$1
    local orgname=$2
    assert_within_limits $devhub DailyScratchOrgs
    local scratch_org_username=$(create_scratch_org $devhub $orgname)
    echo $scratch_org_username > SCRATCH_ORG_USERNAME.txt
    get_org_auth_url $scratch_org_username > SCRATCH_ORG_AUTH_URL.txt
    push_to_scratch_org $scratch_org_username
    populate_scratch_org_redirect_html $scratch_org_username
    echo "Deployed to scratch org $username for $orgname"
}

function create_scratch_org() {
    local devhub=$1
    export local orgname=$2
    local cmd="sfdx force:org:create --targetdevhubusername $devhub --wait 10 --durationdays 30 --definitionfile config/project-scratch-def.json orgName=$orgname --json" && (echo $cmd >&2)
    local output=$($cmd) && (echo $output | jq '.' >&2)
    scratch_org_username="$(jq -r '.result.username' <<< $output)"
    echo $scratch_org_username > SCRATCH_ORG_USERNAME.txt
    local cmd="sfdx force:org:display --verbose --targetusername $org_username --json" && (echo $cmd >&2)
    local output=$($cmd)
    org_auth_url="$(jq -r '.result.sfdxAuthUrl' <<< $output)"
    echo $org_auth_url > SCRATCH_ORG_AUTH_URL.txt
    echo $scratch_org_username
}

function get_scratch_org_usernames() {
    local devhub=$1
    local orgname=$2
    local result=$(sfdx force:data:soql:query --targetusername $devhub --query "SELECT SignupUsername FROM ScratchOrgInfo WHERE OrgName='$orgname'" --json)
    local usernames=$(jq -r ".result.records|map(.SignupUsername)|.[]" <<< $result)
    echo $usernames
}

function push_to_scratch_org() {
    local scratch_org_username=$1
    if [ ! $scratch_org_username ]; then
        echo "ERROR No scratch org username provided to 'push_to_scratch_org' function" >&2
        exit 1;
    fi
    if [ ! -f "package.json" ]; then
        npm init -y
    fi
    cat package.json >&2
    local scriptValue=$(jq -r '.scripts["scratch:deploy"]' < package.json)
    if [[ -z "$scriptValue" || $scriptValue == null ]]; then
        local tmp=$(mktemp)
        jq '.scripts["scratch:deploy"]="sfdx force:source:push"' package.json > $tmp
        mv $tmp package.json
        echo "added scratch:deploy script property to package.json" >&2
        cat package.json >&2
    fi
    local old_org_username=$(jq -r '.result[].value' <<< $(sfdx force:config:get defaultusername --json))
    sfdx force:config:set defaultusername=$scratch_org_username
    npm run scratch:deploy
    sfdx force:config:set defaultusername=$old_org_username
}

function delete_scratch_orgs() {
    local devhub_username=$1
    local scratch_org_name=$2
    local usernames=$(get_scratch_org_usernames $devhub_username $scratch_org_name)
    for scratch_org_username in $usernames; do
        echo "Deleting $scratch_org_username"
        local cmd="sfdx force:data:record:delete --sobjecttype ScratchOrgInfo --targetusername $devhub_username --where "'"SignupUsername='$scratch_org_username'"'" --json" && (echo $cmd >&2)
        local output=$($cmd) && (echo $output | jq '.' >&2)
    done
}

function deploy_metadata() {
    local org_username=$1
    local RUN_TESTS=$2
    if [[ -z "$org_username" || $org_username == null ]]; then
        echo "ERROR No org username provided to 'deploy_component' function" >&2
        exit 1
    fi
    source_folder=$(cat sfdx-project.json | jq -r '.packageDirectories[] | select(.default==true) | .path')
    if [ ! $source_folder ]; then
        echo "no default package directory found, defaulting to first package directory listed in sfdx-project.json" >&2
        cat sfdx-project.json >&2
    fi
    if [ ! $source_folder ]; then
        echo "no default package directory found, defaulting to first package directory listed in sfdx-project.json" >&2
        cat sfdx-project.json >&2
        source_folder=$(cat sfdx-project.json | jq -r '.packageDirectories | .[0] | .path')
    fi
    if [ ! $source_folder ]; then
        echo "ERROR Default package directory not specified. Specify a default package directory in sfdx-project.json." >&2
        exit 1
    fi
    if [[ -z "$RUN_TESTS" ]]; then
        RUN_TESTS="accountSearchControllerTest"
    fi
    sfdx force:source:deploy --targetusername $org_username -p $source_folder --testlevel RunSpecifiedTests --runtests $RUN_TESTS
}

