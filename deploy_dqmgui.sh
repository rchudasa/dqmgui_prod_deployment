#!/bin/env bash
#
# Script intended for installing [legacy] DQMGUI on online HLT machines (dqmsrv-...).
# It tries to imitate the behavior of the Deploy script without installing external RPMs.
#
# The installation depends on the steps defined in the installation_steps array.
# They are executed in sequence and can be skipped with the appropriate flag.
#
# Only targeting RHEL8 + Python3.8 for now(!)
#
# If the target (installation+dmqm tag) directory exists (e.g. /data/srv/$DMWM_GIT_TAG), it will
# be *DELETED* by the script, before re-installing. The "state" dir is left alone.
#
# Required system packages: See os_packages.txt which accompanies this script.
#
# Required tools: patch, curl (if patching DMWM directly from github PRs)
#
# Contact: cms-dqm-coreteam@cern.ch

# Stop at any non-zero return
set -e

# Enable verbose logging
VERBOSE_LOGGING=0

# Main directory we're installing into.
INSTALLATION_DIR=/data/srv

# Remember the directory where the script was called from
CALLER_DIRECTORY=$PWD

# Default value set for each step flag. Set this to 0 to skip all steps.
# This helps if you want to only run only a few steps of the installation only.
EXECUTE_ALL_STEPS=1

#
declare -A SPECIAL_HOSTS=(
    ["vocms0730"]="dev"
    ["vocms0736"]="offline"
    ["vocms0737"]="relval"
)

# This scipt's directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Get constants from config file
# This is needed to name some directories whose name is
# based on the version of the package (DMWM and DQMGUI).
source $SCRIPT_DIR/config.sh

TMP_BASE_PATH=/tmp

DMWM_PRS_URL_BASE="https://github.com/dmwm/deployment/pull"
# Comma-separated DMWM PRs to apply. E.g., 1312,1315
DMWM_PRS=

# Where the keytab should be found
WMCORE_AUTH_DIR="$HOME/auth/wmcore-auth/"

# Function to sanitize args to a folder name
# From here: https://stackoverflow.com/a/44811468/6562491
# echoes "null" if no input given.
_sanitize_string() {
    local s="${*:-null}"     # receive input in first argument
    s="${s//[^[:alnum:]]/-}" # replace all non-alnum characters to -
    s="${s//+(-)/-}"         # convert multiple - to single -
    s="${s/#-/}"             # remove - from start
    s="${s/%-/}"             # remove - from end
    echo "${s,,}"            # convert to lowercase
}

# Preliminary checks to do before installing the GUI
preliminary_checks() {
    # Display all commands if asked to
    if [ "$VERBOSE_LOGGING" -ne 0 ]; then
        set -x
    fi

    # Make sure we don't have superuser privileges
    if [ "$(id -u)" -eq 0 ]; then
        echo "This script should not be run with superuser privileges!" 1>&2
        exit 1
    fi

    if [ -n "$DMWM_PRS" ]; then
        # If there are PRs to apply, check if patch is available locally
        if ! command -v patch >/dev/null; then
            echo "ERROR: PRs to apply were specified but the patch command is not available"
            exit 1
        fi
        OLD_IFS=$IFS
        IFS=','
        # Split PRs with commas
        for pr in $DMWM_PRS; do
            # Each should be a number
            if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
                echo "ERROR: $pr is not a valid PR number"
                exit 1
            fi
            # Did not find diff locally, try downloading it
            if ! _find_patch $pr >/dev/null; then
                if ! command -v curl >/dev/null; then
                    echo "ERROR: $pr not available locally and curl is not installed"
                fi
                echo "INFO: Did not find $pr diff locally, trying downloading it from $DMWM_PRS_URL_BASE"
                if ! curl --silent -L "${DMWM_PRS_URL_BASE}/${pr}.diff" >"/tmp/${pr}.diff"; then
                    echo "ERROR: Could not download diff for PR $pr from $DMWM_PRS_URL_BASE"
                    rm -rf "/tmp/${pr}.diff"
                    exit 1
                fi
            fi
        done
        IFS=$OLD_IFS
    fi

    # Stop GUI if already running
    if [ -f "${INSTALLATION_DIR:?}/current/config/dqmgui/manage" ] &&
        [ -f "$INSTALLATION_DIR/current/apps/dqmgui/128/etc/profile.d/env.sh" ]; then
        $INSTALLATION_DIR/current/config/dqmgui/manage stop 'I did read documentation'
    fi

    # Delete installation (config & sw, does not delete state)
    if [ -d "${INSTALLATION_DIR:?}/${DMWM_GIT_TAG:?}" ]; then
        echo "WARNING: $INSTALLATION_DIR/$DMWM_GIT_TAG exists, deleting contents"
        rm -rf "${INSTALLATION_DIR:?}/${DMWM_GIT_TAG:?}/"
    fi

}
# Check for needed OS-wide dependencies
check_dependencies() {
    # Read in the required packages
    _package_list=$(cat "$SCRIPT_DIR/os_packages.txt")
    # Split into array
    declare -a required_packages=($_package_list)

    # Instead of doing a 'yum list' per package, it may be faster to just
    # ask all of them at once, and dump to file. Then grep the file.
    echo -n "Getting system packages..."
    installed_packages=$(yum list --installed ${required_packages[*]})
    echo "Done"

    # Look for the package in the installed packages
    for package in "${required_packages[@]}"; do
        if ! echo $installed_packages | grep -q "$package"; then
            echo "ERROR: Package $package missing please run: 'sudo yum install ${required_packages[@]}'"
            exit 1
        fi
    done

    echo "INFO: All required packages are installed"
}

