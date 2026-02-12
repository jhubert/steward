#!/usr/bin/env bash
set -euo pipefail

# Moxie CRM API CLI wrapper
# Requires: MOXIE_API_KEY, MOXIE_POD_URL

JQ=$(command -v jq 2>/dev/null || true)
fmt_json() { if [ -n "$JQ" ]; then "$JQ" . 2>/dev/null || cat; else cat; fi; }

die() { echo "ERROR: $*" >&2; exit 1; }

[ -z "${MOXIE_API_KEY:-}" ] && die "MOXIE_API_KEY not set"
[ -z "${MOXIE_POD_URL:-}" ] && die "MOXIE_POD_URL not set (e.g. https://pod00.withmoxie.dev/api/public)"

BASE_URL="${MOXIE_POD_URL%/}"

api_get() {
  local path="$1"
  local resp http_code body
  resp=$(curl -sS -w "\n%{http_code}" -H "X-API-KEY: $MOXIE_API_KEY" -H "Content-Type: application/json" "$BASE_URL$path" 2>&1) || die "curl failed: $resp"
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [ "$http_code" = "429" ]; then die "Rate limited (429). Wait before retrying."; fi
  if [ "${http_code:0:1}" != "2" ]; then die "HTTP $http_code: $body"; fi
  echo "$body" | fmt_json
}

api_post() {
  local path="$1" data="$2"
  local resp http_code body
  resp=$(curl -sS -w "\n%{http_code}" -X POST -H "X-API-KEY: $MOXIE_API_KEY" -H "Content-Type: application/json" -d "$data" "$BASE_URL$path" 2>&1) || die "curl failed: $resp"
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [ "$http_code" = "429" ]; then die "Rate limited (429). Wait before retrying."; fi
  if [ "${http_code:0:1}" != "2" ]; then die "HTTP $http_code: $body"; fi
  echo "$body" | fmt_json
}

api_delete() {
  local path="$1"
  local resp http_code body
  resp=$(curl -sS -w "\n%{http_code}" -X DELETE -H "X-API-KEY: $MOXIE_API_KEY" "$BASE_URL$path" 2>&1) || die "curl failed: $resp"
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [ "$http_code" = "429" ]; then die "Rate limited (429). Wait before retrying."; fi
  if [ "${http_code:0:1}" != "2" ]; then die "HTTP $http_code: $body"; fi
  echo "$body" | fmt_json
}

api_multipart() {
  local path="$1"; shift
  local resp http_code body
  resp=$(curl -sS -w "\n%{http_code}" -X POST -H "X-API-KEY: $MOXIE_API_KEY" "$@" "$BASE_URL$path" 2>&1) || die "curl failed: $resp"
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  if [ "$http_code" = "429" ]; then die "Rate limited (429). Wait before retrying."; fi
  if [ "${http_code:0:1}" != "2" ]; then die "HTTP $http_code: $body"; fi
  echo "$body" | fmt_json
}

# Read JSON from --data flag or stdin
get_json() {
  local data=""
  local args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    if [ "${args[$i]}" = "--data" ] && [ $((i+1)) -lt ${#args[@]} ]; then
      data="${args[$((i+1))]}"
      break
    fi
  done
  if [ -z "$data" ] && [ ! -t 0 ]; then
    data=$(cat)
  fi
  echo "$data"
}

# Parse named flags into JSON object
parse_flags() {
  local json="{"
  local first=true
  while [ $# -gt 0 ]; do
    case "$1" in
      --data) shift; shift 2>/dev/null || true; continue ;;
      --*)
        local key="${1#--}"
        shift
        local val="${1:-}"
        shift 2>/dev/null || true
        # Handle booleans and numbers
        case "$val" in
          true|false) ;;
          *[!0-9.]*|"") val="\"$val\"" ;;
          *) ;; # number
        esac
        if $first; then first=false; else json+=","; fi
        json+="\"$key\":$val"
        ;;
      *) shift ;;
    esac
  done
  json+="}"
  [ "$json" = "{}" ] && echo "" || echo "$json"
}

