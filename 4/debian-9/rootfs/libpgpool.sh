#!/bin/bash
#
# Bitnami Pgpool library

# shellcheck disable=SC1090
# shellcheck disable=SC1091

# Load Generic Libraries
. /liblog.sh
. /libfs.sh
. /libnet.sh
. /libos.sh
. /libservice.sh
. /libvalidations.sh

########################
# Loads global variables used on pgpool configuration.
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   Series of exports to be used as 'eval' arguments
#########################
pgpool_env() {
    cat <<"EOF"
# Format log messages
MODULE=pgpool

# Paths
export PGPOOL_BASE_DIR="/opt/bitnami/pgpool"
export PGPOOL_DATA_DIR="${PGPOOL_BASE_DIR}/data"
export PGPOOL_CONF_DIR="${PGPOOL_BASE_DIR}/conf"
export PGPOOL_ETC_DIR="${PGPOOL_BASE_DIR}/etc"
export PGPOOL_LOG_DIR="${PGPOOL_BASE_DIR}/logs"
export PGPOOL_TMP_DIR="${PGPOOL_BASE_DIR}/tmp"
export PGPOOL_BIN_DIR="${PGPOOL_BASE_DIR}/bin"
export PGPOOL_CONF_FILE="${PGPOOL_CONF_DIR}/pgpool.conf"
export PGPOOL_PCP_CONF_FILE="${PGPOOL_ETC_DIR}/pcp.conf"
export PGPOOL_PGHBA_FILE="${PGPOOL_CONF_DIR}/pool_hba.conf"
export PGPOOL_PID_FILE="${PGPOOL_TMP_DIR}/pgpool.pid"
export PGPOOL_LOG_FILE="${PGPOOL_LOG_DIR}/pgpool.log"
export PGPOOL_PWD_FILE="pool_passwd"
export PATH="${PGPOOL_BIN_DIR}:$PATH"

# Users
export PGPOOL_DAEMON_USER="pgpool"
export PGPOOL_DAEMON_GROUP="pgpool"

# Settings
export PGPOOL_PORT_NUMBER="${PGPOOL_PORT_NUMBER:-5432}"
export PGPOOL_BACKEND_NODES="${PGPOOL_BACKEND_NODES:-}"
export PGPOOL_SR_CHECK_USER="${PGPOOL_SR_CHECK_USER:-}"
export PGPOOL_POSTGRES_USERNAME="${PGPOOL_POSTGRES_USERNAME:-postgres}"
export PGPOOL_ADMIN_USERNAME="${PGPOOL_ADMIN_USERNAME:-}"
export PGPOOL_ENABLE_LDAP="${PGPOOL_ENABLE_LDAP:-no}"
export PGPOOL_TIMEOUT="360"

# LDAP
export PGPOOL_LDAP_URI="${PGPOOL_LDAP_URI:-}"
export PGPOOL_LDAP_BASE="${PGPOOL_LDAP_BASE:-}"
export PGPOOL_LDAP_BIND_DN="${PGPOOL_LDAP_BIND_DN:-}"
export PGPOOL_LDAP_BIND_PASSWORD="${PGPOOL_LDAP_BIND_PASSWORD:-}"
export PGPOOL_LDAP_BASE_LOOKUP="${PGPOOL_LDAP_BASE_LOOKUP:-}"
export PGPOOL_LDAP_NSS_INITGROUPS_IGNOREUSERS="${PGPOOL_LDAP_NSS_INITGROUPS_IGNOREUSERS:-root,nslcd}"
export PGPOOL_LDAP_SCOPE="${PGPOOL_LDAP_SCOPE:-}"
export PGPOOL_LDAP_TLS_REQCERT="${PGPOOL_LDAP_TLS_REQCERT:-}"

EOF
    if [[ -f "${PGPOOL_ADMIN_PASSWORD_FILE:-}" ]]; then
        cat << "EOF"
export PGPOOL_ADMIN_PASSWORD="$(< "${PGPOOL_ADMIN_PASSWORD_FILE}")"
EOF
    else
        cat << "EOF"
export PGPOOL_ADMIN_PASSWORD="${PGPOOL_ADMIN_PASSWORD:-}"
EOF
    fi
    if [[ -f "${PGPOOL_POSTGRES_PASSWORD_FILE:-}" ]]; then
        cat << "EOF"
export PGPOOL_POSTGRES_PASSWORD="$(< "${PGPOOL_POSTGRES_PASSWORD_FILE}")"
EOF
    else
        cat << "EOF"
export PGPOOL_POSTGRES_PASSWORD="${PGPOOL_POSTGRES_PASSWORD:-}"
EOF
    fi
    if [[ -f "${PGPOOL_SR_CHECK_PASSWORD_FILE:-}" ]]; then
        cat << "EOF"
export PGPOOL_SR_CHECK_PASSWORD="$(< "${PGPOOL_SR_CHECK_PASSWORD_FILE}")"
EOF
    else
        cat << "EOF"
export PGPOOL_SR_CHECK_PASSWORD="${PGPOOL_SR_CHECK_PASSWORD:-}"
EOF
    fi
}

