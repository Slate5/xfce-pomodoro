#!/bin/bash

# LOG related globals
declare -g LOG
declare -g PROJECT
declare -g DEBUG
declare -g NOTIFY_ONLY
declare -g DIR="$(dirname $0)"
declare -g DATE="$(date +%F)"
declare -g LOG_MSG='Work sessions today%s:'

# notify-send related globals
declare -g TIME_FRAME_MSG
declare -g GOAL_DATE="${DATE}"
declare -g ICON='xfce-pomodoro'
declare -gi WEEKEND_SESSIONS
declare -gi SESSION_GOAL=0
declare -gi SESSIONS_DONE=0

check_dependencies() {
    for cmd in getopt awk notify-send paplay sed tac grep seq; do
        if ! command -v ${cmd} &>/dev/null; then
            abort_msg "Command not found: ${cmd}"
        fi
    done

    if command -v fc-list &>/dev/null; then
        if ! fc-list | grep -qi emoji; then
            abort_msg 'Pomodoro wants emoji ;(, are they installed?'
        fi
    fi
}

help_text() {
	cat <<-'EOF'
		HELP!!!
	EOF
}

abort_msg() {
    # Assign msg and exit code with args or default values
    local msg="${1:-Unknown error}"
    local exit_code=${2:-1}

    printf -- '\033[1;31m%s\033[m\n\n' "${msg}" >&2
    help_text

    exit ${exit_code}
}

parse_args() {
    local args exit_code

    args="$(getopt -o d:wms:p:nh \
                   -l day:,week,month,sessions:,project: \
                   -l weekend-sessions:,notify,help \
                   -n "$(basename "${0}")" -- "${@}")"

    if (( (exit_code=$?) != 0 )); then
        help_text
        exit ${exit_code}
    fi

    eval set -- "${args}"

    while :; do
        case "${1}" in
            '-d'|'--day')
                if [ -n "${TIME_FRAME_MSG}" ]; then
                    abort_msg 'Time frame can be specified only once' 22
                elif [[ ! ${2} =~ ^[0-9]+$ ]] || (( ${2} == 0 )); then
                    abort_msg 'Number of days has to be an integer bigger than 0' 22
                fi

                if (( ${2} == 1 )); then
                    TIME_FRAME_MSG='today'
                else
                    TIME_FRAME_MSG="in the last ${2} days"
                    GOAL_DATE="$(date +%F -d "${2} days ago")"
                fi
                shift 2
                ;;
            '-w'|'--week')
                if [ -n "${TIME_FRAME_MSG}" ]; then
                    abort_msg 'Time frame can be specified only once' 22
                fi

                TIME_FRAME_MSG='within this week'
                GOAL_DATE="$(date +%F -d 'last Sunday +1 day')"
                shift
                ;;
            '-m'|'--month')
                if [ -n "${TIME_FRAME_MSG}" ]; then
                    abort_msg 'Time frame can be specified only once' 22
                fi

                TIME_FRAME_MSG="in $(date +%B)"
                GOAL_DATE="$(date +%Y-%m-01)"
                shift
                ;;
            '-s'|'--sessions')
                if [[ ! ${2} =~ ^[0-9]+$ ]] || (( ${2} == 0 )); then
                    abort_msg 'Session count has to be an integer bigger than 0' 22
                fi

                SESSION_GOAL=${2}
                shift 2
                ;;
            '-p'|'--project')
                PROJECT=" (${2})"
                shift 2
                ;;
            '--weekend-sessions')
                if [[ ! ${2} =~ ^[0-9]+$ ]]; then
                    abort_msg 'Weekend goal has to be a positive integer' 22
                fi

                WEEKEND_SESSIONS=${2}
                shift 2
                ;;
            '-n'|'--notify')
                NOTIFY_ONLY='true'
                shift
                ;;
            '-h'|'--help')
                help_text
                exit 0
                ;;
            '--')
                shift
                break
                ;;
            *)
                abort_msg
                ;;
        esac
    done

    if (( SESSION_GOAL > 0 )); then
        if [ -z "${TIME_FRAME_MSG}" ]; then
            TIME_FRAME_MSG='today'
        fi

        if [[ -n "${WEEKEND_SESSIONS}" && "${TIME_FRAME_MSG}" != 'today' ]]; then
            abort_msg 'Weekend goal makes sense only when `-d 1`' 22
        fi
    elif [ -n "${TIME_FRAME_MSG}" -o -n "${WEEKEND_SESSIONS}" ]; then
        abort_msg 'Flags [-d|-w|-m|--weekend-sessions] depend on `-s`' 22
    else
        TIME_FRAME_MSG='today'
    fi
}

