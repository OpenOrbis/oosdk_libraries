#!/bin/sh

# Test interop with OpenSSL and GnuTLS (and self-op while at it).
#
# Check each common ciphersuite, with each version, both ways (client/server),
# with and without client authentication.
#
# Peer version requirements:
# - OpenSSL 1.0.1e 11 Feb 2013 (probably since 1.0.1, tested with 1.0.1e)
# - GnuTLS 3.2.15 (probably works since 3.2.12 but tested only with 3.2.15)

set -u

# initialise counters
TESTS=0
FAILED=0
SKIPPED=0
SRVMEM=0

# default commands, can be overriden by the environment
: ${P_SRV:=../programs/ssl/ssl_server2}
: ${P_CLI:=../programs/ssl/ssl_client2}
: ${OPENSSL_CMD:=openssl} # OPENSSL would conflict with the build system
: ${GNUTLS_CLI:=gnutls-cli}
: ${GNUTLS_SERV:=gnutls-serv}

# do we have a recent enough GnuTLS?
if ( which $GNUTLS_CLI && which $GNUTLS_SERV ) >/dev/null; then
    eval $( $GNUTLS_CLI --version | head -n1 | sed 's/.* \([0-9]*\)\.\([0-9]\)*\.\([0-9]*\)$/MAJOR="\1" MINOR="\2" PATCH="\3"/' )
    if [ $MAJOR -lt 3 -o \
        \( $MAJOR -eq 3 -a $MINOR -lt 2 \) -o \
        \( $MAJOR -eq 3 -a $MINOR -eq 2 -a $PATCH -lt 15 \) ]
    then
        PEER_GNUTLS=""
    else
        PEER_GNUTLS=" GnuTLS"
    fi
else
    PEER_GNUTLS=""
fi

# default values for options
MODES="ssl3 tls1 tls1_1 tls1_2"
VERIFIES="NO YES"
TYPES="ECDSA RSA PSK"
FILTER=""
EXCLUDE='NULL\|DES-CBC-' # avoid plain DES but keep 3DES-EDE-CBC (PolarSSL), DES-CBC3 (OpenSSL)
VERBOSE=""
MEMCHECK=0
PEERS="OpenSSL$PEER_GNUTLS PolarSSL"

print_usage() {
    echo "Usage: $0"
    echo -e "  -h|--help\tPrint this help."
    echo -e "  -f|--filter\tOnly matching ciphersuites are tested (Default: '$FILTER')"
    echo -e "  -e|--exclude\tMatching ciphersuites are excluded (Default: '$EXCLUDE')"
    echo -e "  -m|--modes\tWhich modes to perform (Default: '$MODES')"
    echo -e "  -t|--types\tWhich key exchange type to perform (Default: '$TYPES')"
    echo -e "  -V|--verify\tWhich verification modes to perform (Default: '$VERIFIES')"
    echo -e "  -p|--peers\tWhich peers to use (Default: '$PEERS')"
    echo -e "            \tAlso available: GnuTLS (needs v3.2.15 or higher)"
    echo -e "  -M|--memcheck\tCheck memory leaks and errors."
    echo -e "  -v|--verbose\tSet verbose output."
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
            -m|--modes)
                shift; MODES=$1
                ;;
            -t|--types)
                shift; TYPES=$1
                ;;
            -V|--verify)
                shift; VERIFIES=$1
                ;;
            -p|--peers)
                shift; PEERS=$1
                ;;
            -v|--verbose)
                VERBOSE=1
                ;;
            -M|--memcheck)
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

log() {
  if [ "X" != "X$VERBOSE" ]; then
    echo "$@"
  fi
}

filter()
{
  LIST="$1"
  NEW_LIST=""

  for i in $LIST;
  do
    NEW_LIST="$NEW_LIST $( echo "$i" | grep "$FILTER" | grep -v "$EXCLUDE" )"
  done

  # normalize whitespace
  echo "$NEW_LIST" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'
}

filter_ciphersuites()
{
    if [ "X" != "X$FILTER" -o "X" != "X$EXCLUDE" ];
    then
        P_CIPHERS=$( filter "$P_CIPHERS" )
        O_CIPHERS=$( filter "$O_CIPHERS" )
        G_CIPHERS=$( filter "$G_CIPHERS" )
    fi
}

reset_ciphersuites()
{
    P_CIPHERS=""
    O_CIPHERS=""
    G_CIPHERS=""
}

