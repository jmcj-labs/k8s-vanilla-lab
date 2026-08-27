#!/usr/bin/env bash

envoy_e2e_verdict() {
  local code="$1" headers_file="$2"
  case "${code}" in
    200) return 0 ;;
    404)
      grep -Eiq '^server:[[:space:]]*envoy([[:space:]]|$)' "${headers_file}"
      ;;
    *) return 1 ;;
  esac
}
