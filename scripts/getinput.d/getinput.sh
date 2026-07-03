#!/usr/bin/env bash
set -euo pipefail
trap 'echo; echo "Interrupted by user. Exiting..."; exit 130' INT

collect_input_with_confirm(){
  local prompt_text="$1"
  local default_val="$2"
  local visibility_mode="$3"
  local initial_text="${4-}"
  local show_prompt="${5-true}"
  local require_confirm="${6-false}"
  local show_confirmation_text="${7-true}"
  local empty_allowed="${8-true}"
  local first second

  while true; do
    first=$(read_line_with_visibility "$prompt_text" "$default_val" "$visibility_mode" "$initial_text" "$show_prompt" "$show_confirmation_text")
    first="${first%$'\n'}"

    if [ "$empty_allowed" != "true" ] && [ -z "$first" ]; then
      # Ask user whether to retry or skip
      local choice
      printf "Input cannot be empty. retry [ENTER] or skip [s]: " >&2
      IFS= read -rsN1 choice 2>/dev/null || true
      printf "\n" >&2
      case "$choice" in
        "" )
          # retry outer loop
          initial_text=""
          show_prompt="true"
          ;;
        "s"|"S")
          # indicate skip to caller with special exit code 200
          return 200
          ;;
        *)
          # any other key behaves like retry
          initial_text=""
          show_prompt="true"
          ;;
      esac
      continue
    fi

    if [ "$require_confirm" != "true" ]; then
      printf "%s\n" "$first"
      return 0
    fi
    second=$(read_line_with_visibility "Confirm $prompt_text" "$default_val" "$visibility_mode" "" "true" "$show_confirmation_text")
    second="${second%$'\n'}"
    if [ "$second" = "$first" ]; then
      printf "%s\n" "$first"
      return 0
    fi
    printf "Inputs do not match. Please try again.\n" >&2
    initial_text=""
    show_prompt="true"
  done
}

show_confirmation(){
  local mode="$1"
  local final_value="$2"
  local typed_len="${3-0}"
  local used_default="${4-false}"
  local confirmation

  if [ "$mode" = "dotted" ]; then
    if [ "$used_default" = "true" ]; then
      if [ -n "$final_value" ]; then
        confirmation="[default applied]"
      else
        confirmation="Input taken: (empty)"
      fi
    elif [ "$typed_len" -gt 0 ]; then
      local dots
      dots=$(printf "%${typed_len}s" "" | tr ' ' '*')
      confirmation="Input taken: ${dots}"
    else
      confirmation="Input taken: (empty)"
    fi
  else
    if [ -n "$final_value" ]; then
      confirmation="Input taken: $final_value"
    else
      confirmation="Input taken: (empty)"
    fi
  fi

  printf "%s\n" "$confirmation" >&2
}

read_line_with_visibility(){
  local prompt_text="$1"
  local default_val="$2"
  local mode="${3-visible}"
  local initial="${4-}"
  local show_prompt="${5-true}"
  local show_confirmation_text="${6-true}"
  local input="$initial"
  local ch rest

  if [ "$show_prompt" = "true" ]; then
    if [ -n "$default_val" ]; then
      printf "%s: [%s] " "$prompt_text" "$default_val" >&2
    else
      printf "%s: " "$prompt_text" >&2
    fi
  fi

  if [ -n "$initial" ]; then
    if [ "$mode" = "dotted" ]; then
      printf "%${#initial}s" "" | tr ' ' '*' >&2
    else
      printf "%s" "$initial" >&2
    fi
  fi

  while true; do
    IFS= read -rsN1 ch || true
    case "$ch" in
      $'\x03')
        printf "\n" >&2
        exit 130
        ;;
      $'\n'|$'\r')
        local final_value used_default
        local typed_len=${#input}
        if [ -z "$input" ]; then
          final_value="$default_val"
          used_default="true"
        else
          final_value="$input"
          used_default="false"
        fi
        printf "\r\033[K" >&2
        if [ "$show_confirmation_text" = "true" ]; then
          show_confirmation "$mode" "$final_value" "$typed_len" "$used_default"
        fi
        printf "%s\n" "$final_value"
        return 0
        ;;
      $'\x7f'|$'\b')
        if [ -n "$input" ]; then
          input=${input%?}
          printf "\b \b" >&2
        fi
        ;;
      $'\e')
        read -rsn2 -t 0.01 rest 2>/dev/null || true
        ;;
      '')
        ;;
      *)
        input+="$ch"
        if [ "$mode" = "dotted" ]; then
          printf "*" >&2
        else
          printf "%s" "$ch" >&2
        fi
        ;;
    esac
  done
}

