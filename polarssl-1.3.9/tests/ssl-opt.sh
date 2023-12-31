#!/bin/sh

# Test various options that are not covered by compat.sh
#
# Here the goal is not to cover every ciphersuite/version, but
# rather specific options (max fragment length, truncated hmac, etc)
# or procedures (session resumption from cache or ticket, renego, etc).
#
# Assumes all options are compiled in.

set -u

# default values, can be overriden by the environment
: ${P_SRV:=../programs/ssl/ssl_server2}
: ${P_CLI:=../programs/ssl/ssl_client2}
: ${OPENSSL_CMD:=openssl} # OPENSSL would conflict with the build system
: ${GNUTLS_CLI:=gnutls-cli}
: ${GNUTLS_SERV:=gnutls-serv}

O_SRV="$OPENSSL_CMD s_server -www -cert data_files/server5.crt -key data_files/server5.key"
O_CLI="echo 'GET / HTTP/1.0' | $OPENSSL_CMD s_client"
G_SRV="$GNUTLS_SERV --x509certfile data_files/server5.crt --x509keyfile data_files/server5.key"
G_CLI="$GNUTLS_CLI"

TESTS=0
FAILS=0
SKIPS=0

CONFIG_H='../include/polarssl/config.h'

MEMCHECK=0
FILTER='.*'
EXCLUDE='^$'

print_usage() {
    echo "Usage: $0 [options]"
    echo -e "  -h|--help\tPrint this help."
    echo -e "  -m|--memcheck\tCheck memory leaks and errors."
    echo -e "  -f|--filter\tOnly matching tests are executed (default: '$FILTER')"
    echo -e "  -e|--exclude\tMatching tests are excluded (default: '$EXCLUDE')"
}

get_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--filter)
                shift; FILTER=$1
                ;;
            -e|--exclude)
                shift; EXCLUDE=$1
                ;;
            -m|--memcheck)
                MEMCHECK=1
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo "Unknown argument: '$1'"
                print_usage
                exit 1
                ;;
        esac
        shift
    done
}

# skip next test if OpenSSL can't send SSLv2 ClientHello
requires_openssl_with_sslv2() {
    if [ -z "${OPENSSL_HAS_SSL2:-}" ]; then
        if $OPENSSL_CMD ciphers -ssl2 >/dev/null 2>&1; then
            OPENSSL_HAS_SSL2="YES"
        else
            OPENSSL_HAS_SSL2="NO"
        fi
    fi
    if [ "$OPENSSL_HAS_SSL2" = "NO" ]; then
        SKIP_NEXT="YES"
    fi
}

# skip next test if GnuTLS isn't available
requires_gnutls() {
    if [ -z "${GNUTLS_AVAILABLE:-}" ]; then
        if ( which "$GNUTLS_CLI" && which "$GNUTLS_SERV" ) >/dev/null; then
            GNUTLS_AVAILABLE="YES"
        else
            GNUTLS_AVAILABLE="NO"
        fi
    fi
    if [ "$GNUTLS_AVAILABLE" = "NO" ]; then
        SKIP_NEXT="YES"
    fi
}

# print_name <name>
print_name() {
    echo -n "$1 "
    LEN=$(( 72 - `echo "$1" | wc -c` ))
    for i in `seq 1 $LEN`; do echo -n '.'; done
    echo -n ' '

    TESTS=$(( $TESTS + 1 ))
}

# fail <message>
fail() {
    echo "FAIL"
    echo "  ! $1"

    mv $SRV_OUT o-srv-${TESTS}.log
    mv $CLI_OUT o-cli-${TESTS}.log
    echo "  ! outputs saved to o-srv-${TESTS}.log and o-cli-${TESTS}.log"

    if [ "X${USER:-}" = Xbuildbot -o "X${LOGNAME:-}" = Xbuildbot ]; then
        echo "  ! server output:"
        cat o-srv-${TESTS}.log
        echo "  ! ============================================================"
        echo "  ! client output:"
        cat o-cli-${TESTS}.log
    fi

    FAILS=$(( $FAILS + 1 ))
}

# is_polar <cmd_line>
is_polar() {
    echo "$1" | grep 'ssl_server2\|ssl_client2' > /dev/null
}

# has_mem_err <log_file_name>
has_mem_err() {
    if ( grep -F 'All heap blocks were freed -- no leaks are possible' "$1" &&
         grep -F 'ERROR SUMMARY: 0 errors from 0 contexts' "$1" ) > /dev/null
    then
        return 1 # false: does not have errors
    else
        return 0 # true: has errors
    fi
}

# wait for server to start: two versions depending on lsof availability
wait_server_start() {
    if which lsof >/dev/null; then
        # make sure we don't loop forever
        ( sleep "$DOG_DELAY"; echo "SERVERSTART TIMEOUT"; kill $MAIN_PID ) &
        WATCHDOG_PID=$!

        # make a tight loop, server usually takes less than 1 sec to start
        until lsof -nbi TCP:"$PORT" | grep LISTEN >/dev/null; do :; done

        kill $WATCHDOG_PID
        wait $WATCHDOG_PID
    else
        sleep "$START_DELAY"
    fi
}

# wait for client to terminate and set CLI_EXIT
# must be called right after starting the client
wait_client_done() {
    CLI_PID=$!

    ( sleep "$DOG_DELAY"; echo "TIMEOUT" >> $CLI_OUT; kill $CLI_PID ) &
    WATCHDOG_PID=$!

    wait $CLI_PID
    CLI_EXIT=$?

    kill $WATCHDOG_PID
    wait $WATCHDOG_PID

    echo "EXIT: $CLI_EXIT" >> $CLI_OUT
}