usage() {
  cat <<'EOF'
Moxie CRM API CLI

USAGE: moxie.sh <resource> <action> [options]

RESOURCES & ACTIONS:

  clients list                         List all clients
  clients search <query>               Search clients by name/contact
  clients create [flags|--data JSON]   Create client
    --name, --type (Client|Prospect), --currency, --initials, --website, --phone, --notes

  contacts search [query]              Search contacts
  contacts create [flags|--data JSON]  Create contact
    --first, --last, --email, --phone, --notes, --clientName/--client

  projects search [query]              Search projects (query=client name)
  projects create [flags|--data JSON]  Create project
    --name, --clientName/--client, --startDate, --dueDate

  invoices search [query]              Search payable invoices
  invoices create [--data JSON]        Create invoice (use JSON for line items)

  expenses create [flags|--data JSON]  Create expense
    --date, --amount, --currency, --paid, --reimbursable, --category, --vendor, --clientName

  tasks stages                         List task kanban stages
  tasks create [flags|--data JSON]     Create task
    --name, --clientName/--client, --projectName/--project, --status, --dueDate

  tickets create [flags|--data JSON]   Create ticket
    --userEmail, --ticketType, --subject, --comment, --dueDate
  tickets comment [flags|--data JSON]  Add comment to ticket
    --userEmail, --ticketNumber, --comment, --privateComment

  opportunities create [flags|--data] Create opportunity
    --name, --clientName, --stageName, --value, --estCloseDate

  time create [flags|--data JSON]      Create time entry
    --start, --end, --email/--userEmail, --clientName, --projectName, --notes

  deliverable approve [--data JSON]    Approve deliverable
    --clientName, --projectName, --deliverableName

  payment create [flags|--data JSON]   Apply payment to invoice
    --date, --amount, --invoiceNumber, --clientName, --paymentType, --memo

  attachments upload --type TYPE --id ID --file PATH   Upload file (multipart)
  attachments url --type TYPE --id ID --fileName NAME --fileUrl URL  Attach from URL

  calendar create [--data JSON]        Create/update calendar event
  calendar delete <eventId>            Delete calendar event

  templates email                      List email templates
  templates invoice                    List invoice templates
  vendors list                         List vendor names
  forms list                           List form names
  pipeline stages                      List pipeline stages
  users list                           List workspace users
  submissions create [--data JSON]     Create form submission

OPTIONS:
  --data JSON    Provide request body as JSON string
  --help         Show this help

  JSON can also be piped via stdin for POST endpoints.
EOF
  exit 0
}

