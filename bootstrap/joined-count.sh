#!/usr/bin/env bash
# Pure decision helpers injected into control-plane-join.yaml by templatefile.
# Keep this file ASCII-only: it becomes part of the cloud-init payload.

ssm_read_kind() {
  local rc="$1" output="$2"
  if [ "${rc}" -eq 0 ]; then
    printf '%s\n' present
  elif printf '%s\n' "${output}" | grep -q 'ParameterNotFound'; then
    printf '%s\n' absent
  else
    printf '%s\n' error
  fi
}

joined_count_decision() {
  local value="$1" cp_index="$2" cluster_size="$3" required
  case "${value}" in
    ''|*[!0-9]*) printf '%s\n' invalid; return 2 ;;
  esac
  case "${cp_index}" in
    ''|*[!0-9]*) printf '%s\n' invalid; return 2 ;;
  esac
  case "${cluster_size}" in
    ''|*[!0-9]*|0) printf '%s\n' invalid; return 2 ;;
  esac
  if [ "${value}" -gt "${cluster_size}" ] || [ "${cp_index}" -ge "${cluster_size}" ]; then
    printf '%s\n' invalid
    return 2
  fi

  required="${cp_index}"
  if [ "${required}" -lt 1 ]; then
    required=1
  fi
  if [ "${value}" -ge "${required}" ]; then
    printf '%s\n' proceed
  else
    printf '%s\n' wait
  fi
}