get_session_total() {
    # Escape potential (regex) special characters
    local msg_esc="${LOG_MSG//[\(\)\[\]\{\}\^\$\*\+\?]/\\&}"

    SESSIONS_DONE=$(awk -v date="${GOAL_DATE}" '
                        $1 >= date && $0 ~ /'"${msg_esc}"'/ {
                            sum += $NF
                        }
                        END {
                            printf "%d", sum
                        }' ${LOG})
}

log_result() {
    # Escape potential (regex) special characters
    local msg_esc="${LOG_MSG//[\(\)\[\]\{\}\^\$\*\+\?]/\\&}"

    # Log total number of completed sessions
    if ! grep -qE "^${DATE}\s*${msg_esc}\s*" ${LOG}; then
        echo -e "${DATE}\t${LOG_MSG} 1" >> ${LOG}
    else
        sed -Ei "s/^(${DATE}\s*${msg_esc}\s*)([0-9]+)/"'echo "\1$(( \2 + 1 ))"/e' ${LOG}
    fi
}

notify_finish() {
    local notify_args
    local msg=$'\n'
    local todo

    if [ -n "${DEBUG}" ] || (( ${1} > 1 )); then
        notify_args='-e '
    fi

    notify_args+="-a Pomodoro -c Tools -i ${ICON} "
    notify_args+='-h boolean:suppress-sound:true '
    notify_args+='-A close=❌ '
    if [ -s ${LOG} ]; then
        notify_args+='-A log=📜 Log -A stats=📊 Stats '
    else
        msg+=$'Come back when you start doing something...\n'
    fi
    if [ -z "${NOTIFY_ONLY}" ]; then
        notify_args+=$'-A discard=\xF0\x9F\x97\x91\xEF\xB8\x8F Discard '
    fi
    notify_args+='-- Pomodoro'

    if (( SESSIONS_DONE > 1 )); then
        msg+="<b>${SESSIONS_DONE}</b> sessions done ${TIME_FRAME_MSG}${PROJECT}."
    else
        msg+="<b>${SESSIONS_DONE}</b> session done ${TIME_FRAME_MSG}${PROJECT}."
    fi

    if (( SESSION_GOAL > 0 )); then
        (( todo = SESSION_GOAL - SESSIONS_DONE ))

        msg+=$'\n\n'

        if (( SESSIONS_DONE * 3 < SESSION_GOAL )); then
            msg+="<span color='#ff443a' font='20px'><b>🔴 ${todo} left</b></span>\n"
            msg+="to reach the goal of <b>${SESSION_GOAL}</b>."
        elif (( SESSIONS_DONE * 3 < SESSION_GOAL * 2 )); then
            msg+="<span color='#ff9800' font='20px'><b>🟠 ${todo} left</b></span>\n"
            msg+="to reach the goal of <b>${SESSION_GOAL}</b>."
        elif (( todo > 0 )); then
            msg+="<span color='#ffcc32' font='20px'><b>🟡 ${todo} left</b></span>\n"
            msg+="to reach the goal of <b>${SESSION_GOAL}</b>."
        elif (( SESSIONS_DONE * 100 <= SESSION_GOAL * 110 )); then
            msg+="<span color='#7cb342' font='20px'><b>🟢 CONGRATULATIONS!</b></span>\n"
            msg+="You reached the goal: <span color='#a0c37b'><b>${SESSION_GOAL}</b></span>."
        elif (( SESSIONS_DONE * 100 <= SESSION_GOAL * 125 )); then
            msg+="<span color='#f2a258' font='20px'><b>🐻 BEAST MODE!</b></span>\n"
            msg+="You <i>smashed</i> <span color='#aa8972'><b>$(( -todo ))</b></span> more...\n"
            msg+="Will you stop already?"
        elif (( SESSIONS_DONE * 100 <= SESSION_GOAL * 150 )); then
            msg+="<span color='#e7950b' font='20px'><b>💥 CRAZY MODE!</b></span>\n"
            msg+="You <i>over-did</i> <span color='#e7db71'><b>$(( -todo ))</b></span> "
            msg+="more than needed...\n"
            msg+="Are you alright?"
        else
            msg+="<span color='#e7b92d' font='20px'><b>⚡ GOD MODE!</b></span>\n"
            msg+="<span color='#a7c4f4'><b>Sky is not the limit...</b></span>\n"
            msg+="Let alone <span color='#e7d164'><b>$(( -todo ))</b></span> puny extra sessions!\n"
            msg+="But even <i>gods</i> need a nap..."
        fi
    fi

    notify-send ${notify_args} "${msg}"$'\n'
}

notify_log() {
    local lines_num=10
    local page_num
    local step=${lines_num}
    local effective_lines_num
    local total_log_lines=$(wc -l ${LOG} | awk '{print $1}')
    local total_log_pages=$(( (total_log_lines - 1) / lines_num + 1 ))
    local log_lines
    local ret

    # Button sets depend on the current page and number of pages
    local notify_args
    local first_page_buttons
    local mid_page_buttons
    local last_page_buttons
    # Holds current set of buttons
    local cur_buttons

    case $(( (total_log_lines - 1) / lines_num )) in
        0)  ;;
        1)
            first_page_buttons='-A older=◀ Older'
            last_page_buttons='-A newer=▶ Newer'
            ;;
        *)
            first_page_buttons='-A oldest=◀◀ Oldest -A older=◀ Older -A 🚫 Newer -A 🚫 Newest'
            mid_page_buttons='-A oldest=◀◀ Oldest -A older=◀ Older '
            mid_page_buttons+='-A newer=▶ Newer -A newest=▶▶ Newest'
            last_page_buttons='-A 🚫 Oldest -A 🚫 Older -A newer=▶ Newer -A newest=▶▶ Newest'
            ;;
    esac

    cur_buttons="${first_page_buttons}"

    notify_args="-e -t 0 -a Pomodoro -c Tools -i ${ICON} "
    notify_args+='-h boolean:suppress-sound:true -A close=❌ -A back=🢀'

    while :; do
        if (( step <= total_log_lines )); then
            effective_lines_num=${lines_num}
        else
            effective_lines_num=$(( total_log_lines - (step - lines_num) ))
        fi

        log_lines="$(tail -n ${step} ${LOG} | head -n ${effective_lines_num} |
                     sed -E 's,(.*:\s*)([0-9]+),\1 <b>\2</b>\t\t,' | tac)"

        if (( total_log_lines > lines_num )); then
            page_num="($(( step / lines_num ))/${total_log_pages})"
        fi

        ret="$(notify-send ${notify_args} ${cur_buttons} \
               -- "Pomodoro LOG ${page_num}:" $'\n'"${log_lines}"$'\n')"

        case "${ret}" in
            'older')
                (( step += lines_num ))

                if (( step >= total_log_lines )); then
                    cur_buttons="${last_page_buttons}"
                else
                    cur_buttons="${mid_page_buttons}"
                fi
                ;;
            'newer')
                (( step -= lines_num ))

                if (( step == lines_num )); then
                    cur_buttons="${first_page_buttons}"
                else
                    cur_buttons="${mid_page_buttons}"
                fi
                ;;
            'oldest')
                (( step = ((total_log_lines - 1) / lines_num + 1) * lines_num ))
                cur_buttons="${last_page_buttons}"
                ;;
            'newest')
                (( step = lines_num ))
                cur_buttons="${first_page_buttons}"
                ;;
            'back'|'close')
                echo "${ret}"
                return
                ;;
        esac
    done
}

