#!/usr/bin/env bash
#===============================================================================
# Copyright (c) 2024 T2Mobile Technologies Corporation and its affiliates.
# All rights reserved.
#===============================================================================

# Initial Configuration
declare -A BUILD_LOGFILE_MAPPING
declare -A BUILD_STATUS_MAPPING
GPT_MAIN_FILES=(
    "rawprogram0.xml"
    "patch0.xml"
    "gpt_main0.bin"
    "gpt_backup0.bin"
)
MAX_ALLOWED_JOBS=$(($(nproc) * 3 / 8))
VALID_PRODUCT_LIST=("volcano" "fps")
VALID_VARIANT_LIST=("user" "userdebug")
VALID_SUBSYSTEM_LIST=("amss" "qssi" "target" "merge" "copy" "all")
BACKUP_BINARIES=(
    "ANDROID_QSSI_OUT:system/etc/selinux/plat_mac_permissions.xml"
    "AMSS_ROOT:Milos.LA.2.0/common/build/amss_7635_backup_files.zip"
    "AMSS_ROOT:about.html"
    "ANDROID_KERNEL_OUT:vmlinux"
    "ANDROID_KERNEL_OUT:System.map"
    "ANDROID_KERNEL_OUT:.config"
    "ANDROID_PRODUCT_OUT:ramdisk.img"
    "ANDROID_PRODUCT_OUT:vendor_ramdisk-debug.img"
    "ANDROID_PRODUCT_OUT:vendor_boot-debug.img"
    "ANDROID_PRODUCT_OUT:dlkm/lib/modules/"
)


usage() {
    echo
    cat <<USAGE
Usage: build.sh <options> [build subsystem]
  Example: bash build.sh -p fps -v userdebug all

optional arguments:
  -p, --product <product>      product to build. Supported product - volcano, fp6
  -v, --variant <variant>      variant to build. Supported variant - user, userdebug
  -m, --mmitest                mmitest release
  -j, --job <number>           number of jobs to run in parallel
  -h, --help                   print this help and exits

build subsystem arguments:
  amss        build amss subsystems
  qssi        build qssi part
  target      build vendor part
  merge       generate super image
  copy        copy all flash images to Images folder
  all         build all (qssi + vendor + amss)
USAGE
    exit
}

function print_info() {
    echo "==============================================================================="
    echo -e "\033[32mINFO: ${1}\033[0m"
    echo "==============================================================================="
}

function print_error() {
    echo "==============================================================================="
    echo -e "\033[31mERROR: ${1}\033[0m"
    echo "==============================================================================="
}

function command() {
    local cmd="$*"
    echo "==============================================================================="
    echo -e "\033[0;33mCOMMAND: ${cmd}\033[0m"
    echo "==============================================================================="
    time eval "${cmd}"
}

function check_tools() {
    if ! (type xmlstarlet >/dev/null 2>&1); then
        echo -n "xmlstarlet not installed, install xmlstarlet now? (yes/no) "
        read -r ANSWER
        case ${ANSWER} in
        yes | y)
            echo "start install xmlstarlet with command \"apt install xmlstarlet\""
            sudo apt install xmlstarlet
            ;;
        *)
            echo
            echo "you need install xmlstarlet and then run this script"
            exit
            ;;
        esac
    fi
}

function trap_error() {
    local error_code=$?
    local line_number="$1"
    local func_stack="$2"
    local line_callfunc="$3"

    echo "Current working dir: ${PWD}"
    echo "ERROR: line ${line_number} - command exited with status: ${error_code}"
    if [ -n "${func_stack}" ]; then
        echo -n "Error at executed function ${func_stack}() "
        if [ -n "${line_callfunc}" ]; then
            echo -n "called at line ${line_callfunc}"
        fi
        echo
    fi
}

function check_build_options() {
    [ -z "${BUILD_PRODUCT}" ] && print_error "product is not set, please add \"-p\" option and try again" && usage
    [ -z "${BUILD_VARIANT}" ] && print_error "variant is not set, please add \"-v\" option and try again" && usage
    [ -z "${BUILD_SUBSYSTEM}" ] && print_error "build subsystem is not set, please add \"all\" build target and try again" && usage

    if ! (grep -qw "${BUILD_PRODUCT}" <<<"${VALID_PRODUCT_LIST[*]}"); then
        print_error "Invalid product input, product should be in (${VALID_PRODUCT_LIST[*]})!"
        usage
    fi
    if ! (grep -qw "${BUILD_VARIANT}" <<<"${VALID_VARIANT_LIST[*]}"); then
        print_error "Invalid variant input, variant should be in (${VALID_VARIANT_LIST[*]})!"
        usage
    fi
    if ! (grep -qw "${BUILD_SUBSYSTEM}" <<<"${VALID_SUBSYSTEM_LIST[*]}"); then
        print_error "Invalid subsystem input, build subsystem should be in (${VALID_SUBSYSTEM_LIST[*]})!"
        usage
    fi
}