# Usage: run_test name srv_cmd cli_cmd cli_exit [option [...]]
# Options:  -s pattern  pattern that must be present in server output
#           -c pattern  pattern that must be present in client output
#           -S pattern  pattern that must be absent in server output
#           -C pattern  pattern that must be absent in client output
run_test() {
    NAME="$1"
    SRV_CMD="$2"
    CLI_CMD="$3"
    CLI_EXPECT="$4"
    shift 4

    if echo "$NAME" | grep "$FILTER" | grep -v "$EXCLUDE" >/dev/null; then :
    else
        return
    fi

    print_name "$NAME"

    # should we skip?
    if [ "X$SKIP_NEXT" = "XYES" ]; then
        SKIP_NEXT="NO"
        echo "SKIP"
        SKIPS=$(( $SKIPS + 1 ))
        return
    fi

    # prepend valgrind to our commands if active
    if [ "$MEMCHECK" -gt 0 ]; then
        if is_polar "$SRV_CMD"; then
            SRV_CMD="valgrind --leak-check=full $SRV_CMD"
        fi
        if is_polar "$CLI_CMD"; then
            CLI_CMD="valgrind --leak-check=full $CLI_CMD"
        fi
    fi

    # run the commands
    echo "$SRV_CMD" > $SRV_OUT
    $SRV_CMD >> $SRV_OUT 2>&1 &
    SRV_PID=$!
    wait_server_start

    echo "$CLI_CMD" > $CLI_OUT
    eval "$CLI_CMD" >> $CLI_OUT 2>&1 &
    wait_client_done

    # kill the server
    kill $SRV_PID
    wait $SRV_PID

    # check if the client and server went at least to the handshake stage
    # (useful to avoid tests with only negative assertions and non-zero
    # expected client exit to incorrectly succeed in case of catastrophic
    # failure)
    if is_polar "$SRV_CMD"; then
        if grep "Performing the SSL/TLS handshake" $SRV_OUT >/dev/null; then :;
        else
            fail "server failed to start"
            return
        fi
    fi
    if is_polar "$CLI_CMD"; then
        if grep "Performing the SSL/TLS handshake" $CLI_OUT >/dev/null; then :;
        else
            fail "client failed to start"
            return
        fi
    fi

    # check server exit code
    if [ $? != 0 ]; then
        fail "server fail"
        return
    fi

    # check client exit code
    if [ \( "$CLI_EXPECT" = 0 -a "$CLI_EXIT" != 0 \) -o \
         \( "$CLI_EXPECT" != 0 -a "$CLI_EXIT" = 0 \) ]
    then
        fail "bad client exit code"
        return
    fi

    # check other assertions
    # lines beginning with == are added by valgrind, ignore them
    while [ $# -gt 0 ]
    do
        case $1 in
            "-s")
                if grep -v '^==' $SRV_OUT | grep "$2" >/dev/null; then :; else
                    fail "-s $2"
                    return
                fi
                ;;

            "-c")
                if grep -v '^==' $CLI_OUT | grep "$2" >/dev/null; then :; else
                    fail "-c $2"
                    return
                fi
                ;;

            "-S")
                if grep -v '^==' $SRV_OUT | grep "$2" >/dev/null; then
                    fail "-S $2"
                    return
                fi
                ;;

            "-C")
                if grep -v '^==' $CLI_OUT | grep "$2" >/dev/null; then
                    fail "-C $2"
                    return
                fi
                ;;

            *)
                echo "Unknown test: $1" >&2
                exit 1
        esac
        shift 2
    done

    # check valgrind's results
    if [ "$MEMCHECK" -gt 0 ]; then
        if is_polar "$SRV_CMD" && has_mem_err $SRV_OUT; then
            fail "Server has memory errors"
            return
        fi
        if is_polar "$CLI_CMD" && has_mem_err $CLI_OUT; then
            fail "Client has memory errors"
            return
        fi
    fi

    # if we're here, everything is ok
    echo "PASS"
    rm -f $SRV_OUT $CLI_OUT
}

cleanup() {
    rm -f $CLI_OUT $SRV_OUT $SESSION
    kill $SRV_PID >/dev/null 2>&1
    kill $WATCHDOG_PID >/dev/null 2>&1
    exit 1
}

#
# MAIN
#

get_options "$@"

# sanity checks, avoid an avalanche of errors
if [ ! -x "$P_SRV" ]; then
    echo "Command '$P_SRV' is not an executable file"
    exit 1
fi
if [ ! -x "$P_CLI" ]; then
    echo "Command '$P_CLI' is not an executable file"
    exit 1
fi
if which $OPENSSL_CMD >/dev/null 2>&1; then :; else
    echo "Command '$OPENSSL_CMD' not found"
    exit 1
fi

# used by watchdog
MAIN_PID="$$"

# be more patient with valgrind
if [ "$MEMCHECK" -gt 0 ]; then
    START_DELAY=3
    DOG_DELAY=30
else
    START_DELAY=1
    DOG_DELAY=10
fi

# Pick a "unique" port in the range 10000-19999.
PORT="0000$$"
PORT="1$(echo $PORT | tail -c 5)"

# fix commands to use this port
P_SRV="$P_SRV server_port=$PORT"
P_CLI="$P_CLI server_port=$PORT"
O_SRV="$O_SRV -accept $PORT"
O_CLI="$O_CLI -connect localhost:$PORT"
G_SRV="$G_SRV -p $PORT"
G_CLI="$G_CLI -p $PORT"

# Also pick a unique name for intermediate files
SRV_OUT="srv_out.$$"
CLI_OUT="cli_out.$$"
SESSION="session.$$"

SKIP_NEXT="NO"

trap cleanup INT TERM HUP

# Basic test

# Checks that:
# - things work with all ciphersuites active (used with config-full in all.sh)
# - the expected (highest security) parameters are selected
#   ("signature_algorithm ext: 6" means SHA-512 (highest common hash))
run_test    "Default" \
            "$P_SRV debug_level=3" \
            "$P_CLI" \
            0 \
            -s "Protocol is TLSv1.2" \
            -s "Ciphersuite is TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384" \
            -s "client hello v3, signature_algorithm ext: 6" \
            -s "ECDHE curve: secp521r1" \
            -S "error" \
            -C "error"

# Test for SSLv2 ClientHello

requires_openssl_with_sslv2
run_test    "SSLv2 ClientHello: reference" \
            "$P_SRV debug_level=3" \
            "$O_CLI -no_ssl2" \
            0 \
            -S "parse client hello v2" \
            -S "ssl_handshake returned"

# Adding a SSL2-only suite makes OpenSSL client send SSLv2 ClientHello
requires_openssl_with_sslv2
run_test    "SSLv2 ClientHello: actual test" \
            "$P_SRV debug_level=2" \
            "$O_CLI -cipher 'DES-CBC-MD5:ALL'" \
            0 \
            -s "parse client hello v2" \
            -S "ssl_handshake returned"

# Tests for Truncated HMAC extension

run_test    "Truncated HMAC: reference" \
            "$P_SRV debug_level=4" \
            "$P_CLI trunc_hmac=0 force_ciphersuite=TLS-RSA-WITH-AES-128-CBC-SHA" \
            0 \
            -s "dumping 'computed mac' (20 bytes)"

run_test    "Truncated HMAC: actual test" \
            "$P_SRV debug_level=4" \
            "$P_CLI trunc_hmac=1 force_ciphersuite=TLS-RSA-WITH-AES-128-CBC-SHA" \
            0 \
            -s "dumping 'computed mac' (10 bytes)"

# Tests for Session Tickets

