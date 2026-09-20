#!/usr/bin/env bats

setup() {
    export SCRIPT_UNDER_TEST="${BATS_TEST_DIRNAME}/../system_files/shared/usr/libexec/bluefin-countme"
    export WORKDIR="${BATS_TEST_DIRNAME}/.bluefin-countme-test-${BATS_TEST_NUMBER}-${$}"
    export MOCKDIR="${WORKDIR}/bin"
    export STATE_DIRECTORY="${WORKDIR}/state"
    export IMAGE_INFO_FILE="${WORKDIR}/image-info.json"
    export COUNTME_ENDPOINT="https://countme.example.invalid/metalink"
    export CURL_LOG="${WORKDIR}/curl.log"

    mkdir -p "${MOCKDIR}" "${STATE_DIRECTORY}"
}

teardown() {
    rm -rf "${WORKDIR}"
}

write_mock() {
    printf '%s\n' "$2" > "${MOCKDIR}/$1"
    chmod +x "${MOCKDIR}/$1"
}

# Records the request and succeeds, so tests can assert on the query. -G turns
# --data-urlencode pairs into the query string, so the pairs are logged too.
mock_curl_ok() {
    write_mock curl '#!/usr/bin/bash
prev=""
for arg in "$@"; do
    case "$prev" in
        --data-urlencode) printf "%s\n" "$arg" >> "${CURL_LOG}" ;;
    esac
    case "$arg" in
        https://*) printf "%s\n" "$arg" >> "${CURL_LOG}" ;;
    esac
    prev="$arg"
done
exit 0'
}

mock_curl_fail() {
    write_mock curl '#!/usr/bin/bash
exit 22'
}

mock_bootc() {
    write_mock bootc "#!/usr/bin/bash
printf '%s' '$1'"
}

# Succeeds, but prints a warning on stderr first — merged into stdout this is not
# valid JSON and the tag would be lost.
mock_bootc_noisy() {
    write_mock bootc "#!/usr/bin/bash
echo 'warning: /sysroot mounted read-only' >&2
printf '%s' '$1'"
}

mock_bootc_broken() {
    write_mock bootc '#!/usr/bin/bash
echo "error: sysroot lock held" >&2
exit 1'
}

bootc_json() {
    printf '{"status":{"booted":{"image":{"image":{"image":"%s"}}}}}' "$1"
}

write_image_info() {
    cat > "${IMAGE_INFO_FILE}" <<EOF
{
  "image-name": "$1",
  "image-tag": "$2",
  "image-flavor": "$3"
}
EOF
}

run_script() {
    run env PATH="${MOCKDIR}:${PATH}" \
        IMAGE_INFO_FILE="${IMAGE_INFO_FILE}" \
        STATE_DIRECTORY="${STATE_DIRECTORY}" \
        COUNTME_ENDPOINT="${COUNTME_ENDPOINT}" \
        CURL_LOG="${CURL_LOG}" \
        /usr/bin/bash "${SCRIPT_UNDER_TEST}"
}

reported_url() {
    cat "${CURL_LOG}"
}

@test "bluefin-countme: reports the booted tag, not the compose-time tag" {
    write_image_info bluefin latest gdx
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin-lts:stable)"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"repo=bluefin"* ]]
    [[ "$(reported_url)" == *"tag=stable"* ]]
    [[ "$(reported_url)" != *"tag=latest"* ]]
    [[ "$(reported_url)" == *"flavor=gdx"* ]]
    [[ "$(reported_url)" == *"countme=1"* ]]
}

@test "bluefin-countme: bootc warnings on stderr do not cost the tag" {
    write_image_info bluefin latest main
    mock_bootc_noisy "$(bootc_json ghcr.io/projectbluefin/bluefin-lts:stable)"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"tag=stable"* ]]
}

@test "bluefin-countme: a metacharacter in a value cannot inject query parameters" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json 'ghcr.io/projectbluefin/bluefin:beta&countme=9')"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    grep -Fxq 'tag=beta&countme=9' "${CURL_LOG}"
    [ "$(grep -Fxc 'countme=1' "${CURL_LOG}")" -eq 1 ]
    ! grep -Fxq 'countme=9' "${CURL_LOG}"
}

@test "bluefin-countme: a bootc failure is logged and no tag is reported" {
    write_image_info bluefin latest main
    mock_bootc_broken
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$output" == *"bootc status failed"* ]]
    [[ "$(reported_url)" == *"repo=bluefin"* ]]
    [[ "$(reported_url)" != *"tag="* ]]
}

@test "bluefin-countme: a port-carrying untagged ref yields no bogus tag" {
    rm -f "${IMAGE_INFO_FILE}"
    mock_bootc "$(bootc_json registry.example.com:5000/bluefin)"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"repo=bluefin"* ]]
    [[ "$(reported_url)" != *"tag="* ]]
}