notify_stats() {
    # Graph X number of days on the left of a certain date (excluding that date itself, 6 + 1)
    local show_days_num=6
    local grid_lines='˙ ˙ ˙ ˙ '
    local col_size=${#grid_lines}
    local mark_session='█████'
    local oldest_date="$(grep -om 1 $'^[^\t]\+' ${LOG})"
    local newest_date="$(awk 'END {print $1}' ${LOG})"
    local starting_date="$(date +%F -d "${newest_date} - ${show_days_num} days")"
    local record
    local title
    declare -a table_arr
    local notify_table
    local i j k

    # General notify-send options used
    local notify_args="-e -t 0 -a Pomodoro -c Tools -i ${ICON} "
    notify_args+='-h boolean:suppress-sound:true -A close=❌ -A back=🢀'

    # Button sets depend on the currently visible dates
    local newest_date_buttons='-A 7older=◀◀ 7 Older -A older=◀ Older -A 🚫 Newer -A 🚫 7 Newer'
    local mid_date_buttons='-A 7older=◀◀ 7 Older -A older=◀ Older '
    local mid_date_buttons+='-A newer=▶ Newer -A 7newer=▶▶ 7 Newer'
    local oldest_date_buttons='-A 🚫 7 Older -A 🚫 Older -A newer=▶ Newer -A 7newer=▶▶ 7 Newer'
    # Holds current set of buttons
    local cur_buttons

    if (( $(date +%s -d ${oldest_date}) < $(date +%s -d ${starting_date}) )); then
        cur_buttons="${newest_date_buttons}"
    fi

    # The best score the user has, used as a row number (+1) in the final table
    record=$(awk '{
                     sum[$1] += $NF
                  }
                  END {
                      for (date in sum) {
                          if (sum[date] > record) {
                              record = sum[date]
                          }
                      }
                      print record
                  }'  ${LOG})

    while :; do
        local weekly_average=0

        # Create table_arr template
        for (( i = 0; i <= record; ++i )); do
            table_arr[i]="$(printf -- "${grid_lines}%.0s" $(seq 0 ${show_days_num}))"
            # Centralize somewhat the table (compensate for ICON space on the left)
            # 3 tabs would make left (ICON) and right spacing equal...
            table_arr[i]+=$'\t\t'
        done

        # Add dates and fill up table_arr with sessions
        table_arr[i]=' '    # Centralize dates row
        for (( j = 0; j <= show_days_num; ++j )); do
            local cur_date cur_max idx idx_after row

            cur_date="$(date +'%F;%m/%d' -d "${starting_date} + ${j} days")"
            # Add current date to table bottom
            table_arr[i]+="$(printf -- '%*s' -${col_size} "${cur_date##*;}")"

            # Get total number of sessions for current date
            cur_max=$(awk -v dt="${cur_date%%;*}" '$1 == dt {sum+=$NF} END {print sum}' ${LOG})
            (( weekly_average += cur_max ))

            # Insert mark_session in table_arr's rows
            for (( k = 0; k < cur_max; ++k )); do
                idx=$(( j * col_size + 1 ))
                idx_after=$(( idx + ${#mark_session} ))
                row=$(( record - k ))
                table_arr[row]="${table_arr[row]::idx}${mark_session}${table_arr[row]:idx_after}"
            done

            # Add number cur_max on the top of the session count in the table
            idx=$(( j * col_size + ${#mark_session} - ${#cur_max} - 1 ))
            idx_after=$(( idx + ${#cur_max} ))
            row=$(( record - k ))
            table_arr[row]="${table_arr[row]::idx}${cur_max}${table_arr[row]:idx_after}"
        done

        weekly_average=$(awk -v wa=${weekly_average} -v sdn=${show_days_num} '
                            BEGIN {
                                printf "%.2f", wa / (sdn + 1)
                            }')

        # Create title now that record and week average are known
        title="$(printf -- 'Pomodoro STATS:\t\t%s%s\t\t\t%s' \
                                "x̄ ${weekly_average}" \
                                "$(printf ' %.0s' $(seq ${#weekly_average} 6))" \
                                "🏆 ${record}")"

        # Prepare notify_table for notify-send
        notify_table=$'\n<span font="dejavu sans mono book"><b>'
        for (( i = 0; i <= record + 1; ++i )); do
            notify_table+="${table_arr[i]}"$'\n'
        done
        notify_table+='</b></span>'

        ret="$(notify-send ${notify_args} ${cur_buttons} \
               -- "${title}" "${notify_table}")"

        case "${ret}" in
            'older')
                starting_date="$(date +%F -d "${starting_date} - 1 day")"

                if [[ "${starting_date}" == "${oldest_date}" ]]; then
                    cur_buttons="${oldest_date_buttons}"
                else
                    cur_buttons="${mid_date_buttons}"
                fi
                ;;
            'newer')
                starting_date="$(date +%F -d "${starting_date} + 1 day")"
                local ending_date="$(date +%F -d "${starting_date} + ${show_days_num} days")"

                if [[ "${ending_date}" == "${newest_date}" ]]; then
                    cur_buttons="${newest_date_buttons}"
                else
                    cur_buttons="${mid_date_buttons}"
                fi
                ;;
            '7older')
                starting_date="$(date +%F -d "${starting_date} - 7 day")"

                if (( $(date +%s -d ${oldest_date}) >= $(date +%s -d ${starting_date}) )); then
                    starting_date="${oldest_date}"
                    cur_buttons="${oldest_date_buttons}"
                else
                    cur_buttons="${mid_date_buttons}"
                fi
                ;;
            '7newer')
                starting_date="$(date +%F -d "${starting_date} + 7 day")"
                local ending_date="$(date +%F -d "${starting_date} + ${show_days_num} days")"

                if (( $(date +%s -d ${newest_date}) <= $(date +%s -d ${ending_date}) )); then
                    starting_date="$(date +%F -d "${newest_date} - ${show_days_num} days")"
                    cur_buttons="${newest_date_buttons}"
                else
                    cur_buttons="${mid_date_buttons}"
                fi
                ;;
            'back'|'close')
                echo "${ret}"
                return
                ;;
        esac
    done
}

notify_discard() {
    local notify_args
    local ret

    notify_args="-e -t 0 -a Pomodoro -c Tools -i ${ICON} "
    notify_args+='-h boolean:suppress-sound:true '
    notify_args+=$'-A back=🢀 -A discard=\xF0\x9F\x97\x91\xEF\xB8\x8F Yes '
    notify_args+='-A close=📌 No -- Pomodoro'

    while :; do
        ret="$(notify-send ${notify_args} $'\n<b>Discard last session?</b>\n')"

        if [ -n "${ret}" ]; then
            echo "${ret}"
            return
        fi
    done
}

discard_result() {
    # Escape potential (regex) special characters
    local msg_esc="${LOG_MSG//[\(\)\[\]\{\}\^\$\*\+\?]/\\&}"

    (( --SESSIONS_DONE ))

    if grep -qE "^${DATE}\s*${msg_esc}\s*1\b" ${LOG}; then
        sed -Ei "/^${DATE}\s*${msg_esc}\s*1\b/d" ${LOG}
    else
        sed -Ei "s/^(${DATE}\s*${msg_esc}\s*)([0-9]+)/"'echo "\1$(( \2 - 1 ))"/e' ${LOG}
    fi
}

main() {
    local notify_ret i

    check_dependencies

    # Parse command arguments and assign args related globals
    parse_args "${@}"

    # Run in debug mode when executed from terminal
    if [ -n "${NOTIFY_ONLY}" ]; then
        LOG="${DIR}/.pomodoro.log"
        DEBUG=ON
    elif [ -t 0 ]; then
        LOG="${DIR}/.DEBUG.log"
        DEBUG=ON
    else
        LOG="${DIR}/.pomodoro.log"
    fi

    # First time usage or DEBUG mode, touch LOG
    if [ ! -e ${LOG} ]; then
        touch ${LOG}
    fi

    # Add project (if any) to log msg
    LOG_MSG="$(printf -- "${LOG_MSG}" "${PROJECT}")"

    # Store the result and notify with a sound only when the `-n` flag isn't used
    if [ -z "${NOTIFY_ONLY}" ]; then
        # Log by having one unique result per day and/or per project
        log_result

        # Gently prompt the user that the session has ended
        paplay ${DIR}/assets/Gilfoyle_alarm.ogg &
    fi

    # Modify session goal during weekends (--weekend-sessions)
    if [ -n "${WEEKEND_SESSIONS}" ] && (( $(date +%u) > 5 )); then
        SESSION_GOAL=${WEEKEND_SESSIONS}
    fi

    # Get the number of finished sessions from log
    get_session_total

    # System notification
    for (( i = 1; ; ++i )); do
        notify_ret="$(notify_finish ${i})"

        case "${notify_ret}" in
            'discard')
                notify_ret="$(notify_discard)"

                if [[ "${notify_ret}" == 'back' ]]; then
                    continue
                elif [[ "${notify_ret}" == 'discard' ]]; then
                    discard_result
                    break
                elif [[ "${notify_ret}" == 'close' ]]; then
                    break
                fi
                ;;
            'log')
                notify_ret="$(notify_log)"
                if [[ "${notify_ret}" == 'close' ]]; then
                    break
                fi
                ;;
            'stats')
                notify_ret="$(notify_stats)"
                if [[ "${notify_ret}" == 'close' ]]; then
                    break
                fi
                ;;
            *)
                break
                ;;
        esac
    done

    # Warn the user about .DEBUG.log if it's not needed any more
    if [ -n "${DEBUG}" -a -z "${NOTIFY_ONLY}" ]; then
        printf '\033[35mFeel free:\033[m\n' >&2
        printf "  \033[3;35mrm -f ${LOG}\033[m\n" >&2
    fi
}

# Call main()
main "${@}"