run_test    "Session resume using tickets: basic" \
            "$P_SRV debug_level=3 tickets=1" \
            "$P_CLI debug_level=3 tickets=1 reconnect=1" \
            0 \
            -c "client hello, adding session ticket extension" \
            -s "found session ticket extension" \
            -s "server hello, adding session ticket extension" \
            -c "found session_ticket extension" \
            -c "parse new session ticket" \
            -S "session successfully restored from cache" \
            -s "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using tickets: cache disabled" \
            "$P_SRV debug_level=3 tickets=1 cache_max=0" \
            "$P_CLI debug_level=3 tickets=1 reconnect=1" \
            0 \
            -c "client hello, adding session ticket extension" \
            -s "found session ticket extension" \
            -s "server hello, adding session ticket extension" \
            -c "found session_ticket extension" \
            -c "parse new session ticket" \
            -S "session successfully restored from cache" \
            -s "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using tickets: timeout" \
            "$P_SRV debug_level=3 tickets=1 cache_max=0 ticket_timeout=1" \
            "$P_CLI debug_level=3 tickets=1 reconnect=1 reco_delay=2" \
            0 \
            -c "client hello, adding session ticket extension" \
            -s "found session ticket extension" \
            -s "server hello, adding session ticket extension" \
            -c "found session_ticket extension" \
            -c "parse new session ticket" \
            -S "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -S "a session has been resumed" \
            -C "a session has been resumed"

run_test    "Session resume using tickets: openssl server" \
            "$O_SRV" \
            "$P_CLI debug_level=3 tickets=1 reconnect=1" \
            0 \
            -c "client hello, adding session ticket extension" \
            -c "found session_ticket extension" \
            -c "parse new session ticket" \
            -c "a session has been resumed"

run_test    "Session resume using tickets: openssl client" \
            "$P_SRV debug_level=3 tickets=1" \
            "( $O_CLI -sess_out $SESSION; \
               $O_CLI -sess_in $SESSION; \
               rm -f $SESSION )" \
            0 \
            -s "found session ticket extension" \
            -s "server hello, adding session ticket extension" \
            -S "session successfully restored from cache" \
            -s "session successfully restored from ticket" \
            -s "a session has been resumed"

# Tests for Session Resume based on session-ID and cache

run_test    "Session resume using cache: tickets enabled on client" \
            "$P_SRV debug_level=3 tickets=0" \
            "$P_CLI debug_level=3 tickets=1 reconnect=1" \
            0 \
            -c "client hello, adding session ticket extension" \
            -s "found session ticket extension" \
            -S "server hello, adding session ticket extension" \
            -C "found session_ticket extension" \
            -C "parse new session ticket" \
            -s "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using cache: tickets enabled on server" \
            "$P_SRV debug_level=3 tickets=1" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1" \
            0 \
            -C "client hello, adding session ticket extension" \
            -S "found session ticket extension" \
            -S "server hello, adding session ticket extension" \
            -C "found session_ticket extension" \
            -C "parse new session ticket" \
            -s "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using cache: cache_max=0" \
            "$P_SRV debug_level=3 tickets=0 cache_max=0" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1" \
            0 \
            -S "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -S "a session has been resumed" \
            -C "a session has been resumed"

run_test    "Session resume using cache: cache_max=1" \
            "$P_SRV debug_level=3 tickets=0 cache_max=1" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1" \
            0 \
            -s "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using cache: timemout > delay" \
            "$P_SRV debug_level=3 tickets=0" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1 reco_delay=0" \
            0 \
            -s "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using cache: timeout < delay" \
            "$P_SRV debug_level=3 tickets=0 cache_timeout=1" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1 reco_delay=2" \
            0 \
            -S "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -S "a session has been resumed" \
            -C "a session has been resumed"

run_test    "Session resume using cache: no timeout" \
            "$P_SRV debug_level=3 tickets=0 cache_timeout=0" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1 reco_delay=2" \
            0 \
            -s "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -s "a session has been resumed" \
            -c "a session has been resumed"

run_test    "Session resume using cache: openssl client" \
            "$P_SRV debug_level=3 tickets=0" \
            "( $O_CLI -sess_out $SESSION; \
               $O_CLI -sess_in $SESSION; \
               rm -f $SESSION )" \
            0 \
            -s "found session ticket extension" \
            -S "server hello, adding session ticket extension" \
            -s "session successfully restored from cache" \
            -S "session successfully restored from ticket" \
            -s "a session has been resumed"

run_test    "Session resume using cache: openssl server" \
            "$O_SRV" \
            "$P_CLI debug_level=3 tickets=0 reconnect=1" \
            0 \
            -C "found session_ticket extension" \
            -C "parse new session ticket" \
            -c "a session has been resumed"

# Tests for Max Fragment Length extension

run_test    "Max fragment length: not used, reference" \
            "$P_SRV debug_level=3" \
            "$P_CLI debug_level=3" \
            0 \
            -C "client hello, adding max_fragment_length extension" \
            -S "found max fragment length extension" \
            -S "server hello, max_fragment_length extension" \
            -C "found max_fragment_length extension"

run_test    "Max fragment length: used by client" \
            "$P_SRV debug_level=3" \
            "$P_CLI debug_level=3 max_frag_len=4096" \
            0 \
            -c "client hello, adding max_fragment_length extension" \
            -s "found max fragment length extension" \
            -s "server hello, max_fragment_length extension" \
            -c "found max_fragment_length extension"

run_test    "Max fragment length: used by server" \
            "$P_SRV debug_level=3 max_frag_len=4096" \
            "$P_CLI debug_level=3" \
            0 \
            -C "client hello, adding max_fragment_length extension" \
            -S "found max fragment length extension" \
            -S "server hello, max_fragment_length extension" \
            -C "found max_fragment_length extension"

requires_gnutls
run_test    "Max fragment length: gnutls server" \
            "$G_SRV" \
            "$P_CLI debug_level=3 max_frag_len=4096" \
            0 \
            -c "client hello, adding max_fragment_length extension" \
            -c "found max_fragment_length extension"

# Tests for renegotiation

run_test    "Renegotiation: none, for reference" \
            "$P_SRV debug_level=3 exchanges=2" \
            "$P_CLI debug_level=3 exchanges=2" \
            0 \
            -C "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -S "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -C "=> renegotiate" \
            -S "=> renegotiate" \
            -S "write hello request"

run_test    "Renegotiation: client-initiated" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=1 renegotiate=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -s "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -s "=> renegotiate" \
            -S "write hello request"

run_test    "Renegotiation: server-initiated" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -s "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -s "=> renegotiate" \
            -s "write hello request"

run_test    "Renegotiation: double" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=1 renegotiate=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -s "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -s "=> renegotiate" \
            -s "write hello request"

run_test    "Renegotiation: client-initiated, server-rejected" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=0" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=1 renegotiate=1" \
            1 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -S "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -S "=> renegotiate" \
            -S "write hello request" \
            -c "SSL - Unexpected message at ServerHello in renegotiation" \
            -c "failed"

run_test    "Renegotiation: server-initiated, client-rejected, default" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=0" \
            0 \
            -C "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -S "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -C "=> renegotiate" \
            -S "=> renegotiate" \
            -s "write hello request" \
            -S "SSL - An unexpected message was received from our peer" \
            -S "failed"