########################
# Validate settings in PGPOOL_* env. variables
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_validate() {
    info "Validating settings in PGPOOL_* env vars..."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }

    if [[ -z "$PGPOOL_ADMIN_USERNAME" ]] || [[ -z "$PGPOOL_ADMIN_PASSWORD" ]]; then
        print_validation_error "The Pgpool administrator user's credentials are mandatory. Set the environment variables PGPOOL_ADMIN_USERNAME and PGPOOL_ADMIN_PASSWORD with the Pgpool administrator user's credentials."
    fi
    if [[ -z "$PGPOOL_SR_CHECK_USER" ]] || [[ -z "$PGPOOL_SR_CHECK_PASSWORD" ]]; then
        print_validation_error "The PostrgreSQL replication credentials are mandatory. Set the environment variables PGPOOL_SR_CHECK_USER and PGPOOL_SR_CHECK_PASSWORD with the PostrgreSQL replication credentials."
    fi
    if is_boolean_yes "$PGPOOL_ENABLE_LDAP" && ( [[ -z "${PGPOOL_LDAP_URI}" ]] || [[ -z "${PGPOOL_LDAP_BASE}" ]] || [[ -z "${PGPOOL_LDAP_BIND_DN}" ]] || [[ -z "${PGPOOL_LDAP_BIND_PASSWORD}" ]] ); then
        print_validation_error "The LDAP configuration is required when LDAP authentication is enabled. Set the environment variables PGPOOL_LDAP_URI, PGPOOL_LDAP_BASE, PGPOOL_LDAP_BIND_DN and PGPOOL_LDAP_BIND_PASSWORD with the LDAP configuration."
    fi
    if [[ -z "$PGPOOL_POSTGRES_USERNAME" ]] || [[ -z "$PGPOOL_POSTGRES_PASSWORD" ]]; then
        print_validation_error "The administrator's database credentials are required. Set the environment variables PGPOOL_POSTGRES_USERNAME and PGPOOL_POSTGRES_PASSWORD with the administrator's database credentials."
    fi
    if [[ -z "$PGPOOL_BACKEND_NODES" ]]; then
        print_validation_error "The list of backend nodes cannot be empty. Set the environment variable PGPOOL_BACKEND_NODES with a comma separated list of backend nodes."
    else
        read -r -a nodes <<< "$(tr ',;' ' ' <<< "${PGPOOL_BACKEND_NODES}")"
        for node in "${nodes[@]}"; do
            read -r -a fields <<< "$(tr ':' ' ' <<< "${node}")"
            if [[ -z "${fields[0]:-}" ]]; then
                print_validation_error "Error checking entry '$node', the field 'backend number' must be set!"
            fi
            if [[ -z "${fields[1]:-}" ]]; then
                print_validation_error "Error checking entry '$node', the field 'host' must be set!"
            fi
        done
    fi

    [[ "$error_code" -eq 0 ]] || exit "$error_code"
}

########################
# Start nslcd in background
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_start_nslcd_bg() {
    info "Starting nslcd service in background..."
    nslcd -d &
}

########################
# Create basic pg_hba.conf file
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_create_pghba() {
    local authentication="md5"
    info "Generating pg_hba.conf file..."

    is_boolean_yes "$PGPOOL_ENABLE_LDAP" && authentication="pam pamservice=pgpool.pam"
    cat > "$PGPOOL_PGHBA_FILE" << EOF
local    all             all                            trust
host     all             $PGPOOL_SR_CHECK_USER       all         trust
host     all             $PGPOOL_POSTGRES_USERNAME       all         md5
host     all             wide               all         trust
host     all             pop_user           all         trust
host     all             all                all         $authentication
EOF
}

########################
# Modify the pgpool.conf file by setting a property
# Globals:
#   PGPOOL_*
# Arguments:
#   $1 - property
#   $2 - value
#   $3 - Path to configuration file (default: $PGPOOL_CONF_FILE)
# Returns:
#   None
#########################
pgpool_set_property() {
    local -r property="${1:?missing property}"
    local -r value="${2:-}"
    local -r conf_file="${3:-$PGPOOL_CONF_FILE}"
    sed -i "s?^#*\s*${property}\s*=.*?${property} = ${value}?g" "$conf_file"
}