# Clean VOCMS-specific crontabs
_clean_crontab_vocms() {
    FLAVOR="${SPECIAL_HOSTS[$HOST]}"
    if [ -z "$FLAVOR" ]; then
        echo "INFO: Not a vocms machine, not cleaning vocms crontabs"
        return
    fi
    crontab -l 2>/dev/null | grep -v "$INSTALLATION_DIR/current/config/dqmgui/kinit.sh" | crontab -
}

# Remove existing DQMGUI cronjobs
clean_crontab() {
    _clean_crontab_vocms
    # Filter cronjobs starting in $INSTALLATION_DIR/current/dqmgui and
    # replace crontabs
    crontab -l 2>/dev/null | grep -v "HOME=/tmp" | grep -v "$INSTALLATION_DIR/current/config/dqmgui" | grep -vE "$INSTALLATION_DIR/current.+logrotate.conf" | crontab -
}

# Crontabs specific to VOCMS
_install_crontab_vocms() {
    FLAVOR="${SPECIAL_HOSTS[$HOST]}"
    if [ -z "$FLAVOR" ]; then
        echo "INFO: Not a vocms machine, not installing vocms crontabs"
        return
    fi
    (
        crontab -l # Get existing crontabs
        # Adding kinit script for EOS
        echo "*/6 * * * * $INSTALLATION_DIR/current/config/dqmgui/kinit.sh"
        echo "@reboot $INSTALLATION_DIR/current/config/dqmgui/kinit.sh"
        # backup of the index
        echo "0 7 * * * $INSTALLATION_DIR/current/config/dqmgui/manage indexbackup 'I did read documentation'; ret=\$?; if [ \$ret -ne 3 ] && [ \$ret -ne 0 ] && [ \$ret -ne 4 ]; then echo Error during backup | mailx -s \"$FLAVOR DQM GUI Index Backup, exit code: \$ret\" -a $INSTALLATION_DIR/logs/dqmgui/$FLAVOR/agent-castorindexbackup-$HOST.log cmsweb-operator@cern.ch; fi"
        # backup of the zipped root files
        echo "*/15 * * * * $INSTALLATION_DIR/current/config/dqmgui/manage zipbackup 'I did read documentation'; ret=\$?; if [ \$ret -ne 3 ] && [ \$ret -ne 0 ] && [ \$ret -ne 4 ]; then echo Error during backup | mailx -s \"$FLAVOR DQM GUI Zip Backup, exit code: \$ret\" -a $INSTALLATION_DIR/logs/dqmgui/$FLAVOR/agent-castorzipbackup-$HOST.log cmsweb-operator@cern.ch; fi"
        # check/verification HOST the backup of the zipped root files
        echo "*/15 * * * * $INSTALLATION_DIR/current/config/dqmgui/manage zipbackupcheck 'I did read documentation'; ret=\$?; if [ \$ret -ne 3 ] && [ \$ret -ne 0 ] && [ \$ret -ne 4 ]; then echo Error during backup | mailx -s \"$FLAVOR DQM GUI Zip Backup Check, exit code: \$ret\" -a $INSTALLATION_DIR/logs/dqmgui/$FLAVOR/agent-castorzipbackupcheck-$HOST.log cmsweb-operator@cern.ch; fi"
    ) | crontab -
}