[ $# -eq 0 ] && usage
[ "$1" = "--help" ] || [ "$1" = "-h" ] && usage

RESOURCE="$1"; shift
ACTION="${1:-}"; [ $# -gt 0 ] && shift

case "$RESOURCE" in
  clients)
    case "$ACTION" in
      list) api_get "/action/clients/list" ;;
      search) [ $# -eq 0 ] && die "Usage: moxie.sh clients search <query>"
              api_get "/action/clients/search?query=$(printf '%s' "$1" | curl -Gso /dev/null -w '%{url_effective}' --data-urlencode @- '' | cut -c3-)" ;;
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          # Build from flags
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --name) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.name=$v') ;;
              --type) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientType=$v') ;;
              --currency) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.currency=$v') ;;
              --initials) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.initials=$v') ;;
              --website) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.website=$v') ;;
              --phone) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.phone=$v') ;;
              --notes) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.notes=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/clients/create" "$data" ;;
      *) die "Unknown clients action: $ACTION (list|search|create)" ;;
    esac ;;

  contacts)
    case "$ACTION" in
      search) query="${1:-}"
              api_get "/action/contacts/search?query=$(printf '%s' "$query" | curl -Gso /dev/null -w '%{url_effective}' --data-urlencode @- '' | cut -c3-)" ;;
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --first) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.first=$v') ;;
              --last) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.last=$v') ;;
              --email) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.email=$v') ;;
              --phone) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.phone=$v') ;;
              --notes) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.notes=$v') ;;
              --client|--clientName) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/contacts/create" "$data" ;;
      *) die "Unknown contacts action: $ACTION (search|create)" ;;
    esac ;;

  projects)
    case "$ACTION" in
      search) query="${1:-}"
              api_get "/action/projects/search?query=$(printf '%s' "$query" | curl -Gso /dev/null -w '%{url_effective}' --data-urlencode @- '' | cut -c3-)" ;;
      create)
        data=$(get_json "$@")
        [ -z "$data" ] && data=$(parse_flags "$@")
        [ -z "$data" ] && die "Provide JSON via --data or stdin"
        api_post "/action/projects/create" "$data" ;;
      *) die "Unknown projects action: $ACTION (search|create)" ;;
    esac ;;

  invoices)
    case "$ACTION" in
      search) query="${1:-}"
              api_get "/action/payableInvoices/search?query=$(printf '%s' "$query" | curl -Gso /dev/null -w '%{url_effective}' --data-urlencode @- '' | cut -c3-)" ;;
      create)
        data=$(get_json "$@")
        [ -z "$data" ] && die "Provide invoice JSON via --data or stdin"
        api_post "/action/invoices/create" "$data" ;;
      *) die "Unknown invoices action: $ACTION (search|create)" ;;
    esac ;;

  expenses)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --date) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.date=$v') ;;
              --amount) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.amount=$v') ;;
              --currency) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.currency=$v') ;;
              --paid) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.paid=$v') ;;
              --reimbursable) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.reimbursable=$v') ;;
              --category) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.category=$v') ;;
              --vendor) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.vendor=$v') ;;
              --description) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.description=$v') ;;
              --clientName|--client) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/expenses/create" "$data" ;;
      *) die "Unknown expenses action: $ACTION (create)" ;;
    esac ;;

  tasks)
    case "$ACTION" in
      stages) api_get "/action/taskStages/list" ;;
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --name) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.name=$v') ;;
              --client|--clientName) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --project|--projectName) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.projectName=$v') ;;
              --status) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.status=$v') ;;
              --dueDate) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.dueDate=$v') ;;
              --description) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.description=$v') ;;
              --priority) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.priority=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/tasks/create" "$data" ;;
      *) die "Unknown tasks action: $ACTION (stages|create)" ;;
    esac ;;

  tickets)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --userEmail) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.userEmail=$v') ;;
              --ticketType) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.ticketType=$v') ;;
              --subject) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.subject=$v') ;;
              --comment) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.comment=$v') ;;
              --dueDate) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.dueDate=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/tickets/create" "$data" ;;
      comment)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --userEmail) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.userEmail=$v') ;;
              --ticketNumber) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.ticketNumber=$v') ;;
              --comment) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.comment=$v') ;;
              --privateComment) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.privateComment=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/tickets/comments/create" "$data" ;;
      *) die "Unknown tickets action: $ACTION (create|comment)" ;;
    esac ;;

  opportunities)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --name) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.name=$v') ;;
              --clientName|--client) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --stageName) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.stageName=$v') ;;
              --value) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.value=$v') ;;
              --estCloseDate) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.estCloseDate=$v') ;;
              --description) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.description=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/opportunities/create" "$data" ;;
      *) die "Unknown opportunities action: $ACTION (create)" ;;
    esac ;;

  time)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --start) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.timerStart=$v') ;;
              --end) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.timerEnd=$v') ;;
              --email|--userEmail) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.userEmail=$v') ;;
              --clientName|--client) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --projectName|--project) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.projectName=$v') ;;
              --notes) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.notes=$v') ;;
              --deliverableName) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.deliverableName=$v') ;;
              --createClient) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.createClient=$v') ;;
              --createProject) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.createProject=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/timeWorked/create" "$data" ;;
      *) die "Unknown time action: $ACTION (create)" ;;
    esac ;;

  deliverable)
    case "$ACTION" in
      approve)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --clientName|--client) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --projectName|--project) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.projectName=$v') ;;
              --deliverableName) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.deliverableName=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/deliverable/approve" "$data" ;;
      *) die "Unknown deliverable action: $ACTION (approve)" ;;
    esac ;;

  payment)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        if [ -z "$data" ]; then
          json="{}"; args=("$@")
          for ((i=0; i<${#args[@]}; i++)); do
            case "${args[$i]}" in
              --date) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.date=$v') ;;
              --amount) json=$(echo "$json" | ${JQ:-jq} --argjson v "${args[$((++i))]}" '.amount=$v') ;;
              --invoiceNumber) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.invoiceNumber=$v') ;;
              --clientName|--client) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.clientName=$v') ;;
              --paymentType) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.paymentType=$v') ;;
              --referenceNumber) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.referenceNumber=$v') ;;
              --memo) json=$(echo "$json" | ${JQ:-jq} --arg v "${args[$((++i))]}" '.memo=$v') ;;
              --*) i=$((i+1)) ;;
            esac
          done
          data="$json"
        fi
        api_post "/action/payment/create" "$data" ;;
      *) die "Unknown payment action: $ACTION (create)" ;;
    esac ;;

  attachments)
    case "$ACTION" in
      upload)
        atype="" aid="" afile=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --type) atype="$2"; shift 2 ;;
            --id) aid="$2"; shift 2 ;;
            --file) afile="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -z "$atype" ] || [ -z "$aid" ] || [ -z "$afile" ] && die "Usage: moxie.sh attachments upload --type TYPE --id ID --file PATH"
        api_multipart "/action/attachments/create" -F "type=$atype" -F "id=$aid" -F "file=@$afile" ;;
      url)
        atype="" aid="" fname="" furl=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --type) atype="$2"; shift 2 ;;
            --id) aid="$2"; shift 2 ;;
            --fileName) fname="$2"; shift 2 ;;
            --fileUrl) furl="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -z "$atype" ] || [ -z "$aid" ] || [ -z "$fname" ] || [ -z "$furl" ] && die "Usage: moxie.sh attachments url --type TYPE --id ID --fileName NAME --fileUrl URL"
        api_multipart "/action/attachments/createFromUrl" -F "type=$atype" -F "id=$aid" -F "fileName=$fname" -F "fileUrl=$furl" ;;
      *) die "Unknown attachments action: $ACTION (upload|url)" ;;
    esac ;;

  calendar)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        [ -z "$data" ] && die "Provide calendar event JSON via --data or stdin"
        api_post "/action/calendar/createOrUpdate" "$data" ;;
      delete)
        [ $# -eq 0 ] && die "Usage: moxie.sh calendar delete <eventId>"
        api_delete "/action/calendar/$1" ;;
      *) die "Unknown calendar action: $ACTION (create|delete)" ;;
    esac ;;

  templates)
    case "$ACTION" in
      email) api_get "/action/emailTemplates/list" ;;
      invoice) api_get "/action/invoiceTemplates/list" ;;
      *) die "Unknown templates action: $ACTION (email|invoice)" ;;
    esac ;;

  vendors)
    case "$ACTION" in
      list) api_get "/action/vendors/list" ;;
      *) die "Unknown vendors action: $ACTION (list)" ;;
    esac ;;

  forms)
    case "$ACTION" in
      list) api_get "/action/formNames/list" ;;
      *) die "Unknown forms action: $ACTION (list)" ;;
    esac ;;

  pipeline)
    case "$ACTION" in
      stages) api_get "/action/pipelineStages/list" ;;
      *) die "Unknown pipeline action: $ACTION (stages)" ;;
    esac ;;

  users)
    case "$ACTION" in
      list) api_get "/action/users/list" ;;
      *) die "Unknown users action: $ACTION (list)" ;;
    esac ;;

  submissions)
    case "$ACTION" in
      create)
        data=$(get_json "$@")
        [ -z "$data" ] && die "Provide form submission JSON via --data or stdin"
        api_post "/action/formSubmissions/create" "$data" ;;
      *) die "Unknown submissions action: $ACTION (create)" ;;
    esac ;;

  --help|-h) usage ;;
  *) die "Unknown resource: $RESOURCE. Run moxie.sh --help for usage." ;;
esac