add_common_ciphersuites()
{
    case $TYPE in

        "ECDSA")
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                       \
                    TLS-ECDHE-ECDSA-WITH-NULL-SHA           \
                    TLS-ECDHE-ECDSA-WITH-RC4-128-SHA        \
                    TLS-ECDHE-ECDSA-WITH-3DES-EDE-CBC-SHA   \
                    TLS-ECDHE-ECDSA-WITH-AES-128-CBC-SHA    \
                    TLS-ECDHE-ECDSA-WITH-AES-256-CBC-SHA    \
                    "
                G_CIPHERS="$G_CIPHERS                       \
                    +ECDHE-ECDSA:+NULL:+SHA1                \
                    +ECDHE-ECDSA:+ARCFOUR-128:+SHA1         \
                    +ECDHE-ECDSA:+3DES-CBC:+SHA1            \
                    +ECDHE-ECDSA:+AES-128-CBC:+SHA1         \
                    +ECDHE-ECDSA:+AES-256-CBC:+SHA1         \
                    "
                O_CIPHERS="$O_CIPHERS               \
                    ECDHE-ECDSA-NULL-SHA            \
                    ECDHE-ECDSA-RC4-SHA             \
                    ECDHE-ECDSA-DES-CBC3-SHA        \
                    ECDHE-ECDSA-AES128-SHA          \
                    ECDHE-ECDSA-AES256-SHA          \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-ECDHE-ECDSA-WITH-AES-128-CBC-SHA256         \
                    TLS-ECDHE-ECDSA-WITH-AES-256-CBC-SHA384         \
                    TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256         \
                    TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384         \
                    "
                G_CIPHERS="$G_CIPHERS                               \
                    +ECDHE-ECDSA:+AES-128-CBC:+SHA256               \
                    +ECDHE-ECDSA:+AES-256-CBC:+SHA384               \
                    +ECDHE-ECDSA:+AES-128-GCM:+AEAD                 \
                    +ECDHE-ECDSA:+AES-256-GCM:+AEAD                 \
                    "
                O_CIPHERS="$O_CIPHERS               \
                    ECDHE-ECDSA-AES128-SHA256       \
                    ECDHE-ECDSA-AES256-SHA384       \
                    ECDHE-ECDSA-AES128-GCM-SHA256   \
                    ECDHE-ECDSA-AES256-GCM-SHA384   \
                    "
            fi
            ;;

        "RSA")
            P_CIPHERS="$P_CIPHERS                       \
                TLS-DHE-RSA-WITH-AES-128-CBC-SHA        \
                TLS-DHE-RSA-WITH-AES-256-CBC-SHA        \
                TLS-DHE-RSA-WITH-CAMELLIA-128-CBC-SHA   \
                TLS-DHE-RSA-WITH-CAMELLIA-256-CBC-SHA   \
                TLS-DHE-RSA-WITH-3DES-EDE-CBC-SHA       \
                TLS-RSA-WITH-AES-256-CBC-SHA            \
                TLS-RSA-WITH-CAMELLIA-256-CBC-SHA       \
                TLS-RSA-WITH-AES-128-CBC-SHA            \
                TLS-RSA-WITH-CAMELLIA-128-CBC-SHA       \
                TLS-RSA-WITH-3DES-EDE-CBC-SHA           \
                TLS-RSA-WITH-RC4-128-SHA                \
                TLS-RSA-WITH-RC4-128-MD5                \
                TLS-RSA-WITH-NULL-MD5                   \
                TLS-RSA-WITH-NULL-SHA                   \
                "
            G_CIPHERS="$G_CIPHERS                       \
                +DHE-RSA:+AES-128-CBC:+SHA1             \
                +DHE-RSA:+AES-256-CBC:+SHA1             \
                +DHE-RSA:+CAMELLIA-128-CBC:+SHA1        \
                +DHE-RSA:+CAMELLIA-256-CBC:+SHA1        \
                +DHE-RSA:+3DES-CBC:+SHA1                \
                +RSA:+AES-256-CBC:+SHA1                 \
                +RSA:+CAMELLIA-256-CBC:+SHA1            \
                +RSA:+AES-128-CBC:+SHA1                 \
                +RSA:+CAMELLIA-128-CBC:+SHA1            \
                +RSA:+3DES-CBC:+SHA1                    \
                +RSA:+ARCFOUR-128:+SHA1                 \
                +RSA:+ARCFOUR-128:+MD5                  \
                +RSA:+NULL:+MD5                         \
                +RSA:+NULL:+SHA1                        \
                "
            O_CIPHERS="$O_CIPHERS               \
                DHE-RSA-AES128-SHA              \
                DHE-RSA-AES256-SHA              \
                DHE-RSA-CAMELLIA128-SHA         \
                DHE-RSA-CAMELLIA256-SHA         \
                EDH-RSA-DES-CBC3-SHA            \
                AES256-SHA                      \
                CAMELLIA256-SHA                 \
                AES128-SHA                      \
                CAMELLIA128-SHA                 \
                DES-CBC3-SHA                    \
                RC4-SHA                         \
                RC4-MD5                         \
                NULL-MD5                        \
                NULL-SHA                        \
                "
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                       \
                    TLS-ECDHE-RSA-WITH-AES-128-CBC-SHA      \
                    TLS-ECDHE-RSA-WITH-AES-256-CBC-SHA      \
                    TLS-ECDHE-RSA-WITH-3DES-EDE-CBC-SHA     \
                    TLS-ECDHE-RSA-WITH-RC4-128-SHA          \
                    TLS-ECDHE-RSA-WITH-NULL-SHA             \
                    "
                G_CIPHERS="$G_CIPHERS                       \
                    +ECDHE-RSA:+AES-128-CBC:+SHA1           \
                    +ECDHE-RSA:+AES-256-CBC:+SHA1           \
                    +ECDHE-RSA:+3DES-CBC:+SHA1              \
                    +ECDHE-RSA:+ARCFOUR-128:+SHA1           \
                    +ECDHE-RSA:+NULL:+SHA1                  \
                    "
                O_CIPHERS="$O_CIPHERS               \
                    ECDHE-RSA-AES256-SHA            \
                    ECDHE-RSA-AES128-SHA            \
                    ECDHE-RSA-DES-CBC3-SHA          \
                    ECDHE-RSA-RC4-SHA               \
                    ECDHE-RSA-NULL-SHA              \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                       \
                    TLS-RSA-WITH-AES-128-CBC-SHA256         \
                    TLS-DHE-RSA-WITH-AES-128-CBC-SHA256     \
                    TLS-RSA-WITH-AES-256-CBC-SHA256         \
                    TLS-DHE-RSA-WITH-AES-256-CBC-SHA256     \
                    TLS-ECDHE-RSA-WITH-AES-128-CBC-SHA256   \
                    TLS-ECDHE-RSA-WITH-AES-256-CBC-SHA384   \
                    TLS-RSA-WITH-AES-128-GCM-SHA256         \
                    TLS-RSA-WITH-AES-256-GCM-SHA384         \
                    TLS-DHE-RSA-WITH-AES-128-GCM-SHA256     \
                    TLS-DHE-RSA-WITH-AES-256-GCM-SHA384     \
                    TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256   \
                    TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384   \
                    "
                G_CIPHERS="$G_CIPHERS                       \
                    +RSA:+AES-128-CBC:+SHA256               \
                    +DHE-RSA:+AES-128-CBC:+SHA256           \
                    +RSA:+AES-256-CBC:+SHA256               \
                    +DHE-RSA:+AES-256-CBC:+SHA256           \
                    +ECDHE-RSA:+AES-128-CBC:+SHA256         \
                    +ECDHE-RSA:+AES-256-CBC:+SHA384         \
                    +RSA:+AES-128-GCM:+AEAD                 \
                    +RSA:+AES-256-GCM:+AEAD                 \
                    +DHE-RSA:+AES-128-GCM:+AEAD             \
                    +DHE-RSA:+AES-256-GCM:+AEAD             \
                    +ECDHE-RSA:+AES-128-GCM:+AEAD           \
                    +ECDHE-RSA:+AES-256-GCM:+AEAD           \
                    "
                O_CIPHERS="$O_CIPHERS           \
                    NULL-SHA256                 \
                    AES128-SHA256               \
                    DHE-RSA-AES128-SHA256       \
                    AES256-SHA256               \
                    DHE-RSA-AES256-SHA256       \
                    ECDHE-RSA-AES128-SHA256     \
                    ECDHE-RSA-AES256-SHA384     \
                    AES128-GCM-SHA256           \
                    DHE-RSA-AES128-GCM-SHA256   \
                    AES256-GCM-SHA384           \
                    DHE-RSA-AES256-GCM-SHA384   \
                    ECDHE-RSA-AES128-GCM-SHA256 \
                    ECDHE-RSA-AES256-GCM-SHA384 \
                    "
            fi
            ;;

        "PSK")
            P_CIPHERS="$P_CIPHERS                       \
                TLS-PSK-WITH-RC4-128-SHA                \
                TLS-PSK-WITH-3DES-EDE-CBC-SHA           \
                TLS-PSK-WITH-AES-128-CBC-SHA            \
                TLS-PSK-WITH-AES-256-CBC-SHA            \
                "
            G_CIPHERS="$G_CIPHERS                       \
                +PSK:+ARCFOUR-128:+SHA1                 \
                +PSK:+3DES-CBC:+SHA1                    \
                +PSK:+AES-128-CBC:+SHA1                 \
                +PSK:+AES-256-CBC:+SHA1                 \
                "
            O_CIPHERS="$O_CIPHERS               \
                PSK-RC4-SHA                     \
                PSK-3DES-EDE-CBC-SHA            \
                PSK-AES128-CBC-SHA              \
                PSK-AES256-CBC-SHA              \
                "
            ;;
    esac
}