# Install DQMGUI cronjobs
install_crontab() {
    _create_logrotate_conf
    (
        crontab -l # Get existing crontabs
        echo "17 2 * * * $INSTALLATION_DIR/current/config/dqmgui/daily"
        echo "HOME=/tmp" # Workaround for P5, where the home dir is an NFS mount and isn't immediately available.
        echo "@reboot (sleep 30 && $INSTALLATION_DIR/current/config/dqmgui/manage sysboot)"
        # If the workaround script for managing free memory exists, add a crontab for it to run every 2 hours.
        if [ -f "$INSTALLATION_DIR/current/config/dqmgui/restart_webserver_if_memory_low" ]; then
            echo "30 */2 * * * $INSTALLATION_DIR/current/config/dqmgui/restart_webserver_if_memory_low  >> /data/srv/logs/dqmgui/restart_webserver_if_memory_low.log"
        fi
    ) | crontab -
    _install_crontab_vocms
}

# Copy CMSWEB-only required auth files
# This was originally done by installing the appropriate package,
# but since this deployment script is completely custom, it is now
# done "manually". The keytab and header-auth-key files are expected
# to be found in WMCORE_AUTH_DIR
copy_wmcore_auth() {
    FLAVOR="${SPECIAL_HOSTS[$HOST]}"
    if [ -z "$FLAVOR" ]; then
        echo "INFO: Not a vocms machine, not copying wmcore auth"
        return
    fi
    if [ ! -d "$WMCORE_AUTH_DIR" ]; then
        echo "WARNING: $WMCORE_AUTH_DIR was not found, cannot copy auth files"
        return
    fi
    echo "INFO: Copying wmcore-auth files"
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/auth/wmcore-auth"
    cp "$WMCORE_AUTH_DIR/"{keytab,header-auth-key} "$INSTALLATION_DIR/$DMWM_GIT_TAG/auth/wmcore-auth"

}

# Create necessary directories for installation
create_directories() {
    # Dirs to create under INSTALLATION_DIR
    declare -a necessary_dirs=("logs" "state" "enabled" "$DMWM_GIT_TAG")
    for subdir in "${necessary_dirs[@]}"; do
        dirname="$INSTALLATION_DIR/$subdir"
        echo "DEBUG: Creating subdirectory $dirname"
        mkdir -p "$dirname"
    done
    mkdir -p $INSTALLATION_DIR/logs/dqmgui

    # Create subdirs for state/dqmgui
    mkdir -p $INSTALLATION_DIR/state/dqmgui
    declare -a necessary_dirs=("backup" "dev" "offline" "online" "relval")
    for subdir in "${necessary_dirs[@]}"; do
        # State dirs
        dirname="$INSTALLATION_DIR/state/dqmgui/$subdir"
        echo "DEBUG: Creating subdirectory $dirname"
        mkdir -p "$dirname"
        if [ -f "$INSTALLATION_DIR/state/dqmgui/$subdir" ]; then
            echo "INFO: Removing blacklist.txt"
            rm "$INSTALLATION_DIR/state/dqmgui/$subdir/blacklist.txt"
        fi
        # Log dirs
        dirname="$INSTALLATION_DIR/logs/dqmgui/$subdir"
        echo "DEBUG: Creating subdirectory $dirname"
        mkdir -p "$dirname"
    done

    # Dirs to create under DMWM_GIT_TAG dir
    declare -a necessary_dirs=("config" "sw" "apps.sw" "auth")
    for subdir in "${necessary_dirs[@]}"; do
        dirname="$INSTALLATION_DIR/$DMWM_GIT_TAG/$subdir"
        echo "DEBUG: Creating subdirectory $dirname"
        mkdir -p "$dirname"
    done

    if [ ! -L "$INSTALLATION_DIR/$DMWM_GIT_TAG/apps" ]; then
        echo "DEBUG: Creating link $INSTALLATION_DIR/$DMWM_GIT_TAG/apps.sw <-- $INSTALLATION_DIR/$DMWM_GIT_TAG/apps"
        ln -s "$INSTALLATION_DIR/$DMWM_GIT_TAG/apps.sw" "$INSTALLATION_DIR/$DMWM_GIT_TAG/apps"
    fi

    # Create a "current" link to the DMWM version we're using, like how it was done
    # in the older scripts.
    if [ -L $INSTALLATION_DIR/current ]; then
        rm $INSTALLATION_DIR/current
    fi
    echo "DEBUG: Creating link $INSTALLATION_DIR/$DMWM_GIT_TAG <-- $INSTALLATION_DIR/current"
    ln -s "$INSTALLATION_DIR/$DMWM_GIT_TAG" "$INSTALLATION_DIR/current"

    # Directories for external source and lib files (e.g. classlib)
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src"
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib"

    # DQMGUI dirs
    echo "DEBUG: Creating subdirectory $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG"
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG"

}

