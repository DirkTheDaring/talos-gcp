#!/bin/bash

# --- Phase 4: Scheduling (Cost Optimization) ---

update_schedule() {
    set_names
    # check_dependencies - Not needed

    log "Updating Cluster Schedule..."
    log "  Start Time: ${WORK_HOURS_START:-(Unset)}"
    log "  Stop Time:  ${WORK_HOURS_STOP:-(Unset)}"
    log "  Days:       ${WORK_HOURS_DAYS} (${WORK_HOURS_TIMEZONE})"
    
    # 1. Determine Desired State
    if [ -n "${WORK_HOURS_START}" ] && [ -n "${WORK_HOURS_STOP}" ]; then
        # Enable Schedule
        ensure_schedule_policy
        attach_schedule_to_instances
    else
        # Disable Schedule
        if gcloud compute resource-policies describe "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
            log "Work hours unset. Removing schedule..."
            detach_schedule_from_instances
            delete_schedule_policy
        else
            log "Schedule not active. No action needed."
        fi
    fi
}

ensure_schedule_policy() {
    log "Ensuring Resource Policy '${SCHEDULE_POLICY_NAME}' exists..."
    
    # Parse Days into Cron Format
    # GCP Format: --vm-start-schedule="0 8 * * 1-5" (Min Hour DayOfMonth Month DayOfWeek)
    # Note: GCP might use a specific cron flavor.
    # The gcloud help says: "CRON expression ... UTC time zone ... OR ... provide --timezone"
    
    local CRON_DAYS
    case "${WORK_HOURS_DAYS}" in
        "Mon-Fri") CRON_DAYS="1-5" ;;
        "Mon-Sat") CRON_DAYS="1-6" ;;
        "Sun-Sat"|"Everyday"|"Daily") CRON_DAYS="0-6" ;; # 0=Sunday
        *)
            # Valid Custom: "1,3,5" or "1-5"
            # If it looks like a cron range/list, accept it.
            if [[ "${WORK_HOURS_DAYS}" =~ ^[0-6,\-]+$ ]]; then
                CRON_DAYS="${WORK_HOURS_DAYS}"
            else
                warn "Unknown WORK_HOURS_DAYS format '${WORK_HOURS_DAYS}'. Defaulting to Mon-Fri (1-5)."
                CRON_DAYS="1-5"
            fi
            ;;
    esac
    
    # Parse Start/Stop Times (HH:MM)
    local START_H START_M
    IFS=':' read -r START_H START_M <<< "${WORK_HOURS_START}"
    
    local STOP_H STOP_M
    IFS=':' read -r STOP_H STOP_M <<< "${WORK_HOURS_STOP}"
    
    # Basic Validation
    if [[ -z "$START_H" || -z "$STOP_H" ]]; then
        error "Invalid Time Format. Use HH:MM (e.g. 08:00)."
        exit 1
    fi
    
    # Construct Cron Expressions
    # "MM HH * * DAYS"
    local START_CRON="${START_M} ${START_H} * * ${CRON_DAYS}"
    local STOP_CRON="${STOP_M} ${STOP_H} * * ${CRON_DAYS}"
    
    # Check if Policy Exists
    if gcloud compute resource-policies describe "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        # Update is limited for Instance Schedules. 
        # Easier to recreate if we want to change times, OR use `update instance-schedule`
        
        log "Updating existing schedule..."
        run_safe gcloud compute resource-policies update instance-schedule "${SCHEDULE_POLICY_NAME}" \
            --region="${REGION}" \
            --vm-start-schedule="${START_CRON}" \
            --vm-stop-schedule="${STOP_CRON}" \
            --timezone="${WORK_HOURS_TIMEZONE}" \
            --project="${PROJECT_ID}"
    else
        log "Creating new schedule..."
        run_safe gcloud compute resource-policies create instance-schedule "${SCHEDULE_POLICY_NAME}" \
            --region="${REGION}" \
            --vm-start-schedule="${START_CRON}" \
            --vm-stop-schedule="${STOP_CRON}" \
            --timezone="${WORK_HOURS_TIMEZONE}" \
            --project="${PROJECT_ID}"
            
        log "Schedule created."
    fi
}

delete_schedule_policy() {
    log "Deleting Resource Policy '${SCHEDULE_POLICY_NAME}'..."
    run_safe gcloud compute resource-policies delete "${SCHEDULE_POLICY_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
}

attach_schedule_to_instances() {
    log "Attaching schedule to cluster instances..."
    
    # Batch check all instances and their current policies
    # Output format: NAME;POLICIES
    local INSTANCE_DATA
    INSTANCE_DATA=$(gcloud compute instances list \
        --filter="zone:(${ZONE}) AND (labels.cluster=${CLUSTER_NAME} OR name:${BASTION_NAME})" \
        --format="value(name,resourcePolicies)" \
        --project="${PROJECT_ID}")
    
    if [ -z "$INSTANCE_DATA" ]; then
        warn "No instances found to schedule."
        return
    fi
    
    # Iterate line by line
    while read -r line; do
        if [ -z "$line" ]; then continue; fi
        
        # Split by tab (default separator)
        # value(a,b) usually separates by tab? Or we can force separator.
        # check format. gcloud value(a,b) is tab separated.
        local instance_name policy_string
        read -r instance_name policy_string <<< "$line"
        
        if [[ "$policy_string" =~ (^|/|,|;)"${SCHEDULE_POLICY_NAME}"($|/|,|;) ]]; then
            # info "Instance ${instance_name} already has schedule."
            :
        else
            log "Attaching to ${instance_name}..."
            # This runs sequentially, but only for targets needing update.
            # Parallelization would be better but this is already much fewer calls.
            run_safe gcloud compute instances add-resource-policies "${instance_name}" \
                --resource-policies="${SCHEDULE_POLICY_NAME}" \
                --zone="${ZONE}" \
                --project="${PROJECT_ID}"
        fi
    done <<< "$INSTANCE_DATA"
}

detach_schedule_from_instances() {
    log "Detaching schedule from cluster instances..."
    
    local INSTANCES
    INSTANCES=$(gcloud compute instances list --filter="zone:(${ZONE}) AND (labels.cluster=${CLUSTER_NAME} OR name:${BASTION_NAME}) AND resourcePolicies:${SCHEDULE_POLICY_NAME}" --format="value(name)" --project="${PROJECT_ID}")
    
    if [ -z "$INSTANCES" ]; then
        log "No instances have this schedule attached."
        return
    fi
    
    for instance in $INSTANCES; do
        log "Detaching from ${instance}..."
        run_safe gcloud compute instances remove-resource-policies "${instance}" \
            --resource-policies="${SCHEDULE_POLICY_NAME}" \
            --zone="${ZONE}" \
            --project="${PROJECT_ID}"
    done
}