add_openssl_ciphersuites()
{
    case $TYPE in

        "ECDSA")
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                       \
                    TLS-ECDH-ECDSA-WITH-NULL-SHA            \
                    TLS-ECDH-ECDSA-WITH-RC4-128-SHA         \
                    TLS-ECDH-ECDSA-WITH-3DES-EDE-CBC-SHA    \
                    TLS-ECDH-ECDSA-WITH-AES-128-CBC-SHA     \
                    TLS-ECDH-ECDSA-WITH-AES-256-CBC-SHA     \
                    "
                O_CIPHERS="$O_CIPHERS               \
                    ECDH-ECDSA-NULL-SHA             \
                    ECDH-ECDSA-RC4-SHA              \
                    ECDH-ECDSA-DES-CBC3-SHA         \
                    ECDH-ECDSA-AES128-SHA           \
                    ECDH-ECDSA-AES256-SHA           \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-ECDH-ECDSA-WITH-AES-128-CBC-SHA256          \
                    TLS-ECDH-ECDSA-WITH-AES-256-CBC-SHA384          \
                    TLS-ECDH-ECDSA-WITH-AES-128-GCM-SHA256          \
                    TLS-ECDH-ECDSA-WITH-AES-256-GCM-SHA384          \
                    "
                O_CIPHERS="$O_CIPHERS               \
                    ECDH-ECDSA-AES128-SHA256        \
                    ECDH-ECDSA-AES256-SHA384        \
                    ECDH-ECDSA-AES128-GCM-SHA256    \
                    ECDH-ECDSA-AES256-GCM-SHA384    \
                    "
            fi
            ;;

        "RSA")
            P_CIPHERS="$P_CIPHERS                       \
                TLS-RSA-WITH-DES-CBC-SHA                \
                TLS-DHE-RSA-WITH-DES-CBC-SHA            \
                "
            O_CIPHERS="$O_CIPHERS               \
                DES-CBC-SHA                     \
                EDH-RSA-DES-CBC-SHA             \
                "
            ;;

        "PSK")
            ;;
    esac
}