function get_subsystem_list() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    case ${BUILD_SUBSYSTEM} in
    amss)
        BUILD_STATUS_MAPPING["amss"]="Success"
        ;;
    qssi)
        BUILD_STATUS_MAPPING["qssi"]="Success"
        ;;
    target)
        BUILD_STATUS_MAPPING["kernel"]="Success"
        BUILD_STATUS_MAPPING["target"]="Success"
        ;;
    merge)
        BUILD_STATUS_MAPPING["merge"]="Success"
        ;;
    copy)
        BUILD_STATUS_MAPPING["copy"]="Success"
        ;;
    all)
        BUILD_STATUS_MAPPING["amss"]="Success"
        BUILD_STATUS_MAPPING["qssi"]="Success"
        BUILD_STATUS_MAPPING["target"]="Success"
        BUILD_STATUS_MAPPING["kernel"]="Success"
        BUILD_STATUS_MAPPING["merge"]="Success"
        BUILD_STATUS_MAPPING["copy"]="Success"
        ;;
    *)
        echo "Invalid option \"${BUILD_SUBSYSTEM}\" "
        echo -n "- the valid options are \"amss\", \"qssi\", \"target\", \"merge\", \"copy\" and \"all\""
        usage
        ;;
    esac
    trap - ERR
}

function parse_options() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    TARGET_BUILD_MMITEST="${TARGET_BUILD_MMITEST:-"false"}"
    BUILD_THREADS="${BUILD_THREADS:-${MAX_ALLOWED_JOBS}}"
    while true; do
        case ${1} in
        -p | --product)
            BUILD_PRODUCT="${2}"
            shift 2
            ;;
        -v | --variant)
            BUILD_VARIANT="${2}"
            shift 2
            ;;
        -m | --mmitest)
            TARGET_BUILD_MMITEST="true"
            shift
            ;;
        -j | --jobs)
            BUILD_THREADS="${2}"
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option \"${1}\""
            usage
            ;;
        esac
    done
    if [ "$#" -lt 1 ]; then
        echo "Invalid option: Missing target argument"
        usage
    fi
    BUILD_SUBSYSTEM="${1}"
    check_build_options
    get_subsystem_list
    trap - ERR
}

function set_build_dir() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    local ANSWER
    local index
    index=1
    while true; do
        echo -n "Please input ${1} build path: "
        read -r ANSWER
        if [ -d "${ANSWER}" ]; then
            break
        else
            echo "Invalid path, please input again"
            [ "${index}" -gt 3 ] && break
            index=$((index + 1))
        fi
    done
    eval "${1^^}_ROOT=$(realpath "${ANSWER}")"
    trap - ERR
}