########################
# Add a backend configuration to pgpool.conf file
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_create_backend_config() {
    local -r node=${1:?node is missing}
    local -r retries=5
    local -r sleep_time=3

    # default values
    read -r -a fields <<< "$(tr ':' ' ' <<< "${node}")"
    local -r num="${fields[0]:?field num is needed}"
    local -r host="${fields[1]:?field host is needed}"
    local -r port="${fields[2]:-5432}"
    local -r weight="${fields[3]:-1}"
    local -r dir="${fields[4]:-$PGPOOL_DATA_DIR}"
    local -r flag="${fields[5]:-ALLOW_TO_FAILOVER}"

    #check if it is possible to connect to the node
    debug "Waiting for backend '$host' ..."
    if ! retry_while "is_hostname_resolved $host" "$retries" "$sleep_time"; then
        error "$host is not a resolved hostname"
        exit 1
    fi
    if wait-for-port --host "$host" --timeout "$PGPOOL_TIMEOUT" "$port"; then
        debug "Backend '$host' is ready. Adding its information to the configuration..."
        cat >> "$PGPOOL_CONF_FILE" << EOF
backend_hostname$num = '$host'
backend_port$num = $port
backend_weight$num = $weight
backend_data_directory$num = '$dir'
backend_flag$num = '$flag'
EOF
    else
        error "Backend $host did not respond after $PGPOOL_TIMEOUT seconds!"
        exit 1
    fi
}

########################
#  Create basic pgpool.conf file using the example provided in the etc/ folder
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_create_config() {
    local -i node_counter=0

    info "Generating pgpool.conf file..."
    # Configuring Pgpool-II to use the streaming replication mode since it's the recommended way
    # ref: http://www.pgpool.net/docs/latest/en/html/configuring-pgpool.html
    cp "${PGPOOL_BASE_DIR}/etc/pgpool.conf.sample-stream" "$PGPOOL_CONF_FILE"

    # Connection settings
    # ref: http://www.pgpool.net/docs/latest/en/html/runtime-config-connection.html#RUNTIME-CONFIG-CONNECTION-SETTINGS
    pgpool_set_property "listen_addresses" "'*'"
    pgpool_set_property "port" "'$PGPOOL_PORT_NUMBER'"
    pgpool_set_property "socket_dir" "'$PGPOOL_TMP_DIR'"
    # Communication Manager Connection settings
    pgpool_set_property "pcp_socket_dir" "'$PGPOOL_TMP_DIR'"
    # Authentication settings
    # ref: http://www.pgpool.net/docs/latest/en/html/runtime-config-connection.html#RUNTIME-CONFIG-AUTHENTICATION-SETTINGS
    pgpool_set_property "enable_pool_hba" "off"
    pgpool_set_property "allow_clear_text_frontend_auth" "on"
    pgpool_set_property "pool_passwd" "''"
    pgpool_set_property "authentication_timeout" "'30'"
    # Connection Pooling settings
    # http://www.pgpool.net/docs/latest/en/html/runtime-config-connection-pooling.html
    pgpool_set_property "max_pool" "'15'"
    # File Locations settings
    pgpool_set_property "pid_file_name" "'$PGPOOL_PID_FILE'"
    pgpool_set_property "logdir" "'$PGPOOL_LOG_DIR'"
    # Load Balancing settings
    pgpool_set_property "load_balance_mode" "'on'"
    pgpool_set_property "black_function_list" "'nextval,setval'"
    # Streaming settings
    pgpool_set_property "sr_check_user" "'$PGPOOL_SR_CHECK_USER'"
    pgpool_set_property "sr_check_password" "'$PGPOOL_SR_CHECK_PASSWORD'"
    pgpool_set_property "sr_check_period" "'30'"
    # Healthcheck per node settings
    pgpool_set_property "health_check_period" "'30'"
    pgpool_set_property "health_check_timeout" "'10'"
    pgpool_set_property "health_check_user" "'$PGPOOL_SR_CHECK_USER'"
    pgpool_set_property "health_check_password" "'$PGPOOL_SR_CHECK_PASSWORD'"
    pgpool_set_property "health_check_max_retries" "'5'"
    pgpool_set_property "health_check_retry_delay" "'5'"
    # Failover settings
    pgpool_set_property "failover_command" "'echo \">>> Failover - that will initialize new primary node search!\"'"
    pgpool_set_property "failover_on_backend_error" "'off'"
    # Keeps searching for a primary node forever when a failover occurs
    pgpool_set_property "search_primary_node_timeout" "'0'"

    # Backend settings
    read -r -a nodes <<< "$(tr ',;' ' ' <<< "${PGPOOL_BACKEND_NODES}")"
    for node in "${nodes[@]}"; do
        pgpool_create_backend_config "$node"
    done
}