add_gnutls_ciphersuites()
{
    case $TYPE in

        "ECDSA")
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-ECDHE-ECDSA-WITH-CAMELLIA-128-CBC-SHA256    \
                    TLS-ECDHE-ECDSA-WITH-CAMELLIA-256-CBC-SHA384    \
                    TLS-ECDHE-ECDSA-WITH-CAMELLIA-128-GCM-SHA256    \
                    TLS-ECDHE-ECDSA-WITH-CAMELLIA-256-GCM-SHA384    \
                   "
                G_CIPHERS="$G_CIPHERS                               \
                    +ECDHE-ECDSA:+CAMELLIA-128-CBC:+SHA256          \
                    +ECDHE-ECDSA:+CAMELLIA-256-CBC:+SHA384          \
                    +ECDHE-ECDSA:+CAMELLIA-128-GCM:+AEAD            \
                    +ECDHE-ECDSA:+CAMELLIA-256-GCM:+AEAD            \
                   "
            fi
            ;;

        "RSA")
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                           \
                    TLS-RSA-WITH-NULL-SHA256                    \
                    "
                G_CIPHERS="$G_CIPHERS                           \
                    +RSA:+NULL:+SHA256                          \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                           \
                    TLS-ECDHE-RSA-WITH-CAMELLIA-128-CBC-SHA256  \
                    TLS-ECDHE-RSA-WITH-CAMELLIA-256-CBC-SHA384  \
                    TLS-RSA-WITH-CAMELLIA-128-CBC-SHA256        \
                    TLS-RSA-WITH-CAMELLIA-256-CBC-SHA256        \
                    TLS-DHE-RSA-WITH-CAMELLIA-128-CBC-SHA256    \
                    TLS-DHE-RSA-WITH-CAMELLIA-256-CBC-SHA256    \
                    TLS-ECDHE-RSA-WITH-CAMELLIA-128-GCM-SHA256  \
                    TLS-ECDHE-RSA-WITH-CAMELLIA-256-GCM-SHA384  \
                    TLS-DHE-RSA-WITH-CAMELLIA-128-GCM-SHA256    \
                    TLS-DHE-RSA-WITH-CAMELLIA-256-GCM-SHA384    \
                    TLS-RSA-WITH-CAMELLIA-128-GCM-SHA256        \
                    TLS-RSA-WITH-CAMELLIA-256-GCM-SHA384        \
                    "
                G_CIPHERS="$G_CIPHERS                           \
                    +ECDHE-RSA:+CAMELLIA-128-CBC:+SHA256        \
                    +ECDHE-RSA:+CAMELLIA-256-CBC:+SHA384        \
                    +RSA:+CAMELLIA-128-CBC:+SHA256              \
                    +RSA:+CAMELLIA-256-CBC:+SHA256              \
                    +DHE-RSA:+CAMELLIA-128-CBC:+SHA256          \
                    +DHE-RSA:+CAMELLIA-256-CBC:+SHA256          \
                    +ECDHE-RSA:+CAMELLIA-128-GCM:+AEAD          \
                    +ECDHE-RSA:+CAMELLIA-256-GCM:+AEAD          \
                    +DHE-RSA:+CAMELLIA-128-GCM:+AEAD            \
                    +DHE-RSA:+CAMELLIA-256-GCM:+AEAD            \
                    +RSA:+CAMELLIA-128-GCM:+AEAD                \
                    +RSA:+CAMELLIA-256-GCM:+AEAD                \
                    "
            fi
            ;;

        "PSK")
            P_CIPHERS="$P_CIPHERS                               \
                TLS-DHE-PSK-WITH-3DES-EDE-CBC-SHA               \
                TLS-DHE-PSK-WITH-AES-128-CBC-SHA                \
                TLS-DHE-PSK-WITH-AES-256-CBC-SHA                \
                TLS-DHE-PSK-WITH-RC4-128-SHA                    \
                "
            G_CIPHERS="$G_CIPHERS                               \
                +DHE-PSK:+3DES-CBC:+SHA1                        \
                +DHE-PSK:+AES-128-CBC:+SHA1                     \
                +DHE-PSK:+AES-256-CBC:+SHA1                     \
                +DHE-PSK:+ARCFOUR-128:+SHA1                     \
                "
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                           \
                    TLS-ECDHE-PSK-WITH-AES-256-CBC-SHA          \
                    TLS-ECDHE-PSK-WITH-AES-128-CBC-SHA          \
                    TLS-ECDHE-PSK-WITH-3DES-EDE-CBC-SHA         \
                    TLS-ECDHE-PSK-WITH-RC4-128-SHA              \
                    TLS-RSA-PSK-WITH-3DES-EDE-CBC-SHA           \
                    TLS-RSA-PSK-WITH-AES-256-CBC-SHA            \
                    TLS-RSA-PSK-WITH-AES-128-CBC-SHA            \
                    TLS-RSA-PSK-WITH-RC4-128-SHA                \
                    "
                G_CIPHERS="$G_CIPHERS                           \
                    +ECDHE-PSK:+3DES-CBC:+SHA1                  \
                    +ECDHE-PSK:+AES-128-CBC:+SHA1               \
                    +ECDHE-PSK:+AES-256-CBC:+SHA1               \
                    +ECDHE-PSK:+ARCFOUR-128:+SHA1               \
                    +RSA-PSK:+3DES-CBC:+SHA1                    \
                    +RSA-PSK:+AES-256-CBC:+SHA1                 \
                    +RSA-PSK:+AES-128-CBC:+SHA1                 \
                    +RSA-PSK:+ARCFOUR-128:+SHA1                 \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                           \
                    TLS-ECDHE-PSK-WITH-AES-256-CBC-SHA384       \
                    TLS-ECDHE-PSK-WITH-CAMELLIA-256-CBC-SHA384  \
                    TLS-ECDHE-PSK-WITH-AES-128-CBC-SHA256       \
                    TLS-ECDHE-PSK-WITH-CAMELLIA-128-CBC-SHA256  \
                    TLS-ECDHE-PSK-WITH-NULL-SHA384              \
                    TLS-ECDHE-PSK-WITH-NULL-SHA256              \
                    TLS-PSK-WITH-AES-128-CBC-SHA256             \
                    TLS-PSK-WITH-AES-256-CBC-SHA384             \
                    TLS-DHE-PSK-WITH-AES-128-CBC-SHA256         \
                    TLS-DHE-PSK-WITH-AES-256-CBC-SHA384         \
                    TLS-PSK-WITH-NULL-SHA256                    \
                    TLS-PSK-WITH-NULL-SHA384                    \
                    TLS-DHE-PSK-WITH-NULL-SHA256                \
                    TLS-DHE-PSK-WITH-NULL-SHA384                \
                    TLS-RSA-PSK-WITH-AES-256-CBC-SHA384         \
                    TLS-RSA-PSK-WITH-AES-128-CBC-SHA256         \
                    TLS-RSA-PSK-WITH-NULL-SHA256                \
                    TLS-RSA-PSK-WITH-NULL-SHA384                \
                    TLS-DHE-PSK-WITH-CAMELLIA-128-CBC-SHA256    \
                    TLS-DHE-PSK-WITH-CAMELLIA-256-CBC-SHA384    \
                    TLS-PSK-WITH-CAMELLIA-128-CBC-SHA256        \
                    TLS-PSK-WITH-CAMELLIA-256-CBC-SHA384        \
                    TLS-RSA-PSK-WITH-CAMELLIA-256-CBC-SHA384    \
                    TLS-RSA-PSK-WITH-CAMELLIA-128-CBC-SHA256    \
                    TLS-PSK-WITH-AES-128-GCM-SHA256             \
                    TLS-PSK-WITH-AES-256-GCM-SHA384             \
                    TLS-DHE-PSK-WITH-AES-128-GCM-SHA256         \
                    TLS-DHE-PSK-WITH-AES-256-GCM-SHA384         \
                    TLS-RSA-PSK-WITH-CAMELLIA-128-GCM-SHA256    \
                    TLS-RSA-PSK-WITH-CAMELLIA-256-GCM-SHA384    \
                    TLS-PSK-WITH-CAMELLIA-128-GCM-SHA256        \
                    TLS-PSK-WITH-CAMELLIA-256-GCM-SHA384        \
                    TLS-DHE-PSK-WITH-CAMELLIA-128-GCM-SHA256    \
                    TLS-DHE-PSK-WITH-CAMELLIA-256-GCM-SHA384    \
                    TLS-RSA-PSK-WITH-AES-256-GCM-SHA384         \
                    TLS-RSA-PSK-WITH-AES-128-GCM-SHA256         \
                    "
                G_CIPHERS="$G_CIPHERS                           \
                    +ECDHE-PSK:+AES-256-CBC:+SHA384             \
                    +ECDHE-PSK:+CAMELLIA-256-CBC:+SHA384        \
                    +ECDHE-PSK:+AES-128-CBC:+SHA256             \
                    +ECDHE-PSK:+CAMELLIA-128-CBC:+SHA256        \
                    +PSK:+AES-128-CBC:+SHA256                   \
                    +PSK:+AES-256-CBC:+SHA384                   \
                    +DHE-PSK:+AES-128-CBC:+SHA256               \
                    +DHE-PSK:+AES-256-CBC:+SHA384               \
                    +RSA-PSK:+AES-256-CBC:+SHA384               \
                    +RSA-PSK:+AES-128-CBC:+SHA256               \
                    +DHE-PSK:+CAMELLIA-128-CBC:+SHA256          \
                    +DHE-PSK:+CAMELLIA-256-CBC:+SHA384          \
                    +PSK:+CAMELLIA-128-CBC:+SHA256              \
                    +PSK:+CAMELLIA-256-CBC:+SHA384              \
                    +RSA-PSK:+CAMELLIA-256-CBC:+SHA384          \
                    +RSA-PSK:+CAMELLIA-128-CBC:+SHA256          \
                    +PSK:+AES-128-GCM:+AEAD                     \
                    +PSK:+AES-256-GCM:+AEAD                     \
                    +DHE-PSK:+AES-128-GCM:+AEAD                 \
                    +DHE-PSK:+AES-256-GCM:+AEAD                 \
                    +RSA-PSK:+CAMELLIA-128-GCM:+AEAD            \
                    +RSA-PSK:+CAMELLIA-256-GCM:+AEAD            \
                    +PSK:+CAMELLIA-128-GCM:+AEAD                \
                    +PSK:+CAMELLIA-256-GCM:+AEAD                \
                    +DHE-PSK:+CAMELLIA-128-GCM:+AEAD            \
                    +DHE-PSK:+CAMELLIA-256-GCM:+AEAD            \
                    +RSA-PSK:+AES-256-GCM:+AEAD                 \
                    +RSA-PSK:+AES-128-GCM:+AEAD                 \
                    +ECDHE-PSK:+NULL:+SHA384                    \
                    +ECDHE-PSK:+NULL:+SHA256                    \
                    +PSK:+NULL:+SHA256                          \
                    +PSK:+NULL:+SHA384                          \
                    +DHE-PSK:+NULL:+SHA256                      \
                    +DHE-PSK:+NULL:+SHA384                      \
                    +RSA-PSK:+NULL:+SHA256                      \
                    +RSA-PSK:+NULL:+SHA384                      \
                    "
            fi
            ;;
    esac
}