function variables_setup() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR

    check_tools

    [ -z "$QSSI_ROOT" ] && set_build_dir "qssi"
    [ -z "${TARGET_ROOT}" ] && set_build_dir "target"
    AMSS_ROOT="${TARGET_ROOT}/amss_sm7635"

    if [ "${TARGET_BUILD_MMITEST}" == "true" ]; then
        BUILD_OPERATOR="mini"
    else
        BUILD_OPERATOR="global"
    fi
    if [ "${BUILD_VARIANT}" == "user" ]; then
        KERNEL_BUILD_VARIANT="gki"
    else
        KERNEL_BUILD_VARIANT="consolidate"
    fi
    AMSS_PRODUCT_OUT="${AMSS_ROOT}/Milos.LA.2.0/common/build/ufs"
    ANDROID_QSSI_OUT="${QSSI_ROOT}/out/target/product/qssi_64"
    if [ "$BUILD_PRODUCT" == "volcano" ]; then
        ANDROID_KERNEL_OUT="${TARGET_ROOT}/device/qcom/${BUILD_PRODUCT}-kernel"
    else
        ANDROID_KERNEL_OUT="${TARGET_ROOT}/device/fairphone/${BUILD_PRODUCT}-kernel"
    fi
    ANDROID_PRODUCT_OUT="${TARGET_ROOT}/out/target/product/${BUILD_PRODUCT}"
    if [ "$TARGET_BUILD_MMITEST" == "false" ]; then
        PARTITION_TABLE="${AMSS_ROOT}/vendor/fairphone/${BUILD_PRODUCT}/config/partition_ext.xml"
    else
        PARTITION_TABLE="${AMSS_ROOT}/vendor/fairphone/${BUILD_PRODUCT}/config/partition_ext_mini.xml"
    fi
    if [ "${MAX_ALLOWED_JOBS}" -lt "${BUILD_THREADS}" ]; then
        BUILD_THREADS="${MAX_ALLOWED_JOBS}"
    fi
    BUILD_LOGFILE_MAPPING["amss"]="${AMSS_ROOT}/log.amss"
    BUILD_LOGFILE_MAPPING["qssi"]="${QSSI_ROOT}/log.qssi"
    BUILD_LOGFILE_MAPPING["target"]="${TARGET_ROOT}/log.vendor"
    BUILD_LOGFILE_MAPPING["kernel"]="${TARGET_ROOT}/log.kernel"
    BUILD_LOGFILE_MAPPING["merge"]="${TARGET_ROOT}/log.merge"
    trap - ERR
}

function check_build_failed() {
    local return_val=$?
    [ "${return_val}" -eq 0 ] && return
    BUILD_STATUS_MAPPING["${1}"]="Failed"
}

function build_amss() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    print_info "build amss binaries"
    pushd "${AMSS_ROOT}" >/dev/null || exit 1
    trap 'check_build_failed amss' EXIT QUIT TERM INT
    command "bash linux_build.sh -A ${BUILD_PRODUCT} ${BUILD_OPERATOR} 2>&1 | tee ${BUILD_LOGFILE_MAPPING[amss]}"
    trap - EXIT QUIT TERM INT
    popd >/dev/null || exit 1
    trap - ERR
}

function build_android() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    pushd "$WORKDIR" >/dev/null || exit 1
    print_info "build android binaries for ${TARGET_PRODUCT}"
    source build/envsetup.sh
    export TARGET_BUILD_MMITEST
    lunch "${TARGET_PRODUCT}-${BUILD_VARIANT}"
    if [ -f "kernel_platform/build/android/prepare_vendor.sh" ]; then
        print_info "build ${TARGET_PRODUCT} ${KERNEL_BUILD_VARIANT} kernel first"
        trap 'check_build_failed kernel' EXIT QUIT TERM INT
        command "RECOMPILE_KERNEL=1 bash kernel_platform/build/android/prepare_vendor.sh ${TARGET_PRODUCT} ${KERNEL_BUILD_VARIANT} 2>&1 | tee ${BUILD_LOGFILE_MAPPING["kernel"]}"
        trap - EXIT QUIT TERM INT
    fi
    trap 'check_build_failed ${BUILD_OPTION}' EXIT QUIT TERM INT
    command "bash build.sh dist --${BUILD_OPTION}_only -j${BUILD_THREADS} 2>&1 | tee ${BUILD_LOGFILE_MAPPING["${BUILD_OPTION}"]}"
    trap - EXIT QUIT TERM INT
    popd >/dev/null || exit 1
    trap - ERR
}

function build_super() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    print_info "merge qssi and vendor, generate super image"
    pushd "$QSSI_ROOT" >/dev/null || exit 1
    trap 'check_build_failed merge' EXIT QUIT TERM INT
    command "python vendor/qcom/opensource/core-utils/build/build_image_standalone.py \
        --image super \
        --qssi_build_path ${QSSI_ROOT} \
        --target_build_path ${TARGET_ROOT} \
        --merged_build_path ${TARGET_ROOT} \
        --target_lunch ${BUILD_PRODUCT} --output_ota 2>&1 | tee ${BUILD_LOGFILE_MAPPING["merge"]}"
    trap - EXIT QUIT TERM INT
    popd >/dev/null || exit 1
    trap - ERR
}

function get_all_gpt_files() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    local total
    local index
    local gptfile
    total=$(xmlstarlet sel -t -m "//physical_partition" -n -v @text "${PARTITION_TABLE}" | wc -l)
    for gptfile in "${GPT_MAIN_FILES[@]}"; do
        for ((index = 1; index < "${total}"; index++)); do
            GPT_MAIN_FILES=("${GPT_MAIN_FILES[@]}" "${gptfile/0/$index}")
        done
    done
    trap - ERR
}