install_rotoglup() {
    mkdir -p $ROTOGLUP_TMP_DIR
    tar -xzf "$SCRIPT_DIR/rotoglup/rotoglup.tar.gz" -C "$TMP_BASE_PATH"

    cd $ROTOGLUP_TMP_DIR
    #patch -p1 < $SCRIPT_DIR/rotoglup/patches/01.patch
    patch -p1 <"$SCRIPT_DIR/rotoglup/patches/02.patch"
    rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/rtgu"
    mv $ROTOGLUP_TMP_DIR/rtgu "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/rtgu"
    cd $INSTALLATION_DIR/
    rm -rf $ROTOGLUP_TMP_DIR
}

# Compilation step for classlib
compile_classlib() {
    cd "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/classlib-3.1.3"

    #INCLUDE_DIRS="$INCLUDE_DIRS:/usr/include/lzo" make -j `nproc`
    make -j "$(nproc)" CXXFLAGS="-Wno-error=extra -ansi -pedantic -W -Wall -Wno-long-long -Werror"

    # Move the compiled library in the libs dir
    mv "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/classlib-3.1.3/.libs/libclasslib.so" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib/libclasslib.so"

}

# Classlib is needed both as a shared object and for its header files for DQMGUI compilation.
install_classlib() {
    # Temporary directory to extract to

    mkdir -p $CLASSLIB_TMP_DIR
    tar -xf "$SCRIPT_DIR/classlib/classlib-3.1.3.tar.bz2" -C "${TMP_BASE_PATH}"

    # Apply code patches I found on cmsdist. The 7th one is ours, and has some extra needed fixes.
    cd $CLASSLIB_TMP_DIR
    for i in 1 2 3 4 5 6 7 8; do
        patch -p1 <"$SCRIPT_DIR/classlib/patches/0${i}.patch"
    done

    # Run cmake to generate makefiles and others
    cmake .

    ./configure

    # More stuff I found on cmsdist
    perl -p -i -e '
      s{-llzo2}{}g;
        !/^\S+: / && s{\S+LZO((C|Dec)ompressor|Constants|Error)\S+}{}g' \
        $CLASSLIB_TMP_DIR/classlib-3.1.3/Makefile

    if [ -d "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/classlib-3.1.3" ]; then
        rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/classlib-3.1.3"
    fi

    # Move the classlib files inside the installation dir, needed for compiling the GUI
    mv "$CLASSLIB_TMP_DIR" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/"

    # Make a link so that DQMGUI compilation can find the classlib headers easily
    ln -s "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/classlib-3.1.3/classlib" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/classlib"

    rm -rf $CLASSLIB_TMP_DIR
}

install_boost_gil() {
    mkdir -p $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/
    tar -xzf "$SCRIPT_DIR/boost_gil/boost_gil.tar.gz" -C "${TMP_BASE_PATH}"
    rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/boost" # Cleanup dir if exists
    mv "${TMP_BASE_PATH}/boost_gil/include/boost" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/boost"
}

install_gil_numeric() {
    tar -xzf "$SCRIPT_DIR/numeric/numeric.tar.gz" -C "${TMP_BASE_PATH}"
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/boost/gil/extension/"
    rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/boost/gil/extension/numeric" # Cleanup dir if exists
    mv "$NUMERIC_TMP_DIR" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/boost/gil/extension/numeric"
}

# Split DMWM installation to allow a user apply patches
extract_dmwm() {
    # Temporary directory to clone DMWM deployment scripts into
    mkdir -p $DMWM_TMP_DIR
    tar -xzf "$SCRIPT_DIR/dmwm/dmwm.tar.gz" -C "${TMP_BASE_PATH}"
}