add_polarssl_ciphersuites()
{
    case $TYPE in

        "ECDSA")
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-ECDH-ECDSA-WITH-CAMELLIA-128-CBC-SHA256     \
                    TLS-ECDH-ECDSA-WITH-CAMELLIA-256-CBC-SHA384     \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-ECDH-ECDSA-WITH-CAMELLIA-128-GCM-SHA256     \
                    TLS-ECDH-ECDSA-WITH-CAMELLIA-256-GCM-SHA384     \
                    TLS-ECDHE-ECDSA-WITH-AES-128-CCM                \
                    TLS-ECDHE-ECDSA-WITH-AES-256-CCM                \
                    TLS-ECDHE-ECDSA-WITH-AES-128-CCM-8              \
                    TLS-ECDHE-ECDSA-WITH-AES-256-CCM-8              \
                    "
            fi
            ;;

        "RSA")
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-RSA-WITH-AES-128-CCM                        \
                    TLS-RSA-WITH-AES-256-CCM                        \
                    TLS-DHE-RSA-WITH-AES-128-CCM                    \
                    TLS-DHE-RSA-WITH-AES-256-CCM                    \
                    TLS-RSA-WITH-AES-128-CCM-8                      \
                    TLS-RSA-WITH-AES-256-CCM-8                      \
                    TLS-DHE-RSA-WITH-AES-128-CCM-8                  \
                    TLS-DHE-RSA-WITH-AES-256-CCM-8                  \
                    "
            fi
            ;;

        "PSK")
            # *PKS-NULL-SHA suites supported by GnuTLS 3.3.5 but not 3.2.15
            P_CIPHERS="$P_CIPHERS                        \
                TLS-PSK-WITH-NULL-SHA                    \
                TLS-DHE-PSK-WITH-NULL-SHA                \
                "
            if [ "$MODE" != "ssl3" ];
            then
                P_CIPHERS="$P_CIPHERS                    \
                    TLS-ECDHE-PSK-WITH-NULL-SHA          \
                    TLS-RSA-PSK-WITH-NULL-SHA            \
                    "
            fi
            if [ "$MODE" = "tls1_2" ];
            then
                P_CIPHERS="$P_CIPHERS                               \
                    TLS-PSK-WITH-AES-128-CCM                        \
                    TLS-PSK-WITH-AES-256-CCM                        \
                    TLS-DHE-PSK-WITH-AES-128-CCM                    \
                    TLS-DHE-PSK-WITH-AES-256-CCM                    \
                    TLS-PSK-WITH-AES-128-CCM-8                      \
                    TLS-PSK-WITH-AES-256-CCM-8                      \
                    TLS-DHE-PSK-WITH-AES-128-CCM-8                  \
                    TLS-DHE-PSK-WITH-AES-256-CCM-8                  \
                    "
            fi
            ;;
    esac
}