run_test    "Renegotiation: server-initiated, client-rejected, not enforced" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1 \
             renego_delay=-1" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=0" \
            0 \
            -C "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -S "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -C "=> renegotiate" \
            -S "=> renegotiate" \
            -s "write hello request" \
            -S "SSL - An unexpected message was received from our peer" \
            -S "failed"

# delay 2 for 1 alert record + 1 application data record
run_test    "Renegotiation: server-initiated, client-rejected, delay 2" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1 \
             renego_delay=2" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=0" \
            0 \
            -C "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -S "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -C "=> renegotiate" \
            -S "=> renegotiate" \
            -s "write hello request" \
            -S "SSL - An unexpected message was received from our peer" \
            -S "failed"

run_test    "Renegotiation: server-initiated, client-rejected, delay 0" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1 \
             renego_delay=0" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=0" \
            0 \
            -C "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -S "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -C "=> renegotiate" \
            -S "=> renegotiate" \
            -s "write hello request" \
            -s "SSL - An unexpected message was received from our peer"

run_test    "Renegotiation: server-initiated, client-accepted, delay 0" \
            "$P_SRV debug_level=3 exchanges=2 renegotiation=1 renegotiate=1 \
             renego_delay=0" \
            "$P_CLI debug_level=3 exchanges=2 renegotiation=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -s "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -s "=> renegotiate" \
            -s "write hello request" \
            -S "SSL - An unexpected message was received from our peer" \
            -S "failed"

run_test    "Renegotiation: nbio, client-initiated" \
            "$P_SRV debug_level=3 nbio=2 exchanges=2 renegotiation=1" \
            "$P_CLI debug_level=3 nbio=2 exchanges=2 renegotiation=1 renegotiate=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -s "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -s "=> renegotiate" \
            -S "write hello request"

run_test    "Renegotiation: nbio, server-initiated" \
            "$P_SRV debug_level=3 nbio=2 exchanges=2 renegotiation=1 renegotiate=1" \
            "$P_CLI debug_level=3 nbio=2 exchanges=2 renegotiation=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -s "received TLS_EMPTY_RENEGOTIATION_INFO" \
            -s "found renegotiation extension" \
            -s "server hello, secure renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -s "=> renegotiate" \
            -s "write hello request"

run_test    "Renegotiation: openssl server, client-initiated" \
            "$O_SRV" \
            "$P_CLI debug_level=3 exchanges=1 renegotiation=1 renegotiate=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -C "ssl_handshake returned" \
            -C "error" \
            -c "HTTP/1.0 200 [Oo][Kk]"

run_test    "Renegotiation: gnutls server, client-initiated" \
            "$G_SRV" \
            "$P_CLI debug_level=3 exchanges=1 renegotiation=1 renegotiate=1" \
            0 \
            -c "client hello, adding renegotiation extension" \
            -c "found renegotiation extension" \
            -c "=> renegotiate" \
            -C "ssl_handshake returned" \
            -C "error" \
            -c "HTTP/1.0 200 [Oo][Kk]"

# Tests for auth_mode

run_test    "Authentication: server badcert, client required" \
            "$P_SRV crt_file=data_files/server5-badsign.crt \
             key_file=data_files/server5.key" \
            "$P_CLI debug_level=1 auth_mode=required" \
            1 \
            -c "x509_verify_cert() returned" \
            -c "! self-signed or not signed by a trusted CA" \
            -c "! ssl_handshake returned" \
            -c "X509 - Certificate verification failed"

run_test    "Authentication: server badcert, client optional" \
            "$P_SRV crt_file=data_files/server5-badsign.crt \
             key_file=data_files/server5.key" \
            "$P_CLI debug_level=1 auth_mode=optional" \
            0 \
            -c "x509_verify_cert() returned" \
            -c "! self-signed or not signed by a trusted CA" \
            -C "! ssl_handshake returned" \
            -C "X509 - Certificate verification failed"

run_test    "Authentication: server badcert, client none" \
            "$P_SRV crt_file=data_files/server5-badsign.crt \
             key_file=data_files/server5.key" \
            "$P_CLI debug_level=1 auth_mode=none" \
            0 \
            -C "x509_verify_cert() returned" \
            -C "! self-signed or not signed by a trusted CA" \
            -C "! ssl_handshake returned" \
            -C "X509 - Certificate verification failed"

run_test    "Authentication: client badcert, server required" \
            "$P_SRV debug_level=3 auth_mode=required" \
            "$P_CLI debug_level=3 crt_file=data_files/server5-badsign.crt \
             key_file=data_files/server5.key" \
            1 \
            -S "skip write certificate request" \
            -C "skip parse certificate request" \
            -c "got a certificate request" \
            -C "skip write certificate" \
            -C "skip write certificate verify" \
            -S "skip parse certificate verify" \
            -s "x509_verify_cert() returned" \
            -S "! self-signed or not signed by a trusted CA" \
            -s "! ssl_handshake returned" \
            -c "! ssl_handshake returned" \
            -s "X509 - Certificate verification failed"

run_test    "Authentication: client badcert, server optional" \
            "$P_SRV debug_level=3 auth_mode=optional" \
            "$P_CLI debug_level=3 crt_file=data_files/server5-badsign.crt \
             key_file=data_files/server5.key" \
            0 \
            -S "skip write certificate request" \
            -C "skip parse certificate request" \
            -c "got a certificate request" \
            -C "skip write certificate" \
            -C "skip write certificate verify" \
            -S "skip parse certificate verify" \
            -s "x509_verify_cert() returned" \
            -s "! self-signed or not signed by a trusted CA" \
            -S "! ssl_handshake returned" \
            -C "! ssl_handshake returned" \
            -S "X509 - Certificate verification failed"

run_test    "Authentication: client badcert, server none" \
            "$P_SRV debug_level=3 auth_mode=none" \
            "$P_CLI debug_level=3 crt_file=data_files/server5-badsign.crt \
             key_file=data_files/server5.key" \
            0 \
            -s "skip write certificate request" \
            -C "skip parse certificate request" \
            -c "got no certificate request" \
            -c "skip write certificate" \
            -c "skip write certificate verify" \
            -s "skip parse certificate verify" \
            -S "x509_verify_cert() returned" \
            -S "! self-signed or not signed by a trusted CA" \
            -S "! ssl_handshake returned" \
            -C "! ssl_handshake returned" \
            -S "X509 - Certificate verification failed"

run_test    "Authentication: client no cert, server optional" \
            "$P_SRV debug_level=3 auth_mode=optional" \
            "$P_CLI debug_level=3 crt_file=none key_file=none" \
            0 \
            -S "skip write certificate request" \
            -C "skip parse certificate request" \
            -c "got a certificate request" \
            -C "skip write certificate$" \
            -C "got no certificate to send" \
            -S "SSLv3 client has no certificate" \
            -c "skip write certificate verify" \
            -s "skip parse certificate verify" \
            -s "! no client certificate sent" \
            -S "! ssl_handshake returned" \
            -C "! ssl_handshake returned" \
            -S "X509 - Certificate verification failed"