# Update the keytab path in kinit.sh. This only applies for VOCMS deployments
# which require access to EOS, therefore, need to run kinit.
_update_keytab_path() {
    FLAVOR="${SPECIAL_HOSTS[$HOST]}"
    if [ -z "$FLAVOR" ]; then
        echo "INFO: Not a vocms machine, not updating kinit.sh"
        return
    fi
    echo "INFO: Updating keytab path in file $INSTALLATION_DIR/current/config/dqmgui/kinit.sh"
    sed -E "s#export\s+keytab.+#export keytab=\"$INSTALLATION_DIR/$DMWM_GIT_TAG/auth/wmcore-auth/keytab\"#" -i "$INSTALLATION_DIR/current/config/dqmgui/kinit.sh"
}

install_dmwm() {
    # Move dqmgui-related scripts from DMWM to the config folder
    rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/config/dqmgui"                    # Cleanup dir if exists
    mv "$DMWM_TMP_DIR/dqmgui" "$INSTALLATION_DIR/$DMWM_GIT_TAG/config/dqmgui" # DQMGUI Layouts
    _update_keytab_path                                                       # Update the kinit.sh script, if applicable, to use the proper keytab file
    rm -rf $DMWM_TMP_DIR
}

# Tries to look for a <pr_num>.patch or <pr_num>.diff in /tmp or /globalscratch
# Returns nothing if it wasn't found.
_find_patch() {
    pr_num=${1?}
    dirs_to_check=("/tmp" "/globalscratch")
    valid_extensions=(".patch" ".diff")
    for dir in "${dirs_to_check[@]}"; do
        for extension in "${valid_extensions[@]}"; do
            patch_filename="${pr_num}${extension}"
            patch_filepath="${dir}/${patch_filename}"
            if [ -f "$patch_filepath" ]; then
                echo "$patch_filepath"
                return 0
            fi
        done
    done
    return 1
}

# Apply patches to DMWM. Assumes that the patches are available (done during preliminary_checks)
patch_dmwm() {
    OLD_IFS=$IFS
    IFS=','
    cd $DMWM_TMP_DIR
    for pr in $DMWM_PRS; do
        echo "INFO: Looking for the PR $pr patch"
        patch_filepath="$(_find_patch $pr)"
        if [ -z "$patch_filepath" ]; then
            echo "ERROR: Could not find patch for PR $pr"
            return 1
        fi
        echo "INFO: Applying $patch_filepath"
        patch -p1 <"$patch_filepath"
    done
    IFS=$OLD_IFS
    cd -
}