getInput(){
  local prompt_text="$1"
  local default_val="${2-}"
  local timeout_sec="${3-10}"
  local visibility_mode="${4-visible}"
  local confirm_required="${5-false}"
  local show_confirmation_text="${6-true}"
  local empty_allowed="${7-true}"
  local seconds header key rest input
  header="$prompt_text"
  [ -n "$default_val" ] && header+=" [$default_val]"
  printf "%s\n" "$header" >&2

  # If timeout_sec is 0, wait indefinitely (no countdown display) for a key
  # This preserves the existing key-driven behavior: Enter/Space -> accept
  # default; Esc -> open full input; other key -> start input with that
  # initial character. Other flags (confirm_required, show_confirmation_text,
  # empty_allowed) are still honored via collect_input_with_confirm.
  if [ "$timeout_sec" -eq 0 ]; then
    while true; do
      if read -rsn1 key 2>/dev/null; then
        case "$key" in
          $'\x03') printf "\n" >&2; exit 130 ;;
          $'\n'|$'\r'|$' ') printf "\r\033[K" >&2; if [ "$show_confirmation_text" = "true" ]; then show_confirmation "$visibility_mode" "$default_val" 0 true; fi; printf "%s\n" "${default_val}"; return 0 ;;
          $'\e') read -rsn2 -t 0.01 rest 2>/dev/null || true; printf "\r\033[K" >&2; collect_input_with_confirm "$prompt_text" "$default_val" "$visibility_mode" "" "false" "$confirm_required" "$show_confirmation_text" "$empty_allowed"; return 0 ;;
          *) printf "\r\033[K" >&2; collect_input_with_confirm "$prompt_text" "$default_val" "$visibility_mode" "$key" "false" "$confirm_required" "$show_confirmation_text" "$empty_allowed"; return 0 ;;
        esac
      fi
    done
  fi

  seconds=$((timeout_sec))
  while [ $seconds -ge 0 ]; do
    printf "\r\033[Kmoving on in %ds" "$seconds" >&2
    if read -rsn1 -t 1 key 2>/dev/null; then
      case "$key" in
        $'\x03') printf "\n" >&2; exit 130 ;;
        $'\n'|$'\r'|$' ') printf "\r\033[K" >&2; if [ "$show_confirmation_text" = "true" ]; then show_confirmation "$visibility_mode" "$default_val" 0 true; fi; printf "%s\n" "${default_val}"; return 0 ;;
        $'\e') read -rsn2 -t 0.01 rest 2>/dev/null || true; printf "\r\033[K" >&2; collect_input_with_confirm "$prompt_text" "$default_val" "$visibility_mode" "" "false" "$confirm_required" "$show_confirmation_text" "$empty_allowed"; return 0 ;;
        *) printf "\r\033[K" >&2; collect_input_with_confirm "$prompt_text" "$default_val" "$visibility_mode" "$key" "false" "$confirm_required" "$show_confirmation_text" "$empty_allowed"; return 0 ;;
      esac
    fi
    seconds=$((seconds - 1))
  done
  printf "\r\033[K" >&2
  if [ "$show_confirmation_text" = "true" ]; then
    show_confirmation "$visibility_mode" "$default_val" 0 true
  fi
  printf "%s\n" "$default_val"
}