#!/bin/bash -e 
set -x

lockfile-create --use-pid --retry 1 /var/lock/dana || exit 0
function finish {
	lockfile-remove /var/lock/dana
}

trap finish EXIT

PRM=/usr/local/bin/prm
if [ $# != 4 ]; then
    echo "Usage:"
    echo "     $0 PASSPHRASE KEY_GPG REPO_DIR SECTION"
	exit 1
fi

# For example ~/.gnupg/passphrase
readonly PASSPHRASE="$1"
# Key number for gpg sign
readonly KEY="$2"
# REPO_DIR=/var/www/repos/apt
readonly REPO_DIR="$3"
readonly SEC="$4"
#readonly INCOM_DIR=$REPO_DIR/incoming
readonly INCOM_DIR=/home/dana/erl_xenial
#readonly INCOM_DIR=/home/dana/erl_trusty
readonly REJ_DIR=$INCOM_DIR/rejects
readonly DELETED=$REPO_DIR/deleted
readonly REPO_DISTS=$REPO_DIR/dists

set +x
for i in "$REPO_DIR" "$INCOM_DIR" "$REJ_DIR" "$DELETED" "$REPO_DISTS"; do
    mkdir -p "$i"
done
set -x

checksums() {
    local CHANGES_FILE=$1
    local DEB_FILE=$2
    local MD5
    local SHA1
    local SHA256
    MD5=$(grep -A1 "Files" "$CHANGES_FILE" | grep -o "[0-9a-f]\{32\}")
    SHA1=$(grep -A1 "Checksums-Sha1" "$CHANGES_FILE" | grep -o "[0-9a-f]\{40\}")
    SHA256=$(grep -A1 "Checksums-Sha256" "$CHANGES_FILE" | grep -o "[0-9a-f]\{64\}")
    echo "$MD5 $DEB_FILE" | md5sum -c - 2>&1 > /dev/null
    if [ $? != 0 ]; then
	echo $?
	return
    fi
    echo "$SHA1 $DEB_FILE" | sha1sum -c - 2>&1 > /dev/null
    if [ $? != 0 ]; then
	echo $?
	return
    fi
    echo "$SHA256 $DEB_FILE" | sha256sum -c - 2>&1 > /dev/null
    if [ $? != 0 ]; then
	echo $?
	return
    fi
    echo 0
}

jab_notify() {
	set +x
	local ACTION=$1
	local DISTR=$2
	local DEB=$3
	java -jar /home/dana/jenkins-cli.jar -s http://biser.eltex.loc build dana -p DISTR="$DISTR" -p DEB="$DEB" -p ACTION="$ACTION"
	set -x
}

get_from_control(){
    dpkg-deb -f "$DEB" | grep "$1"
}

get_field(){
    dpkg-deb -f "$DEB" | grep "$1" | grep -o ":.*" | cut -b '3-'
}

create_changefile() {
    local DEB=$1
    local CHANGE_FILE=$2
    local REP=$3

    N=$(get_field "Package: ")
    Maint=$(get_field "Maintainer: ")
    SIZE=$(wc -c "$DEB" | grep -o "^a*[0-9]*")
    BASE=$(basename "$DEB")
    SECTION=$(get_field "Section: ")
    PRIORITY=$(get_field "Priority: ")
    {
        echo "Format: 1.8"
        echo "Date: $(date --rfc-2822)"
        echo "Source: $N"
        echo "Binary: $N"
        get_from_control Architecture
        get_from_control Version
        echo "Distribution: $REP"
        echo "Urgency: low"
        echo "Maintainer: $Maint"
        echo "Changed-By: $Maint"
        echo "Description:"
        echo " $(dpkg-deb -f "$DEB" | tail -1)"
        echo "Changes:"
        echo " $N ($(get_field "Version: ")) $REP; urgency=low"
        echo " ."
        echo "   * Empty changelog"
        echo "Checksums-Sha1:"
        echo " $(sha1sum "$DEB" | grep -o '^a*[0-9a-f]*') $SIZE $BASE"
        echo "Checksums-Sha256:"
        echo " $(sha256sum "$DEB" | grep -o '^a*[0-9a-f]*') $SIZE $BASE"
        echo "Files:"
        echo " $(md5sum "$DEB" | grep -o '^a*[0-9a-f]*') $SIZE $SECTION $PRIORITY $BASE"
    } > "$CHANGE_FILE"
}

get_incoming() {
    local MASK=$1
    find "$INCOM_DIR" -name "$MASK" -not -ipath "*/rejects/*"
}

get_deb_pathes() {
    local REP=$1
    local DEB=$2
    find "$REPO_DISTS/$REP" -name "$DEB"
}

SECTIONS=()
for i in $(get_incoming "*.delete"); do
    [ ! -f "$i" ] && continue;
    FN=$(basename "$i")
    DEB=${FN%.*}.deb
    REP=$(cat "$i")
    if [ "$(get_deb_pathes "$REP" "$DEB" | wc -l)" == 0 ]; then
        echo "Don't find package" > "$i"
        mv "$i" "$REJ_DIR"
    else
        for j in $(get_deb_pathes "$REP" "$DEB"); do
            if [ "$(echo "$j" | grep -c "md5-results")" == 1 ]; then
                rm -f "$j"
            else
                SECTIONS+=($REP)

		jab_notify delete $REP ${FN%.*}.deb
                mv "$j" "$DELETED"
                rm "$i"
            fi
        done	
    fi
done

for i in $(get_incoming "*.move"); do
    [ ! -f "$i" ] && continue;
    FN=$(basename "$i")
    DEB=${FN%.*}.deb
    CHANGES_FILE=$INCOM_DIR/${DEB%.*}.changes
    REP_TO=$(cat "$i")

    if [ "$(get_deb_pathes "" "$DEB" | grep -v "$REP_TO" | wc -l)" == 0 ]; then
        echo "Don't find package" > "$i"
        mv "$i" "$REJ_DIR"
    elif [ "$(get_deb_pathes "$REP_TO" "$DEB" | wc -l)" == 1 ]; then
        echo "Already exist in $REP_TO" > "$i"
        mv "$i" "$REJ_DIR"
    else
        for j in $(get_deb_pathes "$REP" "$DEB"); do
            if [ "$(echo "$j" | grep -c "md5-results")" == 0 ]; then
                cp "$j" "$INCOM_DIR"
                create_changefile "$j" "$CHANGES_FILE" "$REP_TO"
                rm "$i"
            fi
        done	
    fi
done

SECTIONS=$(printf '%s\n' "${SECTIONS[@]}" | sort -u)

for REP in unstable testing stable experimental; do
    CHANGED=1
    TMP=$(mktemp -d)

	for i in $(get_incoming "*.deb"); do
		[ ! -f "$i" ] && continue;
		DEB=$(basename "$i")
		CHANGES_FILE=$INCOM_DIR/${DEB%.*}.changes
		[ "$(grep -c "Distribution: $REP" "$CHANGES_FILE")" == 0 ] && continue
		if [ -f "$CHANGES_FILE" ]; then 
                ## Find distribution (testing/stable/unstable)
			if [ "$(grep -c "Distribution: $REP" "$CHANGES_FILE")" == 1 ]; then
			    if [ "$(checksums "$CHANGES_FILE" "$i")" == 0 ]; then
			## Add in repo 
				    mv "$i" "$TMP"
				    rm "$CHANGES_FILE"
				    jab_notify add $REP $DEB
				    CHANGED=1
				    else
				    echo "Corrupt file $i"
				    mv "$i" "$REJ_DIR"
				    mv "$CHANGES_FILE" "$REJ_DIR"
				    jab_notify corrupt $REP $DEB
			    fi
			fi
		fi
    done

    if [[ "$CHANGED" == 1 || "$(echo "$SECTIONS" | grep -c "$REP")" == 1 ]]; then
		REL_FILE=$REPO_DIR/dists/$REP/Release
		rm -f "$REL_FILE.gpg"
		time $PRM --gpg_sign_algorithm='SHA512' --type deb -p "$REPO_DIR" -r "$REP" -a amd64,i386 -c "$SEC" -d "$TMP"

		gpg -u "$KEY" --passphrase-fd 0 --no-tty --yes --detach-sign \
            --output "$REL_FILE.gpg"  "$REL_FILE" < "$PASSPHRASE"
		CHANGED=1
	fi	
   rm -fr "$TMP"
done