@test "bluefin-countme: a digest-pinned ref reports the name without a tag" {
    rm -f "${IMAGE_INFO_FILE}"
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/dakota@sha256:0123456789abcdef)"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"repo=dakota"* ]]
    [[ "$(reported_url)" != *"tag="* ]]
}

@test "bluefin-countme: unexpanded values are never transmitted" {
    write_image_info '${IMAGE_NAME}' '${IMAGE_TAG}' '${IMAGE_FLAVOR}'
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"repo=bluefin"* ]]
    [[ "$(reported_url)" != *'$'* ]]
}

@test "bluefin-countme: reports nothing when no image name can be resolved" {
    rm -f "${IMAGE_INFO_FILE}"
    mock_bootc_broken
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$output" == *"not reporting"* ]]
    [ ! -s "${CURL_LOG}" ]
}

@test "bluefin-countme: missing image-info.json falls back to the booted ref" {
    rm -f "${IMAGE_INFO_FILE}"
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin-nvidia:stable)"
    mock_curl_ok

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"repo=bluefin-nvidia"* ]]
    [[ "$(reported_url)" == *"tag=stable"* ]]
}

@test "bluefin-countme: throttles to one ping per seven days" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok
    printf '%s\n' "$(( $(date +%s) - 86400 ))" > "${STATE_DIRECTORY}/lastrun"

    run_script

    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping"* ]]
    [ ! -s "${CURL_LOG}" ]
}

@test "bluefin-countme: a stale lastrun past the window reports again" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok
    printf '%s\n' "$(( $(date +%s) - 700000 ))" > "${STATE_DIRECTORY}/lastrun"

    run_script

    [ "$status" -eq 0 ]
    [ -s "${CURL_LOG}" ]
}

@test "bluefin-countme: a corrupt epoch cookie is reseeded, not read as 1970" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok
    printf 'garbage' > "${STATE_DIRECTORY}/epoch"

    run_script

    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"countme=1"* ]]
    [[ "$(cat "${STATE_DIRECTORY}/epoch")" =~ ^[0-9]+$ ]]
}

@test "bluefin-countme: the age bucket follows Fedora's week boundaries" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok

    printf '%s\n' "$(( $(date +%s) - 30 * 86400 ))" > "${STATE_DIRECTORY}/epoch"
    run_script
    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"countme=3"* ]]

    : > "${CURL_LOG}"
    rm -f "${STATE_DIRECTORY}/lastrun"
    printf '%s\n' "$(( $(date +%s) - 200 * 86400 ))" > "${STATE_DIRECTORY}/epoch"
    run_script
    [ "$status" -eq 0 ]
    [[ "$(reported_url)" == *"countme=4"* ]]
}

@test "bluefin-countme: a failed ping leaves lastrun untouched so it retries" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_fail

    run_script

    [ "$status" -eq 0 ]
    [[ "$output" == *"will retry"* ]]
    [ ! -f "${STATE_DIRECTORY}/lastrun" ]
}

@test "bluefin-countme: an opt-out marker stops the run before any state is written" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok
    rm -rf "${STATE_DIRECTORY}"
    mkdir -p "${WORKDIR}/root/etc/projectbluefin/countme"
    touch "${WORKDIR}/root/etc/projectbluefin/countme/disabled"

    run env PATH="${MOCKDIR}:${PATH}" \
        IMAGE_INFO_FILE="${IMAGE_INFO_FILE}" \
        STATE_DIRECTORY="${STATE_DIRECTORY}" \
        COUNTME_ENDPOINT="${COUNTME_ENDPOINT}" \
        COUNTME_CONFIG_ROOT="${WORKDIR}/root" \
        CURL_LOG="${CURL_LOG}" \
        /usr/bin/bash "${SCRIPT_UNDER_TEST}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"countme disabled"* ]]
    [ ! -d "${STATE_DIRECTORY}" ]
    [ ! -s "${CURL_LOG}" ]
}

@test "bluefin-countme: the legacy dakota opt-out marker is still honored" {
    write_image_info bluefin latest main
    mock_bootc "$(bootc_json ghcr.io/projectbluefin/bluefin:stable)"
    mock_curl_ok
    rm -rf "${STATE_DIRECTORY}"
    mkdir -p "${WORKDIR}/root/etc/dakota-countme"
    touch "${WORKDIR}/root/etc/dakota-countme/disabled"

    run env PATH="${MOCKDIR}:${PATH}" \
        IMAGE_INFO_FILE="${IMAGE_INFO_FILE}" \
        STATE_DIRECTORY="${STATE_DIRECTORY}" \
        COUNTME_ENDPOINT="${COUNTME_ENDPOINT}" \
        COUNTME_CONFIG_ROOT="${WORKDIR}/root" \
        CURL_LOG="${CURL_LOG}" \
        /usr/bin/bash "${SCRIPT_UNDER_TEST}"

    [ "$status" -eq 0 ]
    [[ "$output" == *"dakota-countme/disabled"* ]]
    [ ! -d "${STATE_DIRECTORY}" ]
    [ ! -s "${CURL_LOG}" ]
}
