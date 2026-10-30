#!/bin/sh
# Start one Valkey service of this folder: start.sh primary | replica |
# sentinel (the services valkey, valkey-replica and valkey-sentinel).
#
# The script writes the configuration from the templates of /etc/valkey
# (valkey.conf, users.acl, sentinel.conf) to /run/valkey (a tmpfs; the files
# have the mode 600). The fields of the templates: {password:<user>} and
# {hash:<user>} (the SHA-256 of the password in the ACL syntax) from the
# secret files /run/secrets/valkey/<user>, {self} (the service name) and
# {primary}. A password has only letters, digits and . _ ~ + / = -.
#
# The primary: the one that the Sentinel gives (after a failover), else a
# data server with the role master, else valkey (the first start). A data
# server that is not the primary starts as its replica.
set -eu
umask 077

role="${1:?usage: start.sh primary | replica | sentinel}"
case "$role" in
  primary) self=valkey ;;
  replica) self=valkey-replica ;;
  sentinel) self=valkey-sentinel ;;
  *) echo "valkey: unknown role $role" >&2; exit 2 ;;
esac

# ask <host> <port> <command>...: one command as the user sentinel.
ask() {
  _host=$1
  _port=$2
  shift 2
  REDISCLI_AUTH="$(tr -d '\r\n' < /run/secrets/valkey/sentinel)" valkey-cli -h "$_host" -p "$_port" -t 2 --user sentinel "$@" 2> /dev/null | head -n 1
}

primary=""
if [ "$role" != sentinel ]; then
  answer=$(ask valkey-sentinel 26379 SENTINEL get-master-addr-by-name ows) || true
  case "$answer" in valkey | valkey-replica) primary=$answer ;; esac
fi
if [ -z "$primary" ]; then
  for host in valkey valkey-replica; do
    if [ "$host" != "$self" ] && [ "$(ask "$host" 6379 ROLE || true)" = master ]; then
      primary=$host
      break
    fi
  done
fi
primary=${primary:-valkey}

script=/run/valkey/render.sed
: > "$script"
for file in /run/secrets/valkey/*; do
  user=${file##*/}
  value=$(tr -d '\r\n' < "$file")
  case "$value" in
    "" | *[!A-Za-z0-9._~+/=-]*)
      rm -f "$script"
      echo "valkey: the password of the user $user is empty or has a character other than letters, digits and . _ ~ + / = -" >&2
      exit 1
      ;;
  esac
  hash=$(printf '%s' "$value" | sha256sum | cut -d ' ' -f 1)
  printf 's|{password:%s}|%s|g\ns|{hash:%s}|#%s|g\n' "$user" "$value" "$user" "$hash" >> "$script"
done
printf 's|{self}|%s|g\ns|{primary}|%s|g\n' "$self" "$primary" >> "$script"

if [ "$role" = sentinel ]; then
  sed -f "$script" /etc/valkey/sentinel.conf > /run/valkey/sentinel.conf
  rm -f "$script"
  echo "valkey: the Sentinel monitors $primary"
  exec valkey-server /run/valkey/sentinel.conf --sentinel
fi
sed -f "$script" /etc/valkey/valkey.conf > /run/valkey/valkey.conf
sed -f "$script" /etc/valkey/users.acl > /run/valkey/users.acl
rm -f "$script"
if [ "$primary" = "$self" ]; then
  echo "valkey: $self starts as the primary"
else
  echo "replicaof $primary 6379" >> /run/valkey/valkey.conf
  echo "valkey: $self starts as a replica of $primary"
fi
exec valkey-server /run/valkey/valkey.conf