function collect_images() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    local package_image_list
    local image
    package_image_list=($(xmlstarlet sel -t -m "//partition" -n -v @filename "${PARTITION_TABLE}" | sort | uniq))
    get_all_gpt_files
    if [ -d "Images" ]; then
        rm -r "Images"
    fi
    mkdir "Images"
    pushd "Images" >/dev/null || exit
    for image in "${package_image_list[@]}" "${GPT_MAIN_FILES[@]}"; do
        if [ -f "${AMSS_PRODUCT_OUT}/${image}" ]; then
            command "ln -sf ${AMSS_PRODUCT_OUT}/${image} ${image}"
        elif [ -f "${ANDROID_PRODUCT_OUT}/${image}" ]; then
            command "ln -sf ${ANDROID_PRODUCT_OUT}/${image} ${image}"
        else
            if (grep -w -q "${image}" <<<"study.tar swversion.mbn" ); then
                print_info "${image} not found, ignore"
                continue
            fi
            print_error "${image} generate failed"
            BUILD_STATUS_MAPPING["copy"]="Failed"
        fi
    done
    if [ "${#BACKUP_BINARIES}" -ge 1 ]; then
        mkdir "backup"
        for backup_binary in "${BACKUP_BINARIES[@]}"; do
            backup_path=$(cut -d ':' -f1 <<<"$backup_binary")
            backup_file=$(cut -d ':' -f2 <<<"$backup_binary")
            if [ "$backup_path" != "$backup_file" ]; then
                backup_file=$(eval echo "\$$backup_path/$backup_file")
            fi
            command "ln -sf ${backup_file} backup/$(basename "${backup_file}")"
        done
    fi
    popd >/dev/null || exit
    trap - ERR
}

function print_build_status() {
    local subsystem
    local extra_info
    print_info "Build status:"
    for subsystem in "${!BUILD_STATUS_MAPPING[@]}"; do
        if [ "${BUILD_STATUS_MAPPING["$subsystem"]}" != "Success" ]; then
            extra_info="; check log file: ${BUILD_LOGFILE_MAPPING["$subsystem"]}"
        fi
        echo "build $subsystem : ${BUILD_STATUS_MAPPING["$subsystem"]}${extra_info}"
    done
}

function build_product() {
    trap 'trap_error ${LINENO} ${FUNCNAME[0]} ${BASH_LINENO[0]}' ERR
    local qssi_pid
    local target_pid
    if (grep "qssi" <<<"${!BUILD_STATUS_MAPPING[@]}"); then
        if [ "$BUILD_SUBSYSTEM" == "qssi" ]; then
            WORKDIR=${QSSI_ROOT} TARGET_PRODUCT="qssi_64" BUILD_OPTION="qssi" build_android
        else
            WORKDIR=${QSSI_ROOT} TARGET_PRODUCT="qssi_64" BUILD_OPTION="qssi" build_android &
            qssi_pid=$!
        fi
    fi
    if (grep "target" <<<"${!BUILD_STATUS_MAPPING[@]}"); then
        if [ "$BUILD_SUBSYSTEM" == "target" ]; then
            WORKDIR=${TARGET_ROOT} TARGET_PRODUCT=${BUILD_PRODUCT} BUILD_OPTION="target" build_android
        else
            WORKDIR=${TARGET_ROOT} TARGET_PRODUCT=${BUILD_PRODUCT} BUILD_OPTION="target" build_android &
            target_pid=$!
        fi
    fi
    (grep "amss" <<<"${!BUILD_STATUS_MAPPING[@]}") && build_amss
    if [ -n "${qssi_pid}" ] || [ -n "${target_pid}" ]; then
        wait ${qssi_pid} ${target_pid}
    fi
    (grep "merge" <<<"${!BUILD_STATUS_MAPPING[@]}") && build_super
    (grep "copy" <<<"${!BUILD_STATUS_MAPPING[@]}") && collect_images
    trap - ERR
}

if ! options=$(getopt --option p:v:j:mh --long product:,variant:,mmitest,job:,help -n "$0" -- "$@"); then
    usage
fi
eval set -- "$options"
parse_options "$@"

variables_setup

build_product

print_build_status