run_test    "Authentication: openssl client no cert, server optional" \
            "$P_SRV debug_level=3 auth_mode=optional" \
            "$O_CLI" \
            0 \
            -S "skip write certificate request" \
            -s "skip parse certificate verify" \
            -s "! no client certificate sent" \
            -S "! ssl_handshake returned" \
            -S "X509 - Certificate verification failed"

run_test    "Authentication: client no cert, openssl server optional" \
            "$O_SRV -verify 10" \
            "$P_CLI debug_level=3 crt_file=none key_file=none" \
            0 \
            -C "skip parse certificate request" \
            -c "got a certificate request" \
            -C "skip write certificate$" \
            -c "skip write certificate verify" \
            -C "! ssl_handshake returned"

run_test    "Authentication: client no cert, ssl3" \
            "$P_SRV debug_level=3 auth_mode=optional force_version=ssl3" \
            "$P_CLI debug_level=3 crt_file=none key_file=none" \
            0 \
            -S "skip write certificate request" \
            -C "skip parse certificate request" \
            -c "got a certificate request" \
            -C "skip write certificate$" \
            -c "skip write certificate verify" \
            -c "got no certificate to send" \
            -s "SSLv3 client has no certificate" \
            -s "skip parse certificate verify" \
            -s "! no client certificate sent" \
            -S "! ssl_handshake returned" \
            -C "! ssl_handshake returned" \
            -S "X509 - Certificate verification failed"

# tests for SNI

run_test    "SNI: no SNI callback" \
            "$P_SRV debug_level=3 server_addr=127.0.0.1 \
             crt_file=data_files/server5.crt key_file=data_files/server5.key" \
            "$P_CLI debug_level=0 server_addr=127.0.0.1 \
             server_name=localhost" \
             0 \
             -S "parse ServerName extension" \
             -c "issuer name *: C=NL, O=PolarSSL, CN=Polarssl Test EC CA" \
             -c "subject name *: C=NL, O=PolarSSL, CN=localhost"

run_test    "SNI: matching cert 1" \
            "$P_SRV debug_level=3 server_addr=127.0.0.1 \
             crt_file=data_files/server5.crt key_file=data_files/server5.key \
             sni=localhost,data_files/server2.crt,data_files/server2.key,polarssl.example,data_files/server1-nospace.crt,data_files/server1.key" \
            "$P_CLI debug_level=0 server_addr=127.0.0.1 \
             server_name=localhost" \
             0 \
             -s "parse ServerName extension" \
             -c "issuer name *: C=NL, O=PolarSSL, CN=PolarSSL Test CA" \
             -c "subject name *: C=NL, O=PolarSSL, CN=localhost"

run_test    "SNI: matching cert 2" \
            "$P_SRV debug_level=3 server_addr=127.0.0.1 \
             crt_file=data_files/server5.crt key_file=data_files/server5.key \
             sni=localhost,data_files/server2.crt,data_files/server2.key,polarssl.example,data_files/server1-nospace.crt,data_files/server1.key" \
            "$P_CLI debug_level=0 server_addr=127.0.0.1 \
             server_name=polarssl.example" \
             0 \
             -s "parse ServerName extension" \
             -c "issuer name *: C=NL, O=PolarSSL, CN=PolarSSL Test CA" \
             -c "subject name *: C=NL, O=PolarSSL, CN=polarssl.example"

run_test    "SNI: no matching cert" \
            "$P_SRV debug_level=3 server_addr=127.0.0.1 \
             crt_file=data_files/server5.crt key_file=data_files/server5.key \
             sni=localhost,data_files/server2.crt,data_files/server2.key,polarssl.example,data_files/server1-nospace.crt,data_files/server1.key" \
            "$P_CLI debug_level=0 server_addr=127.0.0.1 \
             server_name=nonesuch.example" \
             1 \
             -s "parse ServerName extension" \
             -s "ssl_sni_wrapper() returned" \
             -s "ssl_handshake returned" \
             -c "ssl_handshake returned" \
             -c "SSL - A fatal alert message was received from our peer"

# Tests for non-blocking I/O: exercise a variety of handshake flows

run_test    "Non-blocking I/O: basic handshake" \
            "$P_SRV nbio=2 tickets=0 auth_mode=none" \
            "$P_CLI nbio=2 tickets=0" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

run_test    "Non-blocking I/O: client auth" \
            "$P_SRV nbio=2 tickets=0 auth_mode=required" \
            "$P_CLI nbio=2 tickets=0" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

run_test    "Non-blocking I/O: ticket" \
            "$P_SRV nbio=2 tickets=1 auth_mode=none" \
            "$P_CLI nbio=2 tickets=1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

run_test    "Non-blocking I/O: ticket + client auth" \
            "$P_SRV nbio=2 tickets=1 auth_mode=required" \
            "$P_CLI nbio=2 tickets=1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

run_test    "Non-blocking I/O: ticket + client auth + resume" \
            "$P_SRV nbio=2 tickets=1 auth_mode=required" \
            "$P_CLI nbio=2 tickets=1 reconnect=1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

run_test    "Non-blocking I/O: ticket + resume" \
            "$P_SRV nbio=2 tickets=1 auth_mode=none" \
            "$P_CLI nbio=2 tickets=1 reconnect=1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

run_test    "Non-blocking I/O: session-id resume" \
            "$P_SRV nbio=2 tickets=0 auth_mode=none" \
            "$P_CLI nbio=2 tickets=0 reconnect=1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -c "Read from server: .* bytes read"

# Tests for version negotiation

run_test    "Version check: all -> 1.2" \
            "$P_SRV" \
            "$P_CLI" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -s "Protocol is TLSv1.2" \
            -c "Protocol is TLSv1.2"

run_test    "Version check: cli max 1.1 -> 1.1" \
            "$P_SRV" \
            "$P_CLI max_version=tls1_1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -s "Protocol is TLSv1.1" \
            -c "Protocol is TLSv1.1"

run_test    "Version check: srv max 1.1 -> 1.1" \
            "$P_SRV max_version=tls1_1" \
            "$P_CLI" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -s "Protocol is TLSv1.1" \
            -c "Protocol is TLSv1.1"

run_test    "Version check: cli+srv max 1.1 -> 1.1" \
            "$P_SRV max_version=tls1_1" \
            "$P_CLI max_version=tls1_1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -s "Protocol is TLSv1.1" \
            -c "Protocol is TLSv1.1"

run_test    "Version check: cli max 1.1, srv min 1.1 -> 1.1" \
            "$P_SRV min_version=tls1_1" \
            "$P_CLI max_version=tls1_1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -s "Protocol is TLSv1.1" \
            -c "Protocol is TLSv1.1"

run_test    "Version check: cli min 1.1, srv max 1.1 -> 1.1" \
            "$P_SRV max_version=tls1_1" \
            "$P_CLI min_version=tls1_1" \
            0 \
            -S "ssl_handshake returned" \
            -C "ssl_handshake returned" \
            -s "Protocol is TLSv1.1" \
            -c "Protocol is TLSv1.1"