# Create a configuration file for logrotate to manage...(surprise!) rotating logs.
_create_logrotate_conf() {
    echo "# DQMGUI logrotate configuration file
# Automagically generated, please do not edit.

# Make daily compressed rotations in the same directory, keep up to
# 1 year of logs. Dooes not remove the rotated logs, instead copies the
# contents and truncates them to 0.
$INSTALLATION_DIR/logs/dqmgui/*/*.log {
    daily
    compress
    copytruncate
    rotate 365
    maxage 365
    noolddir
    nomail
    dateext
}
" >"$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/etc/logrotate.conf"
}

# env.sh and init.sh file creation. They're needed by other scripts (e.g. manage).
_create_env_and_init_sh() {
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/etc/profile.d/"

    # init.sh contents. This is sourced by env.sh
    echo "export PATH=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/bin:$PATH
export PYTHONPATH=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/lib/python${PYTHON_VERSION}/site-packages:$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/lib64/python${PYTHON_VERSION}/site-packages
.  $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/bin/activate
" >"$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/etc/profile.d/init.sh"

    # env.sh contents. This is sourced by the manage script
    echo ". $INSTALLATION_DIR/$DMWM_GIT_TAG/apps/dqmgui/128/etc/profile.d/init.sh
export YUI_ROOT=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/yui
export EXTJS_ROOT=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/extjs
export D3_ROOT=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/d3
export ROOTJS_ROOT=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/jsroot
export MONITOR_ROOT=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv
export DQMGUI_VERSION='$DQMGUI_GIT_TAG';
# For pointing to the custom built libraries
export LD_PRELOAD=\"$INSTALLATION_DIR/$DMWM_GIT_TAG/apps/dqmgui/128/lib/libDQMGUI.so $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib/libclasslib.so\"
export LD_LIBRARY_PATH=\"$INSTALLATION_DIR/$DMWM_GIT_TAG/apps/dqmgui/128/lib/:$LD_LIBRARY_PATH\"
source $ROOT_INSTALLATION_DIR/bin/thisroot.sh
" >"$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/etc/profile.d/env.sh"
}

# Crete the Python3 virtual environment for the GUI
_create_python_venv() {
    python_exe=$(which python${PYTHON_VERSION})

    python_venv_dir=$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv
    if [ -d "$python_venv_dir" ]; then
        rm -rf "$python_venv_dir"
    fi
    mkdir -p "$python_venv_dir"

    # Extract the downloaded python packages
    tar -xzf "$SCRIPT_DIR/pypi/pypi.tar.gz" -C "${TMP_BASE_PATH}"
    echo -n "INFO: Creating virtual environment at $python_venv_dir"
    $python_exe -m venv "$python_venv_dir"

    # Now use the new venv's python
    python_venv_exe=$python_venv_dir/bin/python

    PYTHON_LIB_DIR_NAME=lib/python$PYTHON_VERSION/site-packages
    export PYTHON_LIB_DIR_NAME

    # Install pip
    unzip -u ${TMP_BASE_PATH}/pip/pip*whl -d "${TMP_BASE_PATH}/pip/pip"
    if [ -d "$python_venv_dir/$PYTHON_LIB_DIR_NAME/pip" ]; then
        rm -rf "$python_venv_dir/$PYTHON_LIB_DIR_NAME/pip"
    fi

    # pipipipi
    mv "${TMP_BASE_PATH}/pip/pip/pip" "$python_venv_dir/$PYTHON_LIB_DIR_NAME/pip"
    rm -rf "${TMP_BASE_PATH}/pip/pip"

    # Install wheels
    eval "${python_venv_exe} -m pip install --no-index --find-links ${TMP_BASE_PATH}/pip ${TMP_BASE_PATH}/pip/*"
    eval "${python_venv_exe} -m pip install $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128"

    cd "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/"
    rm -rf "${TMP_BASE_PATH}/pip"
    echo "Done"
}

# External requirements for building the GUI
# Must be run after the venv is created
_create_makefile_ext() {
    echo "INCLUDE_DIRS = . $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/src/cpp /usr/include/libpng16 /usr/include/jemalloc $(root-config --incdir) $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src /usr/include/google/protobuf /usr/include/boost $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/src/root

LIBRARY_DIRS = . $ROOT_INSTALLATION_DIR/lib $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib /usr/lib /usr/lib64 $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/src/cpp/ $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/lib/
" >"$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/etc/makefile.ext"
}

# Compile and setup all the required stuff that DQMGUI needs.
# Custom libraries, binaries, links to other libraries...
# Then runs the actual compilation, which is the part that takes the longest
# in this script.
compile_dqmgui() {
    cd "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/"
    # Links to python libraries so that the build command can find them
    if [ ! -L "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib/libboost_python.so" ]; then
        ln -s /usr/lib64/libboost_python3.so "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib/libboost_python.so"
    fi

    if [ ! -L "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib/libpython${PYTHON_VERSION}.so" ]; then
        ln -s /usr/lib64/libpython3.so "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/lib/libpython${PYTHON_VERSION}.so"
    fi

    # python3-config is not always in a predictable place
    python_config_cmd=$(which python${PYTHON_VERSION}-config) || python_config_cmd=$(find /usr/bin -name "python3*-config" | head -1)

    if [ -z "$python_config_cmd" ]; then
        echo "ERROR: Could not find python${PYTHON_VERSION}-config"
        exit 1
    fi
    # The actual build command. Uses the makefile in the DQMGUI's repo.
    source "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/bin/activate"
    PYTHONPATH="$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/lib/python${PYTHON_VERSION}/site-packages:$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/lib64/python${PYTHON_VERSION}/site-packages" CPLUS_INCLUDE_PATH="$(${python_config_cmd} --includes | sed -e 's/-I//g')" $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/bin/python $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/setup.py -v build_system -s DQM -d

    # Stuff that I found being done in the dqmgui spec file. I kind of blindy copy paste it
    # here because reasons.
    $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/bin/python $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/setup.py -v install_system -s DQM

    # Move executables to expected place
    for exe in DQMCollector visDQMIndex visDQMRender; do
        mv "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/src/cpp/$exe" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/bin/$exe"
    done

    # Move libs to expected place
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/lib/"
    mv "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/src/cpp/libDQMGUI.so" $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/lib/libDQMGUI.so

    # Move the custom Boost.Python interface library to libs.
    mv $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/src/cpp/Accelerator.so $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/build/lib/Monitoring/DQM/Accelerator.so

    # Compiles layouts etc.
    $INSTALLATION_DIR/current/config/dqmgui/manage compile
}

# Installation procedure of the DQMGUI source.
# Based on recipe I found here: https://github.com/cms-sw/cmsdist/blob/comp_gcc630/dqmgui.spec
# The resulting directory structure and compiled binaries is a mess, but that's the best
# we can do right now, considering the existing mess.
install_dqmgui() {
    # Activate ROOT, we need it to be available so that we can run root-config later
    source "$ROOT_INSTALLATION_DIR/bin/thisroot.sh"

    # Temporary directory to clone GUI into
    tar -xzf "$SCRIPT_DIR/dqmgui/dqmgui.tar.gz" -C "${TMP_BASE_PATH}"

    # Move dqmgui source and bin files to appropriate directory
    if [ -d "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG" ]; then
        rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG"
    fi
    mkdir -p "$DQMGUI_TMP_DIR" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/"
    mv $DQMGUI_TMP_DIR "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128"

    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/data"

    if [ ! -L "$INSTALLATION_DIR/$DMWM_GIT_TAG/apps/dqmgui" ]; then
        echo "DEBUG: Creating link $INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG <-- $INSTALLATION_DIR/$DMWM_GIT_TAG/apps/dqmgui"
        ln -s "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG" "$INSTALLATION_DIR/$DMWM_GIT_TAG/apps/dqmgui"
    fi

    # Create python venv for all python "binaries" and webserver
    _create_python_venv

    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/data/" # Needed for DQMGUI templates
    if [ -d "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/data/templates" ]; then
        rm -rf "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/data/templates"
    fi

    mv "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/cms/dqmgui/$DQMGUI_GIT_TAG/128/src/templates" "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/venv/data/templates"

    # Create files needed by manage script for env variables
    _create_env_and_init_sh

    # Dynamic parametrization of the makefile, i.e. paths required
    # during the compilation procedure.
    _create_makefile_ext
}

# Javascript library
install_yui() {
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/yui"
    tar -xzf "$SCRIPT_DIR/yui/yui.tar.gz" -C "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external"
}

# Javascript library
install_extjs() {
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/extjs"
    tar -xzf "$SCRIPT_DIR/extjs/extjs.tar.gz" -C "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external"
}

# Javascript library
install_d3() {
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/d3"
    tar -xzf "$SCRIPT_DIR/d3/d3.tar.gz" -C "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external"
}

# Javascript library
install_jsroot() {
    mkdir -p "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external/jsroot"
    tar -xzf "$SCRIPT_DIR/jsroot/jsroot.tar.gz" -C "$INSTALLATION_DIR/$DMWM_GIT_TAG/sw/external"
}

# Extract the ROOT tar to a tmp folder for compilation
install_root() {
    if source "$ROOT_INSTALLATION_DIR/bin/thisroot.sh"; then
        echo "INFO: ROOT installation found, not installing ROOT"
        return
    fi
    mkdir -p $ROOT_TMP_DIR
    tar -xzf "$SCRIPT_DIR/root/root.tar.gz" -C "${ROOT_TMP_DIR}"
}

compile_root() {
    if source "$ROOT_INSTALLATION_DIR/bin/thisroot.sh"; then
        echo "INFO: ROOT installation found, not re-compiling ROOT"
        return
    fi
    if [ ! -d $ROOT_TMP_DIR ]; then
        echo "ERROR: ROOT source was not found in $ROOT_TMP_DIR"
        exit 1
    fi

    mkdir -p $ROOT_TMP_BUILD_DIR
    cd $ROOT_TMP_BUILD_DIR
    cmake -DCMAKE_INSTALL_PREFIX=$ROOT_INSTALLATION_DIR $ROOT_TMP_DIR/root -DPython3_EXECUTABLE="$(which python${PYTHON_VERSION})" -Dtesting=OFF -Dbuiltin_gtest=OFF -Dclad=OFF
    cmake --build . --target install -j $(nproc)
    cd $INSTALLATION_DIR
    rm -rf $ROOT_TMP_DIR $ROOT_TMP_BUILD_DIR
}

function copy_env_file() {
    if [ -f "$CALLER_DIRECTORY/.env" ]; then
        echo "Copying .env file to state dir"
        if [ -f "$INSTALLATION_DIR/state/dqmgui/.env" ]; then
            rm -f "$INSTALLATION_DIR/state/dqmgui/.env"
        fi
        cp "$CALLER_DIRECTORY/.env" "$INSTALLATION_DIR/state/dqmgui"
        chmod 400 "$INSTALLATION_DIR/state/dqmgui/.env"
    else
        echo ".env file not found, skipping this step"
    fi

}

# Cleanup temporary directories, remove cronjobs
function _cleanup() {
    rm -rf $ROOT_TMP_DIR $ROOT_TMP_BUILD_DIR $ROTOGLUP_TMP_DIR $CLASSLIB_TMP_DIR $DMWM_TMP_DIR $NUMERIC_TMP_DIR $DQMGUI_TMP_DIR
    clean_crontab
}

### Main script ###

# Declare each step of the installation procedure here. Steps
# will be executed sequentially.
declare -a installation_steps=(preliminary_checks
    check_dependencies
    create_directories
    copy_env_file
    copy_wmcore_auth
    install_boost_gil
    install_gil_numeric
    install_rotoglup
    install_classlib
    compile_classlib
    extract_dmwm
    patch_dmwm
    install_dmwm
    install_root
    compile_root
    install_dqmgui
    compile_dqmgui
    install_yui
    install_extjs
    install_d3
    install_jsroot
    clean_crontab
    install_crontab)

# Parse command line arguments -- use <key>=<value> to override the flags mentioned above.
# e.g. do_install_yui=0
for ARGUMENT in "$@"; do
    KEY=$(echo "$ARGUMENT" | cut -f1 -d=)
    KEY_LENGTH=${#KEY}
    VALUE="${ARGUMENT:$KEY_LENGTH+1}"
    eval "$KEY=$VALUE"
done

# Create dynamic flags to selectively disable/enable steps of the installation
# Those flags are named "do_" with the name of the function, e.g. "do_install_yui" for
# the "install_yui" step and "do_check_dependencies" for "check_dependencies".
# We set those flags to the value of EXECUTE_ALL_STEPS by default.
for step in "${installation_steps[@]}"; do
    flag_name="do_${step}"
    if [ -z "${!flag_name}" ]; then
        echo "${flag_name} not defined"
        eval "do_${step}=$EXECUTE_ALL_STEPS"
    else
        echo "${flag_name} defined and is ${!flag_name}"
    fi
done

## Internal temporary paths
ROOT_TMP_DIR="${TMP_BASE_PATH}/root/$(_sanitize_string $ROOT_GIT_TAG)"
ROOT_TMP_BUILD_DIR="${TMP_BASE_PATH}/root_build/$(_sanitize_string $ROOT_GIT_TAG)"
ROTOGLUP_TMP_DIR="${TMP_BASE_PATH}/rotoglup"
CLASSLIB_TMP_DIR="${TMP_BASE_PATH}/classlib-3.1.3"
DMWM_TMP_DIR="${TMP_BASE_PATH}/dmwm"
NUMERIC_TMP_DIR="${TMP_BASE_PATH}/numeric"
DQMGUI_TMP_DIR="${TMP_BASE_PATH}/dqmgui"
# Where ROOT will be installed
ROOT_INSTALLATION_DIR="$INSTALLATION_DIR/root/$(_sanitize_string $ROOT_GIT_TAG)"
HOST=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Cleanup if interrupted
trap _cleanup SIGINT

# Go to the installation directory
cd $INSTALLATION_DIR/

# The actual installation procedure.
# For each step, check if the appropriate flag is enabled.
for step in "${installation_steps[@]}"; do

    installation_step_flag_name=do_$step
    if [ "${!installation_step_flag_name}" -ne 0 ]; then
        echo "Installation step: $step"
        # Run the actual function
        eval "$step"
    else
        echo "Skipping step: $step"
    fi

done

echo "INFO: Complete!"