setup_arguments()
{
    case $MODE in
        "ssl3")
            G_PRIO_MODE="+VERS-SSL3.0"
            ;;
        "tls1")
            G_PRIO_MODE="+VERS-TLS1.0"
            ;;
        "tls1_1")
            G_PRIO_MODE="+VERS-TLS1.1"
            ;;
        "tls1_2")
            G_PRIO_MODE="+VERS-TLS1.2"
            ;;
        *)
            echo "error: invalid mode: $MODE" >&2
            exit 1;
    esac

    P_SERVER_ARGS="server_port=$PORT server_addr=0.0.0.0 force_version=$MODE"
    O_SERVER_ARGS="-accept $PORT -www -cipher NULL,ALL -$MODE"
    G_SERVER_ARGS="-p $PORT --http"
    G_SERVER_PRIO="EXPORT:+NULL:+MD5:+PSK:+DHE-PSK:+ECDHE-PSK:+RSA-PSK:-VERS-TLS-ALL:$G_PRIO_MODE"

    P_CLIENT_ARGS="server_port=$PORT force_version=$MODE"
    O_CLIENT_ARGS="-connect localhost:$PORT -$MODE"
    G_CLIENT_ARGS="-p $PORT --debug 3"
    G_CLIENT_PRIO="NONE:$G_PRIO_MODE:+COMP-NULL:+CURVE-ALL:+SIGN-ALL"

    if [ "X$VERIFY" = "XYES" ];
    then
        P_SERVER_ARGS="$P_SERVER_ARGS ca_file=data_files/test-ca_cat12.crt auth_mode=required"
        O_SERVER_ARGS="$O_SERVER_ARGS -CAfile data_files/test-ca_cat12.crt -Verify 10"
        G_SERVER_ARGS="$G_SERVER_ARGS --x509cafile data_files/test-ca_cat12.crt --require-client-cert"

        P_CLIENT_ARGS="$P_CLIENT_ARGS ca_file=data_files/test-ca_cat12.crt auth_mode=required"
        O_CLIENT_ARGS="$O_CLIENT_ARGS -CAfile data_files/test-ca_cat12.crt -verify 10"
        G_CLIENT_ARGS="$G_CLIENT_ARGS --x509cafile data_files/test-ca_cat12.crt"
    else
        # don't request a client cert at all
        P_SERVER_ARGS="$P_SERVER_ARGS ca_file=none auth_mode=none"
        G_SERVER_ARGS="$G_SERVER_ARGS --disable-client-cert"

        P_CLIENT_ARGS="$P_CLIENT_ARGS ca_file=none auth_mode=none"
        O_CLIENT_ARGS="$O_CLIENT_ARGS"
        G_CLIENT_ARGS="$G_CLIENT_ARGS --insecure"
    fi

    case $TYPE in
        "ECDSA")
            P_SERVER_ARGS="$P_SERVER_ARGS crt_file=data_files/server5.crt key_file=data_files/server5.key"
            O_SERVER_ARGS="$O_SERVER_ARGS -cert data_files/server5.crt -key data_files/server5.key"
            G_SERVER_ARGS="$G_SERVER_ARGS --x509certfile data_files/server5.crt --x509keyfile data_files/server5.key"

            if [ "X$VERIFY" = "XYES" ]; then
                P_CLIENT_ARGS="$P_CLIENT_ARGS crt_file=data_files/server6.crt key_file=data_files/server6.key"
                O_CLIENT_ARGS="$O_CLIENT_ARGS -cert data_files/server6.crt -key data_files/server6.key"
                G_CLIENT_ARGS="$G_CLIENT_ARGS --x509certfile data_files/server6.crt --x509keyfile data_files/server6.key"
            else
                P_CLIENT_ARGS="$P_CLIENT_ARGS crt_file=none key_file=none"
            fi
            ;;

        "RSA")
            P_SERVER_ARGS="$P_SERVER_ARGS crt_file=data_files/server2.crt key_file=data_files/server2.key"
            O_SERVER_ARGS="$O_SERVER_ARGS -cert data_files/server2.crt -key data_files/server2.key"
            G_SERVER_ARGS="$G_SERVER_ARGS --x509certfile data_files/server2.crt --x509keyfile data_files/server2.key"

            if [ "X$VERIFY" = "XYES" ]; then
                P_CLIENT_ARGS="$P_CLIENT_ARGS crt_file=data_files/server1.crt key_file=data_files/server1.key"
                O_CLIENT_ARGS="$O_CLIENT_ARGS -cert data_files/server1.crt -key data_files/server1.key"
                G_CLIENT_ARGS="$G_CLIENT_ARGS --x509certfile data_files/server1.crt --x509keyfile data_files/server1.key"
            else
                P_CLIENT_ARGS="$P_CLIENT_ARGS crt_file=none key_file=none"
            fi
            ;;

        "PSK")
            # give RSA-PSK-capable server a RSA cert
            # (should be a separate type, but harder to close with openssl)
            P_SERVER_ARGS="$P_SERVER_ARGS psk=6162636465666768696a6b6c6d6e6f70 ca_file=none crt_file=data_files/server2.crt key_file=data_files/server2.key"
            O_SERVER_ARGS="$O_SERVER_ARGS -psk 6162636465666768696a6b6c6d6e6f70 -nocert"
            G_SERVER_ARGS="$G_SERVER_ARGS --x509certfile data_files/server2.crt --x509keyfile data_files/server2.key --pskpasswd data_files/passwd.psk"

            P_CLIENT_ARGS="$P_CLIENT_ARGS psk=6162636465666768696a6b6c6d6e6f70 crt_file=none key_file=none"
            O_CLIENT_ARGS="$O_CLIENT_ARGS -psk 6162636465666768696a6b6c6d6e6f70"
            G_CLIENT_ARGS="$G_CLIENT_ARGS --pskusername Client_identity --pskkey=6162636465666768696a6b6c6d6e6f70"
            ;;
    esac
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

