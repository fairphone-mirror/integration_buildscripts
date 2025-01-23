#!/usr/bin/env bash
#===============================================================================
# Copyright (c) 2024 T2Mobile Technologies Corporation and its affiliates.
# All rights reserved.
#===============================================================================

# Initial Configuration
SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
declare -a BUILD_SUBSYSTEM
declare -A LOGGING_MAPPING
declare -A SUBSYSTEM_STATES
SUBSYSTEM_STATES["qssi"]="Disabled"
SUBSYSTEM_STATES["kernel"]="Disabled"
SUBSYSTEM_STATES["vendor"]="Disabled"
SUBSYSTEM_STATES["amss"]="Disabled"
SUBSYSTEM_STATES["merge"]="Disabled"
SUBSYSTEM_STATES["copy"]="Disabled"
GPT_MAIN_FILES=(
    "rawprogram0.xml"
    "patch0.xml"
    "gpt_main0.bin"
    "gpt_backup0.bin"
)
MAX_ALLOWED_JOBS=$(($(nproc) * 3 / 8))
VALID_PRODUCT_LIST=("volcano" "fps")
VALID_VARIANT_LIST=("user" "userdebug")
VALID_SUBSYSTEM_LIST=("amss" "qssi" "target" "merge" "copy")
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


function check_build_options() {
    local subsystem
    [ -z "${BUILD_PRODUCT}" ] && print_error "product is not set, please add \"-p\" option and try again" && usage
    [ -z "${TARGET_BUILD_VARIANT}" ] && print_error "variant is not set, please add \"-v\" option and try again" && usage
    [ -z "${BUILD_SUBSYSTEM[*]}" ] && print_error "build subsystem is not set, please add \"all\" build target and try again" && usage

    if ! (grep -qw "${BUILD_PRODUCT}" <<<"${VALID_PRODUCT_LIST[*]}"); then
        print_error "Invalid product input, product should be in (${VALID_PRODUCT_LIST[*]})!"
        usage
    fi
    if ! (grep -qw "${TARGET_BUILD_VARIANT}" <<<"${VALID_VARIANT_LIST[*]}"); then
        print_error "Invalid variant input, variant should be in (${VALID_VARIANT_LIST[*]})!"
        usage
    fi
    for subsystem in "${BUILD_SUBSYSTEM[@]}"; do
        if [ "${subsystem}" == "all" ]; then
            continue
        fi
        if ! (grep -qw "${subsystem}" <<<"${VALID_SUBSYSTEM_LIST[*]}"); then
            print_error "Invalid subsystem input, build subsystem should be in (${VALID_SUBSYSTEM_LIST[*]})!"
            usage
        fi
    done
}

function set_build_list() {
    local subsystem
    for subsystem in "${BUILD_SUBSYSTEM[@]}"; do
        if [ "${subsystem}" == "target" ]; then
            SUBSYSTEM_STATES["kernel"]="Queued"
            SUBSYSTEM_STATES["vendor"]="Queued"
        else
            SUBSYSTEM_STATES["${subsystem}"]="Queued"
        fi
    done
}

function parse_options() {
    TARGET_BUILD_MMITEST="${TARGET_BUILD_MMITEST:-"false"}"
    BUILD_THREADS="${BUILD_THREADS:-${MAX_ALLOWED_JOBS}}"
    while true; do
        case ${1} in
        -p | --product)
            BUILD_PRODUCT="${2}"
            shift 2
            ;;
        -v | --variant)
            TARGET_BUILD_VARIANT="${2}"
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
    for subsystem in "${@}"; do
        BUILD_SUBSYSTEM+=("${subsystem}")
    done
    if (grep -qw "all" <<<"${BUILD_SUBSYSTEM[*]}"); then
        BUILD_SUBSYSTEM=("${VALID_SUBSYSTEM_LIST[@]}")
        BUILD_BACKGROUND="&"
    fi
    print_info "BUILD_SUBSYSTEM: ${BUILD_SUBSYSTEM[*]}"
    check_build_options
    set_build_list
    for subsystem in "${!SUBSYSTEM_STATES[@]}"; do
        print_info "${subsystem}: ${SUBSYSTEM_STATES[${subsystem}]}"
    done
}