########################
# Configure LDAP connections
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_ldap_config() {
    local openldap_conf
    info "Configuring LDAP connection..."

    cat > "/etc/pam.d/pgpool.pam" << EOF
auth     required  pam_ldap.so  try_first_pass debug
account  required  pam_ldap.so  debug
EOF
    cat >> "/etc/nslcd.conf" << EOF
# Configuration added for pgpool
nss_initgroups_ignoreusers $PGPOOL_LDAP_NSS_INITGROUPS_IGNOREUSERS
uri $PGPOOL_LDAP_URI
base $PGPOOL_LDAP_BASE
binddn $PGPOOL_LDAP_BIND_DN
bindpw $PGPOOL_LDAP_BIND_PASSWORD
EOF
    if [[ -n "${PGPOOL_LDAP_BASE_LOOKUP}" ]]; then
        cat >> "/etc/nslcd.conf" << EOF
base passwd $PGPOOL_LDAP_BASE_LOOKUP
EOF
    fi
    if [[ -n "${PGPOOL_LDAP_SCOPE}" ]]; then
        cat >> "/etc/nslcd.conf" << EOF
scope $PGPOOL_LDAP_SCOPE
EOF
    fi
    if [[ -n "${PGPOOL_LDAP_TLS_REQCERT}" ]]; then
            cat >> "/etc/nslcd.conf" << EOF
tls_reqcert $PGPOOL_LDAP_TLS_REQCERT
EOF
    fi
    chmod 600 /etc/nslcd.conf

    case "$OS_FLAVOUR" in
        debian-*) openldap_conf=/etc/ldap/ldap.conf ;;
        centos-*|rhel-*|ol-*) openldap_conf=/etc/openldap/ldap.conf ;;
        *) ;;
    esac
    cat >>"${openldap_conf}"<<EOF
BASE $PGPOOL_LDAP_BASE
URI $PGPOOL_LDAP_URI
EOF
}

########################
# Generates a password file for local authentication
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_generate_password_file() {
    info "Generating password file for local authentication..."

    pg_md5 -m --config-file="$PGPOOL_CONF_FILE" -u "$PGPOOL_POSTGRES_USERNAME" "$PGPOOL_POSTGRES_PASSWORD"
}

########################
# Generate a password file for pgpool admin user
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_generate_admin_password_file() {
    info "Generating password file for pgpool admin user..."
    local passwd

    passwd=$(pg_md5 "$PGPOOL_ADMIN_PASSWORD")
    cat >>"$PGPOOL_PCP_CONF_FILE"<<EOF
$PGPOOL_ADMIN_USERNAME:$passwd
EOF
}

########################
# Ensure Pgpool is initialized
# Globals:
#   PGPOOL_*
# Arguments:
#   None
# Returns:
#   None
#########################
pgpool_initialize() {
    info "Initializing Pgpool-II..."

    # This fixes an issue where the trap would kill the entrypoint.sh, if a PID was left over from a previous run
    # Exec replaces the process without creating a new one, and when the container is restarted it may have the same PID
    rm -f "$PGPOOL_PID_FILE"

    # Configuring permissions for tmp, logs and data folders
    am_i_root && configure_permissions_ownership "$PGPOOL_TMP_DIR $PGPOOL_LOG_DIR" -u "$PGPOOL_DAEMON_USER" -g "$PGPOOL_DAEMON_GROUP"
    am_i_root && configure_permissions_ownership "$PGPOOL_DATA_DIR" -u "$PGPOOL_DAEMON_USER" -g "$PGPOOL_DAEMON_GROUP" -d "755" -f "644"

    if [[ -f "$PGPOOL_CONF_FILE" ]]; then
        info "Custom configuration $PGPOOL_CONF_FILE detected!"
    else
        info "No injected configuration files found. Creating default config files..."
        pgpool_create_pghba
        pgpool_create_config
        if is_boolean_yes "$PGPOOL_ENABLE_LDAP"; then
            pgpool_ldap_config
        fi
        pgpool_generate_password_file
        pgpool_generate_admin_password_file
    fi
}
