#!/bin/bash

# MySQL Database Backup Script - Jenkins Optimized Version
# Performs automated database dumps with user count validation
# Designed for Jenkins pipeline execution on remote VMs
# Author: DevOps Team
# Version: 3.0

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration from Jenkins environment variables
readonly MYSQL_HOST="${MYSQL_HOST:-localhost}"
readonly MYSQL_PORT="${MYSQL_PORT:-3306}"
readonly DOCKER_CONTAINER="${DOCKER_CONTAINER:-ugp-mariadb}"
readonly DATABASES=(${DATABASES:-"Accounts Content Gifting H5CGame Orders Sigma UGPCampaign UGPGroup club5"})
readonly BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-5}"
readonly GCP_BUCKET_BASE="${GCP_BUCKET_BASE:-gs://qxx-mysqldump}"
readonly USER_COUNT_VALIDATION="${USER_COUNT_VALIDATION:-true}"
readonly SYNC_CONSISTENCY_CHECK="${SYNC_CONSISTENCY_CHECK:-true}"

# Jenkins workspace paths
readonly WORKSPACE_DIR="${WORKSPACE:-$(pwd)}"
readonly BACKUP_DIR="${WORKSPACE_DIR}/backups"
readonly USER_COUNT_DIR="${WORKSPACE_DIR}/user_counts"

# MySQL dump options
readonly MYSQLDUMP_OPTIONS=("--single-transaction" "--quick" "--lock-tables=false")

# Simple logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    exit 1
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"
}

# Cleanup function
cleanup_on_exit() {
    log_info "Backup process completed"
}

# Trap to ensure cleanup on script exit
trap cleanup_on_exit EXIT

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check required commands
    local required_commands=("docker" "gcloud" "gsutil" "gzip")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            log_error "Required command '$cmd' not found"
        fi
    done
    
    # Check GCP authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        log_error "GCP authentication required - ensure Jenkins has proper service account"
    fi
    
    # Set GCP project if provided
    if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
        gcloud config set project "${GCP_PROJECT_ID}" || log_error "Failed to set GCP project"
    fi
    
    log_info "Prerequisites check passed"
}