function set_build_dir() {
    local target_list
    local ANSWER
    local index
    index=1
    target_list=($(find . -maxdepth 1 -type d \( -name "${1}*" -o -name "${1^^}*" \) -exec basename {} \;))
    if [ "${1}" == "target"  ]; then
        target_list+=($(find . -maxdepth 1 -type d \( -name "vendor*" -o -name "VENDOR*" \) -exec basename {} \;))
    fi
    if [ "${#target_list[@]}" -eq 0 ]; then
        echo "No ${1} build path found on current directory ${PWD}"
        exit 1
    fi
    while true; do
        echo "Please choose ${1} build path:"
        for folder in "${target_list[@]}"; do
            echo "${index}. $(basename "${folder}")"
            index=$((index + 1))
        done
        echo -n "Please input ${1} build path: "
        read -r ANSWER
        if [ -n "${ANSWER}" ]; then
            if (grep -qw -E "^[0-9]+$" <<<"${ANSWER}"); then
                if [ -n "${target_list[$((ANSWER - 1))]}" ]; then
                    eval "${1^^}_ROOT=$(realpath "${target_list[$((ANSWER - 1))]}")"
                    break
                fi
            else
                if (grep -qw "${ANSWER}" <<<"${target_list[@]}"); then
                    eval "${1^^}_ROOT=$(realpath "${ANSWER}")"
                    break
                fi
            fi
        fi
        echo "Invalid path for ${1} build"
        exit 1
    done
}

function variables_setup() {

    check_tools

    [ -z "$WORKSPACE" ] && WORKSPACE="$(dirname "$(dirname "$SCRIPT_PATH")")"
    cd "$WORKSPACE" || exit 2

    [ -z "$QSSI_ROOT" ] && set_build_dir "qssi"
    [ -z "${TARGET_ROOT}" ] && set_build_dir "target"
    AMSS_ROOT="${TARGET_ROOT}/amss_sm7635"

    LOGGING_MAPPING["qssi"]="${QSSI_ROOT}/log.qssi"
    LOGGING_MAPPING["kernel"]="${TARGET_ROOT}/log.kernel"
    LOGGING_MAPPING["vendor"]="${TARGET_ROOT}/log.vendor"
    LOGGING_MAPPING["amss"]="${AMSS_ROOT}/log.amss"
    LOGGING_MAPPING["merge"]="${TARGET_ROOT}/log.merge"

    if [ "${TARGET_BUILD_MMITEST}" == "true" ]; then
        BUILD_OPERATOR="mini"
    else
        BUILD_OPERATOR="global"
    fi
    if [ "${TARGET_BUILD_VARIANT}" == "user" ]; then
        KERNEL_VARIANT="gki"
    else
        KERNEL_VARIANT="consolidate"
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
}

function set_build_state() {
    local result
    local subsystem
    result=1
    subsystem="$1"
    case ${subsystem} in
    kernel)
        (tail -n 5 "${LOGGING_MAPPING[${subsystem}]}" | grep -q "ufdt_apply_overlay:") && result=0
        ;;
    qssi|vendor)
        (tail -n 100 "${LOGGING_MAPPING[${subsystem}]}" | grep -q "#### build completed successfully") && result=0
        ;;
    amss)
        (tail -n 50 "${LOGGING_MAPPING[${subsystem}]}" | grep -q "Saving cmm script.") && result=0
        ;;
    merge)
        (tail -n 5 "${LOGGING_MAPPING[${subsystem}]}" | grep -q -E "INFO\s+: Completed Successfully!") && result=0
    esac

    if [ "${result}" -eq 0 ]; then
        print_info "build ${subsystem} binaries success"
        SUBSYSTEM_STATES["${subsystem}"]="Success"
    else
        print_info "build ${subsystem} binaries failure"
        if [ "${subsystem}" == "kernel" ]; then
            SUBSYSTEM_STATES["kernel"]="Failure"
            SUBSYSTEM_STATES["vendor"]="Skipped"
        else
            SUBSYSTEM_STATES["${subsystem}"]="Failure"
        fi
        if [ "${subsystem}" != "amss" ]; then
            [ "${SUBSYSTEM_STATES["merge"]}" == "Queued" ] && SUBSYSTEM_STATES["merge"]="Skipped"
        fi
        [ "${SUBSYSTEM_STATES["copy"]}" == "Queued" ] && SUBSYSTEM_STATES["copy"]="Skipped"
    fi
}