# start_server <name>
# also saves name and command
start_server() {
    case $1 in
        [Oo]pen*)
            SERVER_CMD="$OPENSSL_CMD s_server $O_SERVER_ARGS"
            ;;
        [Gg]nu*)
            SERVER_CMD="$GNUTLS_SERV $G_SERVER_ARGS --priority $G_SERVER_PRIO"
            ;;
        [Pp]olar*)
            SERVER_CMD="$P_SRV $P_SERVER_ARGS"
            if [ "$MEMCHECK" -gt 0 ]; then
                SERVER_CMD="valgrind --leak-check=full $SERVER_CMD"
            fi
            ;;
        *)
            echo "error: invalid server name: $1" >&2
            exit 1
            ;;
    esac
    SERVER_NAME=$1

    log "$SERVER_CMD"
    echo "$SERVER_CMD" > $SRV_OUT
    $SERVER_CMD >> $SRV_OUT 2>&1 &
    PROCESS_ID=$!

    sleep 1
}

# terminate the running server
stop_server() {
    kill $PROCESS_ID 2>/dev/null
    wait $PROCESS_ID 2>/dev/null

    if [ "$MEMCHECK" -gt 0 ]; then
        if is_polar "$SERVER_CMD" && has_mem_err $SRV_OUT; then
            echo "  ! Server had memory errors"
            SRVMEM=$(( $SRVMEM + 1 ))
            return
        fi
    fi

    rm -f $SRV_OUT
}

# kill the running server (used when killed by signal)
cleanup() {
    rm -f $SRV_OUT $CLI_OUT
    kill $PROCESS_ID >/dev/null 2>&1
    kill $WATCHDOG_PID >/dev/null 2>&1
    exit 1
}

# wait for client to terminate and set EXIT
# must be called right after starting the client
wait_client_done() {
    CLI_PID=$!

    ( sleep "$DOG_DELAY"; echo "TIMEOUT" >> $CLI_OUT; kill $CLI_PID ) &
    WATCHDOG_PID=$!

    wait $CLI_PID
    EXIT=$?

    kill $WATCHDOG_PID
    wait $WATCHDOG_PID

    echo "EXIT: $EXIT" >> $CLI_OUT
}

# run_client <name> <cipher>
run_client() {
    # announce what we're going to do
    TESTS=$(( $TESTS + 1 ))
    VERIF=$(echo $VERIFY | tr '[:upper:]' '[:lower:]')
    TITLE="`echo $1 | head -c1`->`echo $SERVER_NAME | head -c1`"
    TITLE="$TITLE $MODE,$VERIF $2"
    echo -n "$TITLE "
    LEN=$(( 72 - `echo "$TITLE" | wc -c` ))
    for i in `seq 1 $LEN`; do echo -n '.'; done; echo -n ' '

    # run the command and interpret result
    case $1 in
        [Oo]pen*)
            CLIENT_CMD="$OPENSSL_CMD s_client $O_CLIENT_ARGS -cipher $2"
            log "$CLIENT_CMD"
            echo "$CLIENT_CMD" > $CLI_OUT
            ( echo -e 'GET HTTP/1.0'; echo; ) | $CLIENT_CMD >> $CLI_OUT 2>&1 &
            wait_client_done

            if [ $EXIT -eq 0 ]; then
                RESULT=0
            else
                if grep 'Cipher is (NONE)' $CLI_OUT >/dev/null; then
                    RESULT=1
                else
                    RESULT=2
                fi
            fi
            ;;

        [Gg]nu*)
            CLIENT_CMD="$GNUTLS_CLI $G_CLIENT_ARGS --priority $G_PRIO_MODE:$2 localhost"
            log "$CLIENT_CMD"
            echo "$CLIENT_CMD" > $CLI_OUT
            ( echo -e 'GET HTTP/1.0'; echo; ) | $CLIENT_CMD >> $CLI_OUT 2>&1 &
            wait_client_done

            if [ $EXIT -eq 0 ]; then
                RESULT=0
            else
                RESULT=2
                # interpret early failure, with a handshake_failure alert
                # before the server hello, as "no ciphersuite in common"
                if grep -F 'Received alert [40]: Handshake failed' $CLI_OUT; then
                    if grep -i 'SERVER HELLO .* was received' $CLI_OUT; then :
                    else
                        RESULT=1
                    fi
                fi >/dev/null
            fi
            ;;

        [Pp]olar*)
            CLIENT_CMD="$P_CLI $P_CLIENT_ARGS force_ciphersuite=$2"
            if [ "$MEMCHECK" -gt 0 ]; then
                CLIENT_CMD="valgrind --leak-check=full $CLIENT_CMD"
            fi
            log "$CLIENT_CMD"
            echo "$CLIENT_CMD" > $CLI_OUT
            $CLIENT_CMD >> $CLI_OUT 2>&1 &
            wait_client_done

            case $EXIT in
                "0")    RESULT=0    ;;
                "2")    RESULT=1    ;;
                *)      RESULT=2    ;;
            esac

            if [ "$MEMCHECK" -gt 0 ]; then
                if is_polar "$CLIENT_CMD" && has_mem_err $CLI_OUT; then
                    RESULT=2
                fi
            fi

            ;;

        *)
            echo "error: invalid client name: $1" >&2
            exit 1
            ;;
    esac

    echo "EXIT: $EXIT" >> $CLI_OUT

    # report and count result
    case $RESULT in
        "0")
            echo PASS
            ;;
        "1")
            echo SKIP
            SKIPPED=$(( $SKIPPED + 1 ))
            ;;
        "2")
            echo FAIL
            cp $SRV_OUT c-srv-${TESTS}.log
            cp $CLI_OUT c-cli-${TESTS}.log
            echo "  ! outputs saved to c-srv-${TESTS}.log, c-cli-${TESTS}.log"

            if [ "X${USER:-}" = Xbuildbot -o "X${LOGNAME:-}" = Xbuildbot ]; then
                echo "  ! server output:"
                cat c-srv-${TESTS}.log
                echo "  ! ==================================================="
                echo "  ! client output:"
                cat c-cli-${TESTS}.log
            fi

            FAILED=$(( $FAILED + 1 ))
            ;;
    esac

    rm -f $CLI_OUT
}

