# Shared functions of the scripts of the Valkey pods (valkey.sh,
# sentinel.sh, probe.sh, prestop.sh). The chart runs them from the
# ConfigMap <fullname>-redis. The pod gives:
# - POD_NAME: the name of the pod (<fullname>-redis-<ordinal>);
# - VALKEY_DOMAIN: <headless Service>.<namespace>.svc;
# - VALKEY_HOSTS: the DNS names of all pods of the group, pod 0 first;
# - VALKEY_MASTER_NAME: the name of the primary that the Sentinels monitor.
# The folders: /etc/valkey (the ConfigMap), /etc/valkey-tls (the TLS
# Secret), /etc/valkey-users (one password file for each ACL user) and
# /run/valkey (an emptyDir in memory: the files that the scripts write).

config_dir=/etc/valkey
tls_dir=/etc/valkey-tls
users_dir=/etc/valkey-users
run_dir=/run/valkey
self="$POD_NAME.$VALKEY_DOMAIN"

log() {
  printf 'valkey: %s\n' "$*" >&2
}

# password <user>: the password of an ACL user, without the trailing CR
# and LF (the wallet reads its password file in the same way).
password() {
  tr -d '\r\n' < "$users_dir/$1"
}

# cli <host> <port> <user> <command>...: one command as an ACL user, over
# TLS. The password goes in the environment (REDISCLI_AUTH), never in the
# arguments.
cli() {
  _host=$1
  _port=$2
  _user=$3
  shift 3
  REDISCLI_AUTH="$(password "$_user")" valkey-cli --tls --cacert "$tls_dir/ca.crt" \
    -h "$_host" -p "$_port" -t 2 --user "$_user" "$@"
}

# group_host <name>: true when <name> is the DNS name of a pod of the group.
group_host() {
  for _host in $VALKEY_HOSTS; do
    if [ "$_host" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

# other_hosts: the DNS names of the other pods of the group.
other_hosts() {
  for _host in $VALKEY_HOSTS; do
    if [ "$_host" != "$self" ]; then
      echo "$_host"
    fi
  done
}

# find_primary: the DNS name of the primary. First the Sentinels of the
# group (the other pods first): they know the primary after a failover.
# Then a data server with the role master (all Sentinels restart, the data
# servers run). Else pod 0: the first start of a new group, or a start of
# all pods together. An answer that is not a pod of the group does not
# count.
find_primary() {
  for _host in $(other_hosts) "$self"; do
    _answer=$(cli "$_host" 26379 sentinel SENTINEL get-master-addr-by-name "$VALKEY_MASTER_NAME" 2> /dev/null | head -n 1) || true
    if group_host "$_answer"; then
      echo "$_answer"
      return 0
    fi
  done
  for _host in $(other_hosts) "$self"; do
    _role=$(cli "$_host" 6379 sentinel ROLE 2> /dev/null | head -n 1) || true
    if [ "$_role" = master ]; then
      echo "$_host"
      return 0
    fi
  done
  echo "${VALKEY_HOSTS%% *}"
}

# render <template> <output> <primary>: write <output> from <template> of
# the ConfigMap. The template has these fields: {password:<user>} (the
# password), {hash:<user>} ("#" and the SHA-256 of the password, the ACL
# file syntax), {self} (the DNS name of this pod) and {primary} (the DNS
# name of the primary). A password has only letters, digits and . _ ~ + /
# = -, so that it is safe in the configuration files.
render() {
  _script="$run_dir/render.sed"
  : > "$_script"
  for _file in "$users_dir"/*; do
    _user=${_file##*/}
    _value=$(password "$_user")
    case "$_value" in
      "" | *[!A-Za-z0-9._~+/=-]*)
        rm -f "$_script"
        log "the password of the user $_user is empty or has a character other than letters, digits and . _ ~ + / = -"
        return 1
        ;;
    esac
    _hash=$(printf '%s' "$_value" | sha256sum | cut -d ' ' -f 1)
    printf 's|{password:%s}|%s|g\ns|{hash:%s}|#%s|g\n' "$_user" "$_value" "$_user" "$_hash" >> "$_script"
  done
  printf 's|{self}|%s|g\ns|{primary}|%s|g\n' "$self" "$3" >> "$_script"
  sed -f "$_script" "$1" > "$2"
  rm -f "$_script"
  if grep -q -E '\{(password|hash):|\{self\}|\{primary\}' "$2"; then
    log "$2 has a field that no password file gives"
    return 1
  fi
}

# wait_for_name <name>: wait until the resolver gives an address for <name>
# (at most 120 seconds). The Sentinel stops when it cannot resolve the
# primary.
wait_for_name() {
  _tries=0
  until getent hosts "$1" > /dev/null 2>&1; do
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 60 ]; then
      log "DNS gives no address for $1 after 120 seconds"
      return 0
    fi
    sleep 2
  done
}