function build_amss() {
    print_info "build amss binaries"
    pushd "${AMSS_ROOT}" >/dev/null || exit 2
    command "bash linux_build.sh -A ${BUILD_PRODUCT} ${BUILD_OPERATOR} 2>&1 | tee ${LOGGING_MAPPING[amss]}"
    set_build_state "amss"
    popd >/dev/null || exit 2
}

function build_system() {
    print_info "build android images for ${TARGET_PRODUCT}"
    pushd "${QSSI_ROOT}" >/dev/null || exit 2
    source build/envsetup.sh
    export TARGET_BUILD_MMITEST
    lunch "${TARGET_PRODUCT}-${TARGET_BUILD_VARIANT}"
    command "bash build.sh dist --qssi_only -j${BUILD_THREADS} 2>&1 | tee ${LOGGING_MAPPING["qssi"]}"
    popd >/dev/null || exit 2
}

function build_kernel() {
    print_info "build kernel binaries for ${TARGET_PRODUCT}"
    pushd "${TARGET_ROOT}" >/dev/null || exit 2
    source build/envsetup.sh
    export TARGET_BUILD_MMITEST
    lunch "${TARGET_PRODUCT}-${TARGET_BUILD_VARIANT}"
    if [ "${TARGET_PRODUCT}" == "volcano" ]; then
        KERNEL_TARGET="pineapple"
    else
        KERNEL_TARGET="${TARGET_PRODUCT}"
    fi
    command "RECOMPILE_KERNEL=1 bash kernel_platform/build/android/prepare_vendor.sh ${KERNEL_TARGET} ${KERNEL_VARIANT} 2>&1 | tee ${LOGGING_MAPPING["kernel"]}"
    popd >/dev/null || exit 2
}

function build_vendor() {
    print_info "build android images for ${TARGET_PRODUCT}"
    pushd "${TARGET_ROOT}" >/dev/null || exit 2
    source build/envsetup.sh
    export TARGET_BUILD_MMITEST
    lunch "${TARGET_PRODUCT}-${TARGET_BUILD_VARIANT}"
    command "bash build.sh dist --target_only -j${BUILD_THREADS} 2>&1 | tee ${LOGGING_MAPPING["vendor"]}"
    popd >/dev/null || exit 2
}

function build_super() {
    print_info "merge qssi and vendor, generate super image"
    pushd "$QSSI_ROOT" >/dev/null || exit 2
    command "python vendor/qcom/opensource/core-utils/build/build_image_standalone.py \
                 --image super \
                 --qssi_build_path ${QSSI_ROOT} \
                 --target_build_path ${TARGET_ROOT} \
                 --merged_build_path ${TARGET_ROOT} \
                 --target_lunch ${BUILD_PRODUCT} --output_ota 2>&1 | tee ${LOGGING_MAPPING["merge"]}"
    set_build_state "merge"
    popd >/dev/null || exit 2
}

function get_all_gpt_files() {
    local total
    local index
    local gptfile
    total=$(xmlstarlet sel -t -m "//physical_partition" -n -v @text "${PARTITION_TABLE}" | wc -l)
    for gptfile in "${GPT_MAIN_FILES[@]}"; do
        for ((index = 1; index < "${total}"; index++)); do
            GPT_MAIN_FILES=("${GPT_MAIN_FILES[@]}" "${gptfile/0/$index}")
        done
    done
}