# Get user count from database
get_user_count() {
    local mysql_user="$1"
    local mysql_pass="$2"
    
    log_info "Getting user count from database..."
    
    local user_count
    if [[ -n "${DOCKER_CONTAINER:-}" ]]; then
        # Use Docker container
        user_count=$(docker exec -i "$DOCKER_CONTAINER" mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$mysql_user" -p"$mysql_pass" \
            --batch --skip-column-names --execute="SELECT COUNT(1) FROM Accounts.User" 2>/dev/null || echo "0")
    else
        # Direct MySQL connection
        user_count=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$mysql_user" -p"$mysql_pass" \
            --batch --skip-column-names --execute="SELECT COUNT(1) FROM Accounts.User" 2>/dev/null || echo "0")
    fi
    
    if [[ "$user_count" =~ ^[0-9]+$ ]]; then
        echo "$user_count"
    else
        log_error "Failed to get valid user count from database"
    fi
}

# Validate user count
validate_user_count() {
    local new_count="$1"
    local old_count_file="$2"
    
    # Skip validation if disabled
    if [[ "${USER_COUNT_VALIDATION}" != "true" ]]; then
        log_info "User count validation disabled"
        return 0
    fi
    
    log_info "Validating user count: new=$new_count"
    
    if [[ ! -f "$old_count_file" ]]; then
        log_warn "No previous user count file found, creating initial count"
        echo "$new_count" > "$old_count_file"
        return 0
    fi
    
    local old_count
    old_count=$(cat "$old_count_file" 2>/dev/null || echo "0")
    
    log_info "Previous user count: $old_count, Current user count: $new_count"
    
    if [[ "$new_count" -ge "$old_count" ]]; then
        log_info "User count validation passed"
        return 0
    else
        log_error "User count decreased from $old_count to $new_count - backup aborted"
    fi
}

# Create database dump
create_database_dump() {
    local mysql_user="$1"
    local mysql_pass="$2"
    local dump_file="$3"
    
    log_info "Creating database dump: $dump_file"
    
    # Ensure dump directory exists
    mkdir -p "$(dirname "$dump_file")"
    
    # Use databases from config
    if [[ -n "${DOCKER_CONTAINER:-}" ]]; then
        # Use Docker container
        docker exec "$DOCKER_CONTAINER" /usr/bin/mysqldump \
            -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$mysql_user" -p"$mysql_pass" \
            --databases "${DATABASES[@]}" \
            "${MYSQLDUMP_OPTIONS[@]}" \
            > "$dump_file" 2>/dev/null || log_error "Failed to create database dump"
    else
        # Direct mysqldump
        mysqldump \
            -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$mysql_user" -p"$mysql_pass" \
            --databases "${DATABASES[@]}" \
            "${MYSQLDUMP_OPTIONS[@]}" \
            > "$dump_file" 2>/dev/null || log_error "Failed to create database dump"
    fi
    
    # Verify dump file
    if [[ ! -f "$dump_file" ]] || [[ ! -s "$dump_file" ]]; then
        log_error "Database dump file is empty or was not created"
    fi
    
    local dump_size=$(du -h "$dump_file" | cut -f1)
    log_info "Database dump created successfully: $dump_file (${dump_size})"
}

# Compress dump file with performance optimization
compress_dump() {
    local dump_file="$1"
    local compressed_file="${dump_file}.gz"
    
    log_info "Compressing dump file..."
    
    # Use pigz if available for parallel compression, fallback to gzip
    if command -v pigz > /dev/null 2>&1; then
        pigz -f "$dump_file" || log_error "Failed to compress dump file with pigz"
    else
        gzip -f "$dump_file" || log_error "Failed to compress dump file"
    fi
    
    log_info "Dump file compressed: $compressed_file"
    echo "$compressed_file"
}

# Cleanup old backups
cleanup_old_backups() {
    local backup_dir="$1"
    local retention_days="${BACKUP_RETENTION_DAYS}"
    
    log_info "Cleaning up backups older than ${retention_days} days..."
    
    local deleted_count=0
    while IFS= read -r -d '' file; do
        if rm "$file"; then
            log_info "Deleted old backup: $(basename "$file")"
            ((deleted_count++))
        fi
    done < <(find "$backup_dir" -name "*.sql.gz" -type f -mtime +"$retention_days" -print0)
    
    log_info "Cleanup completed: $deleted_count files deleted"
}

# Sync to GCS with performance optimization
sync_to_gcs() {
    local local_dir="$1"
    local gcs_bucket="$2"
    
    log_info "Syncing backups to GCS: $gcs_bucket"
    
    # Use GCS performance settings
    local gsutil_opts=("-m" "rsync" "-d" "-r")
    
    # Add parallel upload settings if available
    if [[ -n "${GCS_PARALLEL_COMPOSITE_UPLOAD_THRESHOLD:-}" ]]; then
        gsutil_opts+=("-o" "GSUtil:parallel_composite_upload_threshold=${GCS_PARALLEL_COMPOSITE_UPLOAD_THRESHOLD}")
    fi
    
    if [[ -n "${GCS_MAX_CONCURRENT_STREAMS:-}" ]]; then
        gsutil_opts+=("-o" "GSUtil:parallel_thread_count=${GCS_MAX_CONCURRENT_STREAMS}")
    fi
    
    if gsutil "${gsutil_opts[@]}" "$local_dir" "$gcs_bucket"; then
        log_info "GCS sync completed successfully"
    else
        log_error "Failed to sync to GCS"
    fi
}

# Verify sync consistency
verify_sync_consistency() {
    local local_dir="$1"
    local gcs_bucket="$2"
    
    # Skip verification if disabled
    if [[ "${SYNC_CONSISTENCY_CHECK}" != "true" ]]; then
        log_info "Sync consistency check disabled"
        return 0
    fi
    
    log_info "Verifying sync consistency..."
    
    local local_count
    local gcs_count
    
    # Count local files
    local_count=$(find "$local_dir" -name "*.sql.gz" -type f | wc -l)
    
    # Count GCS files
    gcs_count=$(gsutil ls "$gcs_bucket"/*.sql.gz 2>/dev/null | wc -l)
    
    log_info "Local files: $local_count, GCS files: $gcs_count"
    
    if [[ "$local_count" -eq "$gcs_count" ]]; then
        log_info "Sync consistency verification passed"
        return 0
    else
        log_error "Sync consistency check failed"
    fi
}

# Main function - simplified for Jenkins
main() {
    # Check required arguments
    if [[ $# -ne 3 ]]; then
        log_error "Usage: $0 <environment> <mysql_user> <mysql_password>"
    fi
    
    local environment="$1"
    local mysql_user="$2"
    local mysql_pass="$3"
    
    log_info "Starting database backup for environment: $environment"
    
    # Check prerequisites
    check_prerequisites
    
    # Set up variables
    local date_stamp=$(date '+%Y%m%d_%H%M%S')
    local dump_file="${BACKUP_DIR}/${date_stamp}_${environment}_backup.sql"
    local user_count_file="${USER_COUNT_DIR}/${environment}_user_count.txt"
    local gcs_bucket="${GCP_BUCKET_BASE}/${environment}"
    
    # Create necessary directories
    mkdir -p "${BACKUP_DIR}" "${USER_COUNT_DIR}"
    
    # Get current user count
    local current_user_count
    current_user_count=$(get_user_count "$mysql_user" "$mysql_pass")
    
    # Validate user count
    validate_user_count "$current_user_count" "$user_count_file"
    
    # Create database dump
    create_database_dump "$mysql_user" "$mysql_pass" "$dump_file"
    
    # Compress dump
    local compressed_file
    compressed_file=$(compress_dump "$dump_file")
    
    # Cleanup old backups
    cleanup_old_backups "${BACKUP_DIR}"
    
    # Sync to GCS
    sync_to_gcs "${BACKUP_DIR}" "$gcs_bucket"
    
    # Verify sync consistency
    verify_sync_consistency "${BACKUP_DIR}" "$gcs_bucket"
    
    # Update user count file
    echo "$current_user_count" > "$user_count_file"
    
    # Success message
    local backup_size=$(du -h "$compressed_file" | cut -f1)
    log_info "Database backup completed successfully"
    log_info "Backup file: $compressed_file"
    log_info "Backup size: $backup_size"
}

# Run main function with all arguments
main "$@"