#
# MAIN
#

get_options "$@"

# sanity checks, avoid an avalanche of errors
if [ ! -x "$P_SRV" ]; then
    echo "Command '$P_SRV' is not an executable file" >&2
    exit 1
fi
if [ ! -x "$P_CLI" ]; then
    echo "Command '$P_CLI' is not an executable file" >&2
    exit 1
fi

if echo "$PEERS" | grep -i openssl > /dev/null; then
    if which "$OPENSSL_CMD" >/dev/null 2>&1; then :; else
        echo "Command '$OPENSSL_CMD' not found" >&2
        exit 1
    fi
fi

if echo "$PEERS" | grep -i gnutls > /dev/null; then
    for CMD in "$GNUTLS_CLI" "$GNUTLS_SERV"; do
        if which "$CMD" >/dev/null 2>&1; then :; else
            echo "Command '$CMD' not found" >&2
            exit 1
        fi
    done
fi

for PEER in $PEERS; do
    case "$PEER" in
        [Pp]olar*|[Oo]pen*|[Gg]nu*)
            ;;
        *)
            echo "Unknown peers: $PEER" >&2
            exit 1
    esac
done

# Pick a "unique" port in the range 10000-19999.
PORT="0000$$"
PORT="1$(echo $PORT | tail -c 5)"

# Also pick a unique name for intermediate files
SRV_OUT="srv_out.$$"
CLI_OUT="cli_out.$$"

# client timeout delay: be more patient with valgrind
if [ "$MEMCHECK" -gt 0 ]; then
    DOG_DELAY=30
else
    DOG_DELAY=10
fi

trap cleanup INT TERM HUP

for VERIFY in $VERIFIES; do
    for MODE in $MODES; do
        for TYPE in $TYPES; do
            for PEER in $PEERS; do

            setup_arguments

            case "$PEER" in

                [Oo]pen*)

                    reset_ciphersuites
                    add_common_ciphersuites
                    add_openssl_ciphersuites
                    filter_ciphersuites

                    if [ "X" != "X$P_CIPHERS" ]; then
                        start_server "OpenSSL"
                        for i in $P_CIPHERS; do
                            run_client PolarSSL $i
                        done
                        stop_server
                    fi

                    if [ "X" != "X$O_CIPHERS" ]; then
                        start_server "PolarSSL"
                        for i in $O_CIPHERS; do
                            run_client OpenSSL $i
                        done
                        stop_server
                    fi

                    ;;

                [Gg]nu*)

                    reset_ciphersuites
                    add_common_ciphersuites
                    add_gnutls_ciphersuites
                    filter_ciphersuites

                    if [ "X" != "X$P_CIPHERS" ]; then
                        start_server "GnuTLS"
                        for i in $P_CIPHERS; do
                            run_client PolarSSL $i
                        done
                        stop_server
                    fi

                    if [ "X" != "X$G_CIPHERS" ]; then
                        start_server "PolarSSL"
                        for i in $G_CIPHERS; do
                            run_client GnuTLS $i
                        done
                        stop_server
                    fi

                    ;;

                [Pp]olar*)

                    reset_ciphersuites
                    add_common_ciphersuites
                    add_openssl_ciphersuites
                    add_gnutls_ciphersuites
                    add_polarssl_ciphersuites
                    filter_ciphersuites

                    if [ "X" != "X$P_CIPHERS" ]; then
                        start_server "PolarSSL"
                        for i in $P_CIPHERS; do
                            run_client PolarSSL $i
                        done
                        stop_server
                    fi

                    ;;

                *)
                    echo "Unknown peer: $PEER" >&2
                    exit 1
                    ;;

                esac

            done
        done
    done
done

echo "------------------------------------------------------------------------"

if [ $FAILED -ne 0 -o $SRVMEM -ne 0 ];
then
    echo -n "FAILED"
else
    echo -n "PASSED"
fi

if [ "$MEMCHECK" -gt 0 ]; then
    MEMREPORT=", $SRVMEM server memory errors"
else
    MEMREPORT=""
fi

PASSED=$(( $TESTS - $FAILED ))
echo " ($PASSED / $TESTS tests ($SKIPPED skipped$MEMREPORT))"

FAILED=$(( $FAILED + $SRVMEM ))
exit $FAILED
