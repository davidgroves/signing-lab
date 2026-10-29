#!/bin/sh
# Ensure runtime dirs exist and are writable by the bind user, then start named in foreground.
set -eu

mkdir -p /var/log/bind /var/cache/bind /var/lib/bind /etc/bind/keys
chown -R bind:bind /var/log/bind /var/cache/bind /var/lib/bind /etc/bind/keys 2>/dev/null || true

# Host-mounted keys/ may not be chownable; loosen perms so named can write key states.
chmod -R ug+rwX /etc/bind/keys 2>/dev/null || true

NAMED_CONF="/etc/bind/named.conf"

# Signer: copy host-mounted named.conf into a writable path so scenarios can
# swap dnssec-policy and rndc reconfig without remounting.
if [ "${NAMED_WRITABLE_CONF:-0}" = "1" ]; then
	SRC="${NAMED_CONF_SRC:-/etc/bind/named.conf.src}"
	NAMED_CONF="/var/cache/bind/named.conf"
	if [ -f "$SRC" ]; then
		cp "$SRC" "$NAMED_CONF"
	elif [ -f /etc/bind/named.conf ]; then
		cp /etc/bind/named.conf "$NAMED_CONF"
	else
		echo "named-entrypoint: no named.conf source at $SRC or /etc/bind/named.conf" >&2
		exit 1
	fi
	chown bind:bind "$NAMED_CONF" 2>/dev/null || true
	chmod ug+rw "$NAMED_CONF" 2>/dev/null || true
fi

# Use -f (foreground) without -g so named.conf logging channels write to files.
exec /usr/sbin/named -u bind -f -c "$NAMED_CONF" -L /var/log/bind/default.log
