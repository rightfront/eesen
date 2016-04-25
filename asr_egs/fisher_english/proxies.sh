function proxy_on() {
    export no_proxy="localhost,127.0.0.1,localaddress,.localdomain.com,.capitalone.com"

    if [ ${#USER} -ne 6 ]; then
        echo "WARNING: your USER environment variable doesn't contain an eID. Add 'export USER=EID123' in your .bash_profile";
    fi

    echo -n "password: "
    read -es password
    local pre="$USER:$password"

    export http_proxy="http://$pre@proxy.kdc.capitalone.com:8099"
    export http_proxy_password=$password
    export http_proxy_username=$USER
    export https_proxy=$http_proxy
    export ftp_proxy=$http_proxy
    export rsync_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy
    export FTP_PROXY=$http_proxy
    export RSYNC_PROXY=$http_proxy
    echo -e "C1 proxy enabled"
}

function proxy_off() {
    unset http_proxy
    unset https_proxy
    unset ftp_proxy
    unset rsync_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset FTP_PROXY
    unset RSYNC_PROXY
    echo -e "C1 proxy disabled"
}