function collect_images() {
    local package_image_list
    local image

    get_all_gpt_files

    if [ -d "Images" ]; then
        rm -r "Images"
    fi
    mkdir "Images"
    package_image_list=($(xmlstarlet sel -t -m "//partition" -n -v @filename "${PARTITION_TABLE}" | sort | uniq))
    pushd "Images" >/dev/null || exit 2
    for image in "${package_image_list[@]}" "${GPT_MAIN_FILES[@]}"; do
        if [ -f "${AMSS_PRODUCT_OUT}/${image}" ]; then
            command "ln -sf ${AMSS_PRODUCT_OUT}/${image} ${image}"
        elif [ -f "${ANDROID_PRODUCT_OUT}/${image}" ]; then
            command "ln -sf ${ANDROID_PRODUCT_OUT}/${image} ${image}"
        else
            if (grep -w -q "${image}" <<<"study.tar swversion.mbn"); then
                print_info "${image} not found, ignore"
                continue
            fi
            print_error "${image} generate failed"
            SUBSYSTEM_STATES["copy"]="Failure"
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
    popd >/dev/null || exit 2
}

function build_product() {
    local system_pid
    local kernel_pid
    local vendor_pid

    if [ "${SUBSYSTEM_STATES["qssi"]}" == "Queued" ]; then
        command "TARGET_PRODUCT=qssi_64 build_system ${BUILD_BACKGROUND}"
        system_pid=$!
    fi

    if [ "${SUBSYSTEM_STATES["kernel"]}" == "Queued" ]; then
        command "TARGET_PRODUCT=${BUILD_PRODUCT} build_kernel ${BUILD_BACKGROUND}"
        kernel_pid=$!
    fi

    if [ -n "${kernel_pid}" ]; then
        wait ${kernel_pid}
        set_build_state "kernel"
        SUBSYSTEM_STATES["target"]=${SUBSYSTEM_STATES["kernel"]}
        LOGGING_MAPPING["target"]=${LOGGING_MAPPING["kernel"]}
    fi

    if [ "${SUBSYSTEM_STATES["vendor"]}" == "Queued" ]; then
        command "TARGET_PRODUCT=${BUILD_PRODUCT} build_vendor ${BUILD_BACKGROUND}"
        vendor_pid=$!
    fi

    [ "${SUBSYSTEM_STATES["amss"]}" == "Queued" ] && build_amss

    if [ -n "${system_pid}" ]; then
        wait ${system_pid}
        set_build_state "qssi"
    fi

    if [ -n "${vendor_pid}" ]; then
        wait ${vendor_pid}
        set_build_state "vendor"
        SUBSYSTEM_STATES["target"]=${SUBSYSTEM_STATES["kernel"]}
        LOGGING_MAPPING["target"]=${LOGGING_MAPPING["kernel"]}
    fi

    [ "${SUBSYSTEM_STATES["merge"]}" == "Queued" ] && build_super

    [ "${SUBSYSTEM_STATES["copy"]}" == "Queued" ] && collect_images
}

function print_build_status() {
    local subsystem
    local build_result
    local extra_info
    print_info "Build status:"
    for subsystem in "${VALID_SUBSYSTEM_LIST[@]}"; do
        unset extra_info
        if [ "${SUBSYSTEM_STATES["$subsystem"]}" != "Queued" ]; then
            case "${SUBSYSTEM_STATES["$subsystem"]}" in
                "Success")
                    build_result="Success"
                    ;;
                "Failure")
                    build_result="Failed"
                    extra_info="; Check log file: ${LOGGING_MAPPING["$subsystem"]}"
                    ;;
                "Skipped")
                    build_result="Skipped"
                    extra_info="; Skipped due to prior failure"
                    ;;
                "Disabled")
                    build_result="Skipped"
                    extra_info="; Not enabled"
                    ;;
                *)
                    build_result="Unknown"
                    ;;
            esac
            echo "build $subsystem : ${SUBSYSTEM_STATES["$subsystem"]}${extra_info}"
        fi
    done
    if [ "${build_result}" == "Failed" ]; then
        print_info "Build failed"
        exit 1
    fi
    print_info "Build completed"
}

if ! options=$(getopt --option p:v:j:mh --long product:,variant:,mmitest,job:,help -n "$0" -- "$@"); then
    usage
fi
eval set -- "$options"

parse_options "$@"

variables_setup

build_product

print_build_status