run_test    "Version check: cli min 1.2, srv max 1.1 -> fail" \
            "$P_SRV max_version=tls1_1" \
            "$P_CLI min_version=tls1_2" \
            1 \
            -s "ssl_handshake returned" \
            -c "ssl_handshake returned" \
            -c "SSL - Handshake protocol not within min/max boundaries"

run_test    "Version check: srv min 1.2, cli max 1.1 -> fail" \
            "$P_SRV min_version=tls1_2" \
            "$P_CLI max_version=tls1_1" \
            1 \
            -s "ssl_handshake returned" \
            -c "ssl_handshake returned" \
            -s "SSL - Handshake protocol not within min/max boundaries"

# Tests for ALPN extension

if grep '^#define POLARSSL_SSL_ALPN' $CONFIG_H >/dev/null; then

run_test    "ALPN: none" \
            "$P_SRV debug_level=3" \
            "$P_CLI debug_level=3" \
            0 \
            -C "client hello, adding alpn extension" \
            -S "found alpn extension" \
            -C "got an alert message, type: \\[2:120]" \
            -S "server hello, adding alpn extension" \
            -C "found alpn extension " \
            -C "Application Layer Protocol is" \
            -S "Application Layer Protocol is"

run_test    "ALPN: client only" \
            "$P_SRV debug_level=3" \
            "$P_CLI debug_level=3 alpn=abc,1234" \
            0 \
            -c "client hello, adding alpn extension" \
            -s "found alpn extension" \
            -C "got an alert message, type: \\[2:120]" \
            -S "server hello, adding alpn extension" \
            -C "found alpn extension " \
            -c "Application Layer Protocol is (none)" \
            -S "Application Layer Protocol is"

run_test    "ALPN: server only" \
            "$P_SRV debug_level=3 alpn=abc,1234" \
            "$P_CLI debug_level=3" \
            0 \
            -C "client hello, adding alpn extension" \
            -S "found alpn extension" \
            -C "got an alert message, type: \\[2:120]" \
            -S "server hello, adding alpn extension" \
            -C "found alpn extension " \
            -C "Application Layer Protocol is" \
            -s "Application Layer Protocol is (none)"

run_test    "ALPN: both, common cli1-srv1" \
            "$P_SRV debug_level=3 alpn=abc,1234" \
            "$P_CLI debug_level=3 alpn=abc,1234" \
            0 \
            -c "client hello, adding alpn extension" \
            -s "found alpn extension" \
            -C "got an alert message, type: \\[2:120]" \
            -s "server hello, adding alpn extension" \
            -c "found alpn extension" \
            -c "Application Layer Protocol is abc" \
            -s "Application Layer Protocol is abc"

run_test    "ALPN: both, common cli2-srv1" \
            "$P_SRV debug_level=3 alpn=abc,1234" \
            "$P_CLI debug_level=3 alpn=1234,abc" \
            0 \
            -c "client hello, adding alpn extension" \
            -s "found alpn extension" \
            -C "got an alert message, type: \\[2:120]" \
            -s "server hello, adding alpn extension" \
            -c "found alpn extension" \
            -c "Application Layer Protocol is abc" \
            -s "Application Layer Protocol is abc"

run_test    "ALPN: both, common cli1-srv2" \
            "$P_SRV debug_level=3 alpn=abc,1234" \
            "$P_CLI debug_level=3 alpn=1234,abcde" \
            0 \
            -c "client hello, adding alpn extension" \
            -s "found alpn extension" \
            -C "got an alert message, type: \\[2:120]" \
            -s "server hello, adding alpn extension" \
            -c "found alpn extension" \
            -c "Application Layer Protocol is 1234" \
            -s "Application Layer Protocol is 1234"

run_test    "ALPN: both, no common" \
            "$P_SRV debug_level=3 alpn=abc,123" \
            "$P_CLI debug_level=3 alpn=1234,abcde" \
            1 \
            -c "client hello, adding alpn extension" \
            -s "found alpn extension" \
            -c "got an alert message, type: \\[2:120]" \
            -S "server hello, adding alpn extension" \
            -C "found alpn extension" \
            -C "Application Layer Protocol is 1234" \
            -S "Application Layer Protocol is 1234"

fi

# Tests for keyUsage in leaf certificates, part 1:
# server-side certificate/suite selection

run_test    "keyUsage srv: RSA, digitalSignature -> (EC)DHE-RSA" \
            "$P_SRV key_file=data_files/server2.key \
             crt_file=data_files/server2.ku-ds.crt" \
            "$P_CLI" \
            0 \
            -c "Ciphersuite is TLS-[EC]*DHE-RSA-WITH-"


run_test    "keyUsage srv: RSA, keyEncipherment -> RSA" \
            "$P_SRV key_file=data_files/server2.key \
             crt_file=data_files/server2.ku-ke.crt" \
            "$P_CLI" \
            0 \
            -c "Ciphersuite is TLS-RSA-WITH-"

run_test    "keyUsage srv: RSA, keyAgreement -> fail" \
            "$P_SRV key_file=data_files/server2.key \
             crt_file=data_files/server2.ku-ka.crt" \
            "$P_CLI" \
            1 \
            -C "Ciphersuite is "

run_test    "keyUsage srv: ECDSA, digitalSignature -> ECDHE-ECDSA" \
            "$P_SRV key_file=data_files/server5.key \
             crt_file=data_files/server5.ku-ds.crt" \
            "$P_CLI" \
            0 \
            -c "Ciphersuite is TLS-ECDHE-ECDSA-WITH-"


run_test    "keyUsage srv: ECDSA, keyAgreement -> ECDH-" \
            "$P_SRV key_file=data_files/server5.key \
             crt_file=data_files/server5.ku-ka.crt" \
            "$P_CLI" \
            0 \
            -c "Ciphersuite is TLS-ECDH-"

run_test    "keyUsage srv: ECDSA, keyEncipherment -> fail" \
            "$P_SRV key_file=data_files/server5.key \
             crt_file=data_files/server5.ku-ke.crt" \
            "$P_CLI" \
            1 \
            -C "Ciphersuite is "

# Tests for keyUsage in leaf certificates, part 2:
# client-side checking of server cert

