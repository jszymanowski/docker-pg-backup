#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# Helpers
############################################
monitoring_log() {
  log "[DB Monitoring] $*"
}

notify_monitoring() {
  local status="${1:-unknown}"

  monitoring_log "notify_monitoring called with status=${status}"

  # Command-based monitoring
  if [[ -n "${MONITORING_ENDPOINT_COMMAND:-}" ]]; then
    monitoring_log "notify_monitoring: running MONITORING_ENDPOINT_COMMAND ${MONITORING_ENDPOINT_COMMAND} and status ${status}"
    eval "${MONITORING_ENDPOINT_COMMAND} '${status}'"
    return 0
  fi

  # Script-based monitoring
  if [[ -n "${EXTRA_CONF_DIR:-}" ]] && \
     [[ -f "${EXTRA_CONF_DIR}/backup_monitoring.sh" ]]; then
    monitoring_log "notify_monitoring: running ${EXTRA_CONF_DIR}/backup_monitoring.sh ${status}"
    bash "${EXTRA_CONF_DIR}/backup_monitoring.sh" "${status}"
    return 0
  fi

  # HEALTHCHECKS_URL-based monitoring (e.g., https://hc-ping.com/your-uuid)
  if [[ -n "${HEALTHCHECKS_URL:-}" ]]; then
    if [[ "${status}" == "success" ]]; then
      monitoring_log "notify_monitoring: pinging HEALTHCHECKS_URL"
      curl -fsS -m 10 --retry 3 "${HEALTHCHECKS_URL}" > /dev/null 2>&1 || \
        monitoring_log "notify_monitoring: failed to ping HEALTHCHECKS_URL"
    else
      monitoring_log "notify_monitoring: signaling failure to HEALTHCHECKS_URL"
      curl -fsS -m 10 --retry 3 "${HEALTHCHECKS_URL}/fail" > /dev/null 2>&1 || true
    fi
    return 0
  fi

  # Safe fallback
  monitoring_log "notify_monitoring: no monitoring configured"
  return 0
}