run_test    "keyUsage cli: DigitalSignature+KeyEncipherment, RSA: OK" \
            "$O_SRV -key data_files/server2.key \
             -cert data_files/server2.ku-ds_ke.crt" \
            "$P_CLI debug_level=1 \
             force_ciphersuite=TLS-RSA-WITH-AES-128-CBC-SHA" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "keyUsage cli: DigitalSignature+KeyEncipherment, DHE-RSA: OK" \
            "$O_SRV -key data_files/server2.key \
             -cert data_files/server2.ku-ds_ke.crt" \
            "$P_CLI debug_level=1 \
             force_ciphersuite=TLS-DHE-RSA-WITH-AES-128-CBC-SHA" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "keyUsage cli: KeyEncipherment, RSA: OK" \
            "$O_SRV -key data_files/server2.key \
             -cert data_files/server2.ku-ke.crt" \
            "$P_CLI debug_level=1 \
             force_ciphersuite=TLS-RSA-WITH-AES-128-CBC-SHA" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "keyUsage cli: KeyEncipherment, DHE-RSA: fail" \
            "$O_SRV -key data_files/server2.key \
             -cert data_files/server2.ku-ke.crt" \
            "$P_CLI debug_level=1 \
             force_ciphersuite=TLS-DHE-RSA-WITH-AES-128-CBC-SHA" \
            1 \
            -c "bad certificate (usage extensions)" \
            -c "Processing of the Certificate handshake message failed" \
            -C "Ciphersuite is TLS-"

run_test    "keyUsage cli: DigitalSignature, DHE-RSA: OK" \
            "$O_SRV -key data_files/server2.key \
             -cert data_files/server2.ku-ds.crt" \
            "$P_CLI debug_level=1 \
             force_ciphersuite=TLS-DHE-RSA-WITH-AES-128-CBC-SHA" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "keyUsage cli: DigitalSignature, RSA: fail" \
            "$O_SRV -key data_files/server2.key \
             -cert data_files/server2.ku-ds.crt" \
            "$P_CLI debug_level=1 \
             force_ciphersuite=TLS-RSA-WITH-AES-128-CBC-SHA" \
            1 \
            -c "bad certificate (usage extensions)" \
            -c "Processing of the Certificate handshake message failed" \
            -C "Ciphersuite is TLS-"

# Tests for keyUsage in leaf certificates, part 3:
# server-side checking of client cert

run_test    "keyUsage cli-auth: RSA, DigitalSignature: OK" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server2.key \
             -cert data_files/server2.ku-ds.crt" \
            0 \
            -S "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "keyUsage cli-auth: RSA, KeyEncipherment: fail (soft)" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server2.key \
             -cert data_files/server2.ku-ke.crt" \
            0 \
            -s "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "keyUsage cli-auth: RSA, KeyEncipherment: fail (hard)" \
            "$P_SRV debug_level=1 auth_mode=required" \
            "$O_CLI -key data_files/server2.key \
             -cert data_files/server2.ku-ke.crt" \
            1 \
            -s "bad certificate (usage extensions)" \
            -s "Processing of the Certificate handshake message failed"

run_test    "keyUsage cli-auth: ECDSA, DigitalSignature: OK" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.ku-ds.crt" \
            0 \
            -S "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "keyUsage cli-auth: ECDSA, KeyAgreement: fail (soft)" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.ku-ka.crt" \
            0 \
            -s "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

# Tests for extendedKeyUsage, part 1: server-side certificate/suite selection

run_test    "extKeyUsage srv: serverAuth -> OK" \
            "$P_SRV key_file=data_files/server5.key \
             crt_file=data_files/server5.eku-srv.crt" \
            "$P_CLI" \
            0

run_test    "extKeyUsage srv: serverAuth,clientAuth -> OK" \
            "$P_SRV key_file=data_files/server5.key \
             crt_file=data_files/server5.eku-srv.crt" \
            "$P_CLI" \
            0

run_test    "extKeyUsage srv: codeSign,anyEKU -> OK" \
            "$P_SRV key_file=data_files/server5.key \
             crt_file=data_files/server5.eku-cs_any.crt" \
            "$P_CLI" \
            0

# add psk to leave an option for client to send SERVERQUIT
run_test    "extKeyUsage srv: codeSign -> fail" \
            "$P_SRV psk=abc123 key_file=data_files/server5.key \
             crt_file=data_files/server5.eku-cli.crt" \
            "$P_CLI psk=badbad" \
            1

# Tests for extendedKeyUsage, part 2: client-side checking of server cert

run_test    "extKeyUsage cli: serverAuth -> OK" \
            "$O_SRV -key data_files/server5.key \
             -cert data_files/server5.eku-srv.crt" \
            "$P_CLI debug_level=1" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "extKeyUsage cli: serverAuth,clientAuth -> OK" \
            "$O_SRV -key data_files/server5.key \
             -cert data_files/server5.eku-srv_cli.crt" \
            "$P_CLI debug_level=1" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "extKeyUsage cli: codeSign,anyEKU -> OK" \
            "$O_SRV -key data_files/server5.key \
             -cert data_files/server5.eku-cs_any.crt" \
            "$P_CLI debug_level=1" \
            0 \
            -C "bad certificate (usage extensions)" \
            -C "Processing of the Certificate handshake message failed" \
            -c "Ciphersuite is TLS-"

run_test    "extKeyUsage cli: codeSign -> fail" \
            "$O_SRV -key data_files/server5.key \
             -cert data_files/server5.eku-cs.crt" \
            "$P_CLI debug_level=1" \
            1 \
            -c "bad certificate (usage extensions)" \
            -c "Processing of the Certificate handshake message failed" \
            -C "Ciphersuite is TLS-"

# Tests for extendedKeyUsage, part 3: server-side checking of client cert

run_test    "extKeyUsage cli-auth: clientAuth -> OK" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.eku-cli.crt" \
            0 \
            -S "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "extKeyUsage cli-auth: serverAuth,clientAuth -> OK" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.eku-srv_cli.crt" \
            0 \
            -S "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "extKeyUsage cli-auth: codeSign,anyEKU -> OK" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.eku-cs_any.crt" \
            0 \
            -S "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "extKeyUsage cli-auth: codeSign -> fail (soft)" \
            "$P_SRV debug_level=1 auth_mode=optional" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.eku-cs.crt" \
            0 \
            -s "bad certificate (usage extensions)" \
            -S "Processing of the Certificate handshake message failed"

run_test    "extKeyUsage cli-auth: codeSign -> fail (hard)" \
            "$P_SRV debug_level=1 auth_mode=required" \
            "$O_CLI -key data_files/server5.key \
             -cert data_files/server5.eku-cs.crt" \
            1 \
            -s "bad certificate (usage extensions)" \
            -s "Processing of the Certificate handshake message failed"

# Tests for DHM parameters loading

run_test    "DHM parameters: reference" \
            "$P_SRV" \
            "$P_CLI force_ciphersuite=TLS-DHE-RSA-WITH-AES-128-CBC-SHA \
                    debug_level=3" \
            0 \
            -c "value of 'DHM: P ' (2048 bits)" \
            -c "value of 'DHM: G ' (2048 bits)"

run_test    "DHM parameters: other parameters" \
            "$P_SRV dhm_file=data_files/dhparams.pem" \
            "$P_CLI force_ciphersuite=TLS-DHE-RSA-WITH-AES-128-CBC-SHA \
                    debug_level=3" \
            0 \
            -c "value of 'DHM: P ' (1024 bits)" \
            -c "value of 'DHM: G ' (2 bits)"

# Tests for PSK callback

run_test    "PSK callback: psk, no callback" \
            "$P_SRV psk=abc123 psk_identity=foo" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=foo psk=abc123" \
            0 \
            -S "SSL - The server has no ciphersuites in common" \
            -S "SSL - Unknown identity received" \
            -S "SSL - Verification of the message MAC failed"

run_test    "PSK callback: no psk, no callback" \
            "$P_SRV" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=foo psk=abc123" \
            1 \
            -s "SSL - The server has no ciphersuites in common" \
            -S "SSL - Unknown identity received" \
            -S "SSL - Verification of the message MAC failed"

run_test    "PSK callback: callback overrides other settings" \
            "$P_SRV psk=abc123 psk_identity=foo psk_list=abc,dead,def,beef" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=foo psk=abc123" \
            1 \
            -S "SSL - The server has no ciphersuites in common" \
            -s "SSL - Unknown identity received" \
            -S "SSL - Verification of the message MAC failed"

run_test    "PSK callback: first id matches" \
            "$P_SRV psk_list=abc,dead,def,beef" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=abc psk=dead" \
            0 \
            -S "SSL - The server has no ciphersuites in common" \
            -S "SSL - Unknown identity received" \
            -S "SSL - Verification of the message MAC failed"

run_test    "PSK callback: second id matches" \
            "$P_SRV psk_list=abc,dead,def,beef" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=def psk=beef" \
            0 \
            -S "SSL - The server has no ciphersuites in common" \
            -S "SSL - Unknown identity received" \
            -S "SSL - Verification of the message MAC failed"

run_test    "PSK callback: no match" \
            "$P_SRV psk_list=abc,dead,def,beef" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=ghi psk=beef" \
            1 \
            -S "SSL - The server has no ciphersuites in common" \
            -s "SSL - Unknown identity received" \
            -S "SSL - Verification of the message MAC failed"

run_test    "PSK callback: wrong key" \
            "$P_SRV psk_list=abc,dead,def,beef" \
            "$P_CLI force_ciphersuite=TLS-PSK-WITH-AES-128-CBC-SHA \
            psk_identity=abc psk=beef" \
            1 \
            -S "SSL - The server has no ciphersuites in common" \
            -S "SSL - Unknown identity received" \
            -s "SSL - Verification of the message MAC failed"

# Tests for ciphersuites per version

run_test    "Per-version suites: SSL3" \
            "$P_SRV version_suites=TLS-RSA-WITH-3DES-EDE-CBC-SHA,TLS-RSA-WITH-RC4-128-SHA,TLS-RSA-WITH-AES-128-CBC-SHA,TLS-RSA-WITH-AES-128-GCM-SHA256" \
            "$P_CLI force_version=ssl3" \
            0 \
            -c "Ciphersuite is TLS-RSA-WITH-3DES-EDE-CBC-SHA"

run_test    "Per-version suites: TLS 1.0" \
            "$P_SRV version_suites=TLS-RSA-WITH-3DES-EDE-CBC-SHA,TLS-RSA-WITH-RC4-128-SHA,TLS-RSA-WITH-AES-128-CBC-SHA,TLS-RSA-WITH-AES-128-GCM-SHA256" \
            "$P_CLI force_version=tls1" \
            0 \
            -c "Ciphersuite is TLS-RSA-WITH-RC4-128-SHA"

run_test    "Per-version suites: TLS 1.1" \
            "$P_SRV version_suites=TLS-RSA-WITH-3DES-EDE-CBC-SHA,TLS-RSA-WITH-RC4-128-SHA,TLS-RSA-WITH-AES-128-CBC-SHA,TLS-RSA-WITH-AES-128-GCM-SHA256" \
            "$P_CLI force_version=tls1_1" \
            0 \
            -c "Ciphersuite is TLS-RSA-WITH-AES-128-CBC-SHA"

run_test    "Per-version suites: TLS 1.2" \
            "$P_SRV version_suites=TLS-RSA-WITH-3DES-EDE-CBC-SHA,TLS-RSA-WITH-RC4-128-SHA,TLS-RSA-WITH-AES-128-CBC-SHA,TLS-RSA-WITH-AES-128-GCM-SHA256" \
            "$P_CLI force_version=tls1_2" \
            0 \
            -c "Ciphersuite is TLS-RSA-WITH-AES-128-GCM-SHA256"

# Tests for ssl_get_bytes_avail()

run_test    "ssl_get_bytes_avail: no extra data" \
            "$P_SRV" \
            "$P_CLI request_size=100" \
            0 \
            -s "Read from client: 100 bytes read$"

run_test    "ssl_get_bytes_avail: extra data" \
            "$P_SRV" \
            "$P_CLI request_size=500" \
            0 \
            -s "Read from client: 500 bytes read (.*+.*)"

# Tests for small packets

run_test    "Small packet SSLv3 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=ssl3 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet SSLv3 StreamCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=ssl3 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.0 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.0 BlockCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.0 StreamCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.1 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.1 StreamCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.1 BlockCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.1 StreamCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 BlockCipher larger MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 force_ciphersuite=TLS-ECDHE-RSA-WITH-AES-256-CBC-SHA384" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 BlockCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 StreamCipher" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 StreamCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 AEAD" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CCM" \
            0 \
            -s "Read from client: 1 bytes read"

run_test    "Small packet TLS 1.2 AEAD shorter tag" \
            "$P_SRV" \
            "$P_CLI request_size=1 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CCM-8" \
            0 \
            -s "Read from client: 1 bytes read"

# Test for large packets

run_test    "Large packet SSLv3 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=ssl3 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet SSLv3 StreamCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=ssl3 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.0 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.0 BlockCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.0 StreamCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.1 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.1 StreamCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.1 BlockCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.1 StreamCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_1 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 BlockCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 BlockCipher larger MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 force_ciphersuite=TLS-ECDHE-RSA-WITH-AES-256-CBC-SHA384" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 BlockCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CBC-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 StreamCipher" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 StreamCipher truncated MAC" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-RC4-128-SHA \
             trunc_hmac=1" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 AEAD" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CCM" \
            0 \
            -s "Read from client: 16384 bytes read"

run_test    "Large packet TLS 1.2 AEAD shorter tag" \
            "$P_SRV" \
            "$P_CLI request_size=16384 force_version=tls1_2 \
             force_ciphersuite=TLS-RSA-WITH-AES-256-CCM-8" \
            0 \
            -s "Read from client: 16384 bytes read"

# Final report

echo "------------------------------------------------------------------------"

if [ $FAILS = 0 ]; then
    echo -n "PASSED"
else
    echo -n "FAILED"
fi
PASSES=$(( $TESTS - $FAILS ))
echo " ($PASSES / $TESTS tests ($SKIPS skipped))"

exit $FAILS
