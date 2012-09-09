#!/bin/sh

# zfs namespace
NS="poudriere"
IPS="$(sysctl -n kern.features.inet 2>/dev/null || (sysctl -n net.inet 1>/dev/null 2>&1 && echo 1) || echo 0)$(sysctl -n kern.features.inet6 2>/dev/null || (sysctl -n net.inet6 1>/dev/null 2>&1 && echo 1) || echo 0)"

err() {
	if [ $# -ne 2 ]; then
		err 1 "err expects 2 arguments: exit_number \"message\""
	fi
	local err_msg="Error: $2"
	msg "${err_msg}" >&2
	[ -n "${MY_JOBID}" ] && job_msg "${err_msg}"
	exit $1
}

msg_n() { echo -n "====>> $1"; }
msg() { echo "====>> $1"; }
job_msg() {
	msg "[${MY_JOBID}] $1" >&5
}

debug() {
	[ -z "${DEBUG_MODE}" ] && return 0;

	msg "DEBUG: $1" >&2
}

eargs() {
	case $# in
	0) err 1 "No arguments expected" ;;
	1) err 1 "1 argument expected: $1" ;;
	*) err 1 "$# arguments expected: $*" ;;
	esac
}

log_start() {
	local logfile=$1

	# Make sure directory exists
	mkdir -p ${logfile%/*}

	exec 3>&1 4>&2
	[ ! -e ${logfile}.pipe ] && mkfifo ${logfile}.pipe
	tee ${logfile} < ${logfile}.pipe >&3 &
	export tpid=$!
	exec > ${logfile}.pipe 2>&1

	# Remove fifo pipe file right away to avoid orphaning it.
	# The pipe will continue to work as long as we keep
	# the FD open to it.
	rm -f ${logfile}.pipe
}

log_path() {
	echo "${LOGS}/${POUDRIERE_BUILD_TYPE}/${JAILNAME%-job-*}/${PTNAME}"
}

buildlog_start() {
	local portdir=$1

	echo "build started at $(date)"
	echo "port directory: ${portdir}"
	echo "building for: $(injail uname -rm)"
	echo "maintained by: $(injail make -C ${portdir} maintainer)"
	echo "Makefile ident: $(injail ident ${portdir}/Makefile|sed -n '2,2p')"

	echo "---Begin Environment---"
	injail env ${PKGENV} ${PORT_FLAGS}
	echo "---End Environment---"
	echo ""
	echo "---Begin OPTIONS List---"
	injail make -C ${portdir} showconfig
	echo "---End OPTIONS List---"
}

buildlog_stop() {
	local portdir=$1

	echo "build of ${portdir} ended at $(date)"
}

log_stop() {
	if [ -n "${tpid}" ]; then
		exec 1>&3 3>&- 2>&4 4>&-
		wait $tpid
		unset tpid
	fi
}

zget() {
	[ $# -ne 1 ] && eargs property
	zfs get -H -o value ${NS}:${1} ${JAILFS}
}

zset() {
	[ $# -ne 2 ] && eargs property value
	zfs set ${NS}:$1="$2" ${JAILFS}
}

pzset() {
	[ $# -ne 2 ] && eargs property value
	zfs set ${NS}:$1="$2" ${PTFS}
}

pzget() {
	[ $# -ne 1 ] && eargs property
	zfs get -H -o value ${NS}:${1} ${PTFS}
}

sig_handler() {
	trap - SIGTERM SIGKILL
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	err 1 "Signal caught, cleaning up and exiting"
}

exit_handler() {
	# Avoid recursively cleaning up here
	trap - EXIT SIGTERM SIGKILL
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	[ ${STATUS} -eq 1 ] && cleanup
	[ -n ${CLEANUP_HOOK} ] && ${CLEANUP_HOOK}
}

siginfo_handler() {
	if [ ! ${POUDRIERE_BUILD_TYPE} = "bulk" ]; then
		return 0;
	fi
	local status=$(zget status)
	local nbb=$(zget stats_built|sed -e 's/ //g')
	local nbf=$(zget stats_failed|sed -e 's/ //g')
	local nbi=$(zget stats_ignored|sed -e 's/ //g')
	local nbs=$(zget stats_skipped|sed -e 's/ //g')
	local nbq=$(zget stats_queued|sed -e 's/ //g')
	local ndone=$((nbb + nbf + nbi + nbs))
	local queue_width=2
	local j status

	if [ ${nbq} -gt 9999 ]; then
		queue_width=5
	elif [ ${nbq} -gt 999 ]; then
		queue_width=4
	elif [ ${nbq} -gt 99 ]; then
		queue_width=3
	fi

	printf "[${status}] [%0${queue_width}d/%0${queue_width}d] Built: %-${queue_width}d Failed: %-${queue_width}d  Ignored: %-${queue_width}d  Skipped: %-${queue_width}d  \n" \
	  ${ndone} ${nbq} ${nbb} ${nbf} ${nbi} ${nbs}

	if [ -n "${JOBS}" ]; then
		for j in ${JOBS}; do
			status=$(JAILFS=${JAILFS}/build/${j} zget status)
			# Hide idle workers
			if ! [ "${status}" = "idle:" ]; then
				echo -e "\t[${j}]: ${status}"
			fi
		done
	fi
}

jail_exists() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -H -o ${NS}:type,${NS}:name ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 'BEGIN { ret = 1 } $1 == "rootfs" && $2 == n { ret = 0; } END { exit ret }' && return 0
	return 1
}

jail_runs() {
	[ $# -ne 0 ] && eargs
	jls -qj ${JAILNAME} name > /dev/null 2>&1 && return 0
	return 1
}

jail_get_base() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -s name -H -o ${NS}:type,${NS}:name,mountpoint ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "rootfs" && $2 == n  { print $3 }' | head -n 1
}

jail_get_version() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -s name -H -o ${NS}:type,${NS}:name,${NS}:version ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "rootfs" && $2 == n { print $3 }' | head -n 1
}

jail_get_fs() {
	[ $# -ne 1 ] && eargs jailname
	zfs list -rt filesystem -s name -H -o ${NS}:type,${NS}:name,name ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "rootfs" && $2 == n { print $3 }' | head -n 1
}

port_exists() {
	[ $# -ne 1 ] && eargs portstree_name
	zfs list -rt filesystem -H -o ${NS}:type,${NS}:name,name ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 'BEGIN { ret = 1 } $1 == "ports" && $2 == n { ret = 0; } END { exit ret }' && return 0
	return 1
}

port_get_base() {
	[ $# -ne 1 ] && eargs portstree_name
	zfs list -rt filesystem -H -o ${NS}:type,${NS}:name,mountpoint ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "ports" && $2 == n { print $3 }'
}

port_get_fs() {
	[ $# -ne 1 ] && eargs portstree_name
	zfs list -rt filesystem -H -o ${NS}:type,${NS}:name,name ${ZPOOL}${ZROOTFS} | \
		awk -v n=$1 '$1 == "ports" && $2 == n { print $3 }'
}

get_data_dir() {
	local data
	if [ -n "${POUDRIERE_DATA}" ]; then
		echo ${POUDRIERE_DATA}
		return
	fi
	data=$(zfs list -rt filesystem -H -o ${NS}:type,mountpoint ${ZPOOL}${ZROOTFS} | awk '$1 == "data" { print $2 }' | head -n 1)
	if [ -n "${data}" ]; then
		echo $data
		return
	fi
	zfs create -p -o ${NS}:type=data \
		-o mountpoint=${BASEFS}/data \
		${ZPOOL}${ZROOTFS}/data
	echo "${BASEFS}/data"
}

fetch_file() {
	[ $# -ne 2 ] && eargs destination source
	fetch -p -o $1 $2 || fetch -p -o $1 $2
}

jail_create_zfs() {
	[ $# -ne 5 ] && eargs name version arch mountpoint fs
	local name=$1
	local version=$2
	local arch=$3
	local mnt=$( echo $4 | sed -e "s,//,/,g")
	local fs=$5
	msg_n "Creating ${name} fs..."
	zfs create -p \
		-o ${NS}:type=rootfs \
		-o ${NS}:name=${name} \
		-o ${NS}:version=${version} \
		-o ${NS}:arch=${arch} \
		-o mountpoint=${mnt} ${fs} || err 1 " Fail" && echo " done"
}

jrun() {
	[ $# -ne 1 ] && eargs network
	local network=$1
	local ipargs
	if [ ${network} -eq 0 ]; then
		case $IPS in
		01) ipargs="ip6.addr=::1" ;;
		10) ipargs="ip4.addr=127.0.0.1" ;;
		11) ipargs="ip4.addr=127.0.0.1 ip6.addr=::1" ;;
		esac
	else
		case $IPS in
		01) ipargs="ip6=inherit" ;;
		10) ipargs="ip4=inherit" ;;
		11) ipargs="ip4=inherit ip6=inherit" ;;
		esac
	fi
	jail -c persist name=${JAILNAME} ${ipargs} path=${JAILMNT} \
		host.hostname=${JAILNAME} allow.sysvipc allow.mount \
		allow.socket_af allow.raw_sockets allow.chflags
}

do_jail_mounts() {
	[ $# -ne 1 ] && eargs should_mkdir
	local should_mkdir=$1
	local arch=$(zget arch)

	# Only do this when starting the master jail, clones will already have the dirs
	if [ ${should_mkdir} -eq 1 ]; then
		mkdir -p ${JAILMNT}/proc
	fi

	mount -t devfs devfs ${JAILMNT}/dev
	mount -t procfs proc ${JAILMNT}/proc

	if [ -z "${NOLINUX}" ]; then
		if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
			if [ ${should_mkdir} -eq 1 ]; then
				mkdir -p ${JAILMNT}/compat/linux/proc
				mkdir -p ${JAILMNT}/compat/linux/sys
			fi
			mount -t linprocfs linprocfs ${JAILMNT}/compat/linux/proc
			mount -t linsysfs linsysfs ${JAILMNT}/compat/linux/sys
		fi
	fi
}

do_portbuild_mounts() {
	[ $# -ne 1 ] && eargs should_mkdir
	local should_mkdir=$1

	# Only do this when starting the master jail, clones will already have the dirs
	if [ ${should_mkdir} -eq 1 ]; then
		mkdir -p ${PORTSDIR}/packages
		mkdir -p ${PKGDIR}/All
		mkdir -p ${PORTSDIR}/distfiles
		if [ -n "${CCACHE_DIR}" -a -d "${CCACHE_DIR}" ]; then
			mkdir -p ${JAILMNT}${CCACHE_DIR} || err 1 "Failed to create ccache directory "
			msg "Mounting ccache from ${CCACHE_DIR}"
			export CCACHE_DIR
			export WITH_CCACHE_BUILD=yes
		fi
	fi

	mount -t nullfs ${PORTSDIR} ${JAILMNT}/usr/ports || err 1 "Failed to mount the ports directory "
	mount -t nullfs ${PKGDIR} ${JAILMNT}/usr/ports/packages || err 1 "Failed to mount the packages directory "

	if [ -n "${DISTFILES_CACHE}" -a -d "${DISTFILES_CACHE}" ]; then
		mount -t nullfs ${DISTFILES_CACHE} ${JAILMNT}/usr/ports/distfiles || err 1 "Failed to mount the distfile directory"
	fi
	[ -n "${MFSSIZE}" ] && mdmfs -M -S -o async -s ${MFSSIZE} md ${JAILMNT}/wrkdirs
	[ -n "${USE_TMPFS}" ] && mount -t tmpfs tmpfs ${JAILMNT}/wrkdirs

	if [ -d ${POUDRIERED}/${JAILNAME%-job-*}-options ]; then
		mount -t nullfs ${POUDRIERED}/${JAILNAME%-job-*}-options ${JAILMNT}/var/db/ports || err 1 "Failed to mount OPTIONS directory"
	elif [ -d ${POUDRIERED}/options ]; then
		mount -t nullfs ${POUDRIERED}/options ${JAILMNT}/var/db/ports || err 1 "Failed to mount OPTIONS directory"
	fi

	if [ -n "${CCACHE_DIR}" -a -d "${CCACHE_DIR}" ]; then
		# Mount user supplied CCACHE_DIR into /var/cache/ccache
		mount -t nullfs ${CCACHE_DIR} ${JAILMNT}${CCACHE_DIR} || err 1 "Failed to mount the ccache directory "
	fi
}

jail_start() {
	[ $# -ne 0 ] && eargs
	local arch=$(zget arch)
	local NEEDFS="nullfs procfs"
	if [ -z "${NOLINUX}" ]; then
		if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
			NEEDFS="${NEEDFS} linprocfs linsysfs"
			sysctl -n compat.linux.osrelease >/dev/null 2>&1 || kldload linux
		fi
	fi
	[ -n "${USE_TMPFS}" ] && NEEDFS="${NEEDFS} tmpfs"
	for fs in ${NEEDFS}; do
		lsvfs $fs >/dev/null 2>&1 || kldload $fs
	done
	jail_exists ${JAILNAME} || err 1 "No such jail: ${JAILNAME}"
	jail_runs && err 1 "jail already running: ${JAILNAME}"
	zset status "start:"
	zfs destroy -r ${JAILFS}/build 2>/dev/null || :
	zfs rollback -R ${JAILFS}@clean

	msg "Mounting system devices for ${JAILNAME}"
	do_jail_mounts 1

	test -n "${RESOLV_CONF}" && cp -v "${RESOLV_CONF}" "${JAILMNT}/etc/"
	msg "Starting jail ${JAILNAME}"
	jrun 0
	# Only set STATUS=1 if not turned off
	# jail -s should not do this or jail will stop on EXIT
	[ ${SET_STATUS_ON_START-1} -eq 1 ] && export STATUS=1
}

jail_stop() {
	[ $# -ne 0 ] && eargs
	jail_runs || err 1 "No such jail running: ${JAILNAME%-job-*}"
	zset status "stop:"

	jail -r ${JAILNAME%-job-*}
	# Shutdown all builders
	if [ ${PARALLEL_JOBS} -ne 0 ]; then
		# - here to only check for unset, {start,stop}_builders will set this to blank if already stopped
		for j in ${JOBS-$(jot -w %02d ${PARALLEL_JOBS})}; do
			jail -r ${JAILNAME%-job-*}-job-${j} >/dev/null 2>&1 || :
		done
	fi
	msg "Umounting file systems"
	mount | awk -v mnt="${MASTERMNT:-${JAILMNT}}/" 'BEGIN{ gsub(/\//, "\\\/", mnt); } { if ($3 ~ mnt && $1 !~ /\/dev\/md/ ) { print $3 }}' |  sort -r | xargs umount -f || :

	if [ -n "${MFSSIZE}" ]; then
		# umount the ${JAILMNT}/build/$jobno/wrkdirs
		mount | grep "/dev/md.*${MASTERMNT:-${JAILMNT}}/build" | while read mnt; do
			local dev=`echo $mnt | awk '{print $1}'`
			if [ -n "$dev" ]; then
				umount $dev
				mdconfig -d -u $dev
			fi
		done
		# umount the $JAILMNT/wrkdirs
		local dev=`mount | grep "/dev/md.*${MASTERMNT:-${JAILMNT}}" | awk '{print $1}'`
		if [ -n "$dev" ]; then
			umount $dev
			mdconfig -d -u $dev
		fi
	fi
	zfs rollback -R ${JAILFS%/build/*}@clean
	zset status "idle:"
	export STATUS=0
}

port_create_zfs() {
	[ $# -ne 3 ] && eargs name mountpoint fs
	local name=$1
	local mnt=$( echo $2 | sed -e 's,//,/,g')
	local fs=$3
	msg_n "Creating ${name} fs..."
	zfs create -p \
		-o mountpoint=${mnt} \
		-o ${NS}:type=ports \
		-o ${NS}:name=${name} \
		${fs} || err 1 " Fail" && echo " done"
}

cleanup() {
	[ -n "${CLEANED_UP}" ] && return 0
	msg "Cleaning up"
	# If this is a builder, don't cleanup, the master will handle that.
	if [ -n "${MY_JOBID}" ]; then
		[ -n "${PKGNAME}" ] && clean_pool ${PKGNAME} 1 || :
		return 0

	fi
	# Prevent recursive cleanup on error
	if [ -n "${CLEANING_UP}" ]; then
		echo "Failure cleaning up. Giving up." >&2
		return
	fi
	export CLEANING_UP=1
	[ -z "${JAILNAME%-job-*}" ] && err 2 "Fail: Missing JAILNAME"
	log_stop

	if [ -d ${MASTERMNT:-${JAILMNT}}/poudriere/var/run ]; then
		for pid in ${MASTERMNT:-${JAILMNT}}/poudriere/var/run/*.pid; do
			# Ensure there is a pidfile to read or break
			[ "${pid}" = "${MASTERMNT:-${JAILMNT}}/poudriere/var/run/*.pid" ] && break
			pkill -15 -F ${pid} >/dev/null 2>&1 || :
		done
		wait
	fi

	# Kill anything orphaned by the workers by killing the PGID
	# This includes MY PID, so ignore SIGTERM briefly
	trap '' SIGTERM
	kill 0
	trap sig_handler SIGTERM
	wait

	zfs destroy -r ${JAILFS%/build/*}/build 2>/dev/null || :
	zfs destroy -r ${JAILFS%/build/*}@prepkg 2>/dev/null || :
	zfs destroy -r ${JAILFS%/build/*}@prebuild 2>/dev/null || :
	jail_stop
	export CLEANED_UP=1
}

injail() {
	jexec -U root ${JAILNAME} $@
}

sanity_check_pkgs() {
	local ret=0
	local depfile
	[ ! -d ${PKGDIR}/All ] && return $ret
	[ -z "$(ls -A ${PKGDIR}/All)" ] && return $ret
	for pkg in ${PKGDIR}/All/*.${PKG_EXT}; do
		# Check for non-empty directory with no packages in it
		[ "${pkg}" = "${PKGDIR}/All/*.${PKG_EXT}" ] && break
		depfile=$(deps_file ${pkg})
		while read dep; do
			if [ ! -e "${PKGDIR}/All/${dep}.${PKG_EXT}" ]; then
				ret=1
				msg "Deleting ${pkg}: missing dependencies"
				delete_pkg ${pkg}
				break
			fi
		done < "${depfile}"
	done

	return $ret
}

build_port() {
	[ $# -ne 1 ] && eargs portdir
	local portdir=$1
	local port=${portdir##/usr/ports/}
	local targets="fetch checksum extract patch configure build install package"

	[ -n "${PORTTESTING}" ] && targets="${targets} deinstall"
	for phase in ${targets}; do
		zset status "${phase}:${port}"
		if [ "${phase}" = "fetch" ]; then
			jail -r ${JAILNAME}
			jrun 1
		fi
		[ "${phase}" = "build" -a $ZVERSION -ge 28 ] && zfs snapshot ${JAILFS}@prebuild
		if [ -n "${PORTTESTING}" -a "${phase}" = "deinstall" ]; then
			msg "Checking shared library dependencies"
			if [ ${PKGNG} -eq 0 ]; then
				PLIST="/var/db/pkg/${PKGNAME}/+CONTENTS"
				grep -v "^@" ${JAILMNT}${PLIST} | \
					sed -e "s,^,${PREFIX}/," | \
					xargs injail ldd 2>&1 | \
					grep -v "not a dynamic executable" | \
					awk ' /=>/{ print $3 }' | sort -u
			else
				injail pkg query "%Fp" ${PKGNAME} | \
					xargs injail ldd 2>&1 | \
					grep -v "not a dynamic executable" | \
					awk '/=>/ { print $3 }' | sort -u
			fi
		fi

		printf "=======================<phase: %-9s>==========================\n" ${phase}
		injail env ${PKGENV} ${PORT_FLAGS} make -C ${portdir} ${phase} || return 1
		echo "==================================================================="

		if [ "${phase}" = "checksum" ]; then
			jail -r ${JAILNAME}
			jrun 0
		fi
		if [ -n "${PORTTESTING}" -a  "${phase}" = "deinstall" ]; then
			msg "Checking for extra files and directories"
			PREFIX=`injail make -C ${portdir} -VPREFIX`
			zset status "fscheck:${port}"
			if [ $ZVERSION -lt 28 ]; then
				find ${jailbase}${PREFIX} ! -type d | \
					sed -e "s,^${jailbase}${PREFIX}/,," | sort

				find ${jailbase}${PREFIX}/ -type d | sed "s,^${jailbase}${PREFIX}/,," | sort > ${jailbase}${PREFIX}.PLIST_DIRS.after
				comm -13 ${jailbase}${PREFIX}.PLIST_DIRS.before ${jailbase}${PREFIX}.PLIST_DIRS.after | sort -r | awk '{ print "@dirrmtry "$1}'
			else
				local portname=$(injail make -C ${portdir} -VPORTNAME)
				local add=$(mktemp ${jailbase}/tmp/add.XXXXXX)
				local add1=$(mktemp ${jailbase}/tmp/add1.XXXXXX)
				local del=$(mktemp ${jailbase}/tmp/del.XXXXXX)
				local del1=$(mktemp ${jailbase}/tmp/del1.XXXXXX)
				local mod=$(mktemp ${jailbase}/tmp/mod.XXXXXX)
				local mod1=$(mktemp ${jailbase}/tmp/mod1.XXXXXX)
				local die=0
				zfs diff -FH ${JAILFS}@prebuild ${JAILFS} | \
					while read mod type path; do
					local ppath
					ppath=`echo "$path" | sed -e "s,^${JAILMNT},," -e "s,^${PREFIX}/,," -e "s,^share/${portname},%%DATADIR%%," -e "s,^etc/${portname},%%ETCDIR%%,"`
					case "$ppath" in
					/var/db/pkg/*) continue;;
					/var/run/*) continue;;
					/wrkdirs/*) continue;;
					/tmp/*) continue;;
					share/nls/POSIX) continue;;
					share/nls/en_US.US-ASCII) continue;;
					/var/log/*) continue;;
					/var/mail/*) continue;;
					/etc/spwd.db) continue;;
					/etc/pwd.db) continue;;
					/etc/group) continue;;
					/etc/passwd) continue;;
					/etc/master.passwd) continue;;
					/etc/shells) continue;;
					esac
					case $mod$type in
					+*) echo "${ppath}" >> ${add};;
					-*) echo "${ppath}" >> ${del};;
					M/) continue;;
					M*) echo "${ppath}" >> ${mod};;
					esac
				done
				sort ${add} > ${add1}
				sort ${del} > ${del1}
				sort ${mod} > ${mod1}
				comm -12 ${add1} ${del1} >> ${mod1}
				comm -23 ${add1} ${del1} > ${add}
				comm -13 ${add1} ${del1} > ${del}
				if [ -s "${add}" ]; then
					msg "Files or directories left over:"
					cat ${add}
				fi
				if [ -s "${del}" ]; then
					msg "Files or directories removed:"
					cat ${del}
				fi
				if [ -s "${mod}" ]; then
					msg "Files or directories modified:"
					cat ${mod1}
				fi
				rm -f ${add} ${add1} ${del} ${del1} ${mod} ${mod1}
			fi
		fi
	done
	jail -r ${JAILNAME}
	jrun 0
	zset status "idle:"
	zfs destroy -r ${JAILFS}@prebuild || :
	return 0
}

save_wrkdir() {
	[ $# -ne 1 ] && eargs port

	local portdir="/usr/ports/${port}"
	local tardir=${POUDRIERE_DATA}/wrkdirs/${JAILNAME%-job-*}/${PTNAME}
	local tarname=${tardir}/${PKGNAME}.tbz
	local mnted_portdir=${JAILMNT}/wrkdirs/${portdir}

	mkdir -p ${tardir}

	# Tar up the WRKDIR, and ignore errors
	rm -f ${tarname}
	tar -s ",${mnted_portdir},," -cjf ${tarname} ${mnted_portdir}/work > /dev/null 2>&1
	job_msg "Saved ${port} wrkdir to: ${tarname}"
}

start_builders() {
	local arch=$(zget arch)
	local version=$(zget version)
	local j mnt fs name

	zfs create -o canmount=off ${JAILFS}/build

	for j in ${JOBS}; do
		mnt="${JAILMNT}/build/${j}"
		fs="${JAILFS}/build/${j}"
		name="${JAILNAME}-job-${j}"
		zset status "starting_jobs:${j}"
		mkdir -p "${mnt}"
		zfs clone -o mountpoint=${mnt} \
			-o ${NS}:name=${name} \
			-o ${NS}:type=rootfs \
			-o ${NS}:arch=${arch} \
			-o ${NS}:version=${version} \
			${JAILFS}@prepkg ${fs}
		zfs snapshot ${fs}@prepkg
		# Jail might be lingering from previous build. Already recursively
		# destroyed all the builder datasets, so just try stopping the jail
		# and ignore any errors
		jail -r ${name} >/dev/null 2>&1 || :
		MASTERMNT=${JAILMNT} JAILNAME=${name} JAILMNT=${mnt} JAILFS=${fs} do_jail_mounts 0
		MASTERMNT=${JAILMNT} JAILNAME=${name} JAILMNT=${mnt} JAILFS=${fs} do_portbuild_mounts 0
		MASTERMNT=${JAILMNT} JAILNAME=${name} JAILMNT=${mnt} JAILFS=${fs} jrun 0
		JAILFS=${fs} zset status "idle:"
	done
}

stop_builders() {
	local j mnt

	# wait for the last running processes
	cat ${JAILMNT}/poudriere/var/run/*.pid 2>/dev/null | xargs pwait 2>/dev/null

	msg "Stopping ${PARALLEL_JOBS} builders"

	for j in ${JOBS}; do
		jail -r ${JAILNAME}-job-${j} >/dev/null 2>&1 || :
	done

	mount | awk -v mnt="${JAILMNT}/build/" 'BEGIN{ gsub(/\//, "\\\/", mnt); } { if ($3 ~ mnt && $1 !~ /\/dev\/md/ ) { print $3 }}' |  sort -r | xargs umount -f 2>/dev/null || :

	zfs destroy -r ${JAILFS}/build 2>/dev/null || :

	# No builders running, unset JOBS
	JOBS=""
}

build_stats_list() {
	[ $# -ne 3 ] && eargs html_path type display_name
	local html_path="$1"
	local type=$2
	local display_name="$3"
	local port cnt pkgname extra
	local status_head="" status_col=""
	local reason_head="" reason_col=""

	if [ ! "${type}" = "skipped" ]; then
		status_head="<th>status</th>"
	fi

	# ignored has a reason
	if [ "${type}" = "ignored" -o "${type}" = "skipped" ]; then
		reason_head="<th>reason</th>"
	elif [ "${type}" = "failed" ]; then
		reason_head="<th>phase</th>"
	fi

cat >> ${html_path} << EOF
    <div id="${type}">
      <h2>${display_name} ports </h2>
      <table>
        <tr>
          <th>Port</th>
          <th>Origin</th>
	  ${status_head}
	  ${reason_head}
        </tr>
EOF
	cnt=0
	while read port extra; do
		pkgname=$(cache_get_pkgname ${port})

		if [ -n "${status_head}" ]; then
			status_col="<td><a href=\"${pkgname}.log\">logfile</a></td>"
		fi

		if [ "${type}" = "ignored" ]; then
			reason_col="<td>${extra}</td>"
		elif [ "${type}" = "skipped" ]; then
			reason_col="<td>depends failed: <a href="#tr_pkg_${extra}">${extra}</a></td>"
		elif [ "${type}" = "failed" ]; then
			reason_col="<td>${extra}</td>"
		fi

		cat >> ${html_path} << EOF
        <tr>
          <td id="tr_pkg_${pkgname}">${pkgname}</td>
          <td>${port}</td>
	  ${status_col}
	  ${reason_col}
        </tr>
EOF
		cnt=$(( cnt + 1 ))
	done <  ${JAILMNT}/poudriere/ports.${type}
	zset stats_${type} $cnt

cat >> ${html_path} << EOF
      </table>
    </div>
EOF
}

build_stats() {
	local port logdir pkgname html_path
	logdir=`log_path`

	if [ "${POUDRIERE_BUILD_TYPE}" = "testport" ]; then
		# Discard test stats page for now
		html_path="/dev/null"
	else
		html_path="${logdir}/index.html"
	fi
	

cat > ${html_path} << EOF
<html>
  <head>
    <title>Poudriere bulk results</title>
    <style type="text/css">
      table {
        display: block;
        border: 2px;
        border-collapse:collapse;
        border: 2px solid black;
        margin-top: 5px;
      }
      th, td { border: 1px solid black; }
      #built td { background-color: #00CC00; }
      #failed td { background-color: #E00000 ; }
      #skipped td { background-color: #CC6633; }
      #ignored td { background-color: #FF9900; }
    </style>
    <script type="text/javascript">
      function toggle_display(id) {
        var e = document.getElementById(id);
        if (e.style.display != 'none')
          e.style.display = 'none';
        else
          e.style.display = 'block';
      }
    </script>
  </head>
  <body>
    <h1>Poudriere bulk results</h1>
    <ul>
      <li>Jail: ${JAILNAME}</li>
      <li>Ports tree: ${PTNAME}</li>
EOF
				cnt=$(zget stats_queued)
cat >> ${html_path} << EOF
      <li>Nb ports queued: ${cnt}</li>
    </ul>
    <hr />
    <button onclick="toggle_display('built');">Show/Hide success</button>
    <button onclick="toggle_display('failed');">Show/Hide failure</button>
    <button onclick="toggle_display('ignored');">Show/Hide ignored</button>
    <button onclick="toggle_display('skipped');">Show/Hide skipped</button>
    <hr />
EOF

    build_stats_list "${html_path}" "built" "Successful"
    build_stats_list "${html_path}" "failed" "Failed"
    build_stats_list "${html_path}" "ignored" "Ignored"
    build_stats_list "${html_path}" "skipped" "Skipped"

cat >> ${html_path} << EOF
  </body>
</html>
EOF
}

build_queue() {

	local activity j cnt mnt fs name pkgname

	while :; do
		activity=0
		for j in ${JOBS}; do
			mnt="${JAILMNT}/build/${j}"
			fs="${JAILFS}/build/${j}"
			name="${JAILNAME}-job-${j}"
			if [ -f  "${JAILMNT}/poudriere/var/run/${j}.pid" ]; then
				if pgrep -qF "${JAILMNT}/poudriere/var/run/${j}.pid" >/dev/null 2>&1; then
					continue
				fi
				build_stats
				rm -f "${JAILMNT}/poudriere/var/run/${j}.pid"
			fi
			pkgname=$(next_in_queue)
			if [ -z "${pkgname}" ]; then
				# pool empty ?
				[ $(stat -f '%z' ${JAILMNT}/poudriere/pool) -eq 2 ] && return
				break
			fi
			activity=1
			MASTERMNT=${JAILMNT} JAILNAME="${name}" JAILMNT="${mnt}" JAILFS="${fs}" \
				MY_JOBID="${j}" \
				build_pkg "${pkgname}" >/dev/null 2>&1 &
			echo "$!" > ${JAILMNT}/poudriere/var/run/${j}.pid
		done
		# Sleep briefly if still waiting on builds, to save CPU
		[ $activity -eq 0 ] && sleep 0.1
	done
}

# Build ports in parallel
# Returns when all are built.
parallel_build() {
	[ -z "${JAILMNT}" ] && err 2 "Fail: Missing JAILMNT"
	local nbq=$(zget stats_queued)

	# If pool is empty, just return
	test ${nbq} -eq 0 && return 0

	msg "Starting using ${PARALLEL_JOBS} builders"
	JOBS="$(jot -w %02d ${PARALLEL_JOBS})"

	zset status "starting_jobs:"
	start_builders

	# Duplicate stdout to socket 5 so the child process can send
	# status information back on it since we redirect its
	# stdout to /dev/null
	exec 5<&1

	zset status "parallel_build:"
	build_queue

	zset status "stopping_jobs:"
	stop_builders
	zset status "idle:"

	# Close the builder socket
	exec 5>&-
}

clean_pool() {
	[ $# -ne 2 ] && eargs pkgname clean_rdepends
	local pkgname=$1
	local clean_rdepends=$2
	local port skipped_origin

	[ ${clean_rdepends} -eq 1 ] && port=$(cache_get_origin "${pkgname}")

	# Cleaning queue (pool is cleaned here)
	lockf -k ${MASTERMNT:-${JAILMNT}}/.lock sh ${SCRIPTPREFIX}/clean.sh "${MASTERMNT:-${JAILMNT}}" "${pkgname}" ${clean_rdepends} | while read skipped_pkgname; do
		skipped_origin=$(cache_get_origin "${skipped_pkgname}")
		echo "${skipped_origin} ${pkgname}" >> ${MASTERMNT:-${JAILMNT}}/poudriere/ports.skipped
		job_msg "Skipping build of ${skipped_origin}: Dependent port ${port} failed"
	done
}

build_pkg() {
	# If this first check fails, the pool will not be cleaned up,
	# since PKGNAME is not yet set.
	[ $# -ne 1 ] && eargs pkgname
	local pkgname="$1"
	local port portdir
	local build_failed=0
	local name cnt
	local failed_status failed_phase
	local clean_rdepends=0
	local ignore

	PKGNAME="${pkgname}" # set ASAP so cleanup() can use it
	port=$(cache_get_origin ${pkgname})
	portdir="/usr/ports/${port}"

	job_msg "Starting build of ${port}"
	zset status "starting:${port}"
	zfs rollback -r ${JAILFS}@prepkg || err 1 "Unable to rollback ${JAILFS}"

	# If this port is IGNORED, skip it
	# This is checked here instead of when building the queue
	# as the list may start big but become very small, so here
	# is a less-common check
	ignore="$(injail make -C ${portdir} -VIGNORE)"

	msg "Cleaning up wrkdir"
	rm -rf ${JAILMNT}/wrkdirs/*

	msg "Building ${port}"
	log_start $(log_path)/${PKGNAME}.log
	buildlog_start ${portdir}

	if [ -n "${ignore}" ]; then
		msg "Ignoring ${port}: ${ignore}"
		echo "${port} ${ignore}" >> "${MASTERMNT:-${JAILMNT}}/poudriere/ports.ignored"
		job_msg "Finished build of ${port}: Ignored: ${ignore}"
		clean_rdepends=1
	else
		zset status "depends:${port}"
		printf "=======================<phase: %-9s>==========================\n" "depends"
		if ! injail make -C ${portdir} pkg-depends fetch-depends extract-depends \
			patch-depends build-depends lib-depends; then
			build_failed=1
			failed_phase="depends"
		else
			echo "==================================================================="
			# Only build if the depends built fine
			injail make -C ${portdir} clean
			if ! build_port ${portdir}; then
				build_failed=1
				failed_status=$(zget status)
				failed_phase=${failed_status%:*}

				if [ "${SAVE_WRKDIR}" -eq 1 ]; then
					# Only save if not in fetch/checksum phase
					if ! [ "${failed_phase}" = "fetch" -o "${failed_phase}" = "checksum" ]; then
						save_wrkdir ${portdir} || :
					fi
				fi
			fi

			injail make -C ${portdir} clean
		fi

		if [ ${build_failed} -eq 0 ]; then
			echo "${port}" >> "${MASTERMNT:-${JAILMNT}}/poudriere/ports.built"

			job_msg "Finished build of ${port}: Success"
			# Cache information for next run
			pkg_cache_data "${PKGDIR}/All/${PKGNAME}.${PKG_EXT}" ${port} || :
		else
			echo "${port} ${failed_phase}" >> "${MASTERMNT:-${JAILMNT}}/poudriere/ports.failed"
			job_msg "Finished build of ${port}: Failed: ${failed_phase}"
			clean_rdepends=1
		fi
	fi

	clean_pool ${PKGNAME} ${clean_rdepends}

	zset status "done:${port}"
	buildlog_stop ${portdir}
	log_stop $(log_path)/${PKGNAME}.log
}

list_deps() {
	[ $# -ne 1 ] && eargs directory
	local dir=$1
	local makeargs="-VPKG_DEPENDS -VBUILD_DEPENDS -VEXTRACT_DEPENDS -VLIB_DEPENDS -VPATCH_DEPENDS -VFETCH_DEPENDS -VRUN_DEPENDS"
	[ -d "${PORTSDIR}/${dir}" ] && dir="/usr/ports/${dir}"

	injail make -C ${dir} $makeargs | tr '\n' ' ' | \
		sed -e "s,[[:graph:]]*/usr/ports/,,g" -e "s,:[[:graph:]]*,,g" | sort -u
}

deps_file() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local depfile=$(pkg_cache_dir ${pkg})/deps

	if [ ! -f "${depfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			pkg_info -qr "${pkg}" | awk '{ print $2 }' > "${depfile}"
		else
			pkg info -qdF "${pkg}" > "${depfile}"
		fi
	fi

	echo ${depfile}
}

pkg_get_origin() {
	[ $# -lt 1 ] && eargs pkg
	local pkg=$1
	local originfile=$(pkg_cache_dir ${pkg})/origin
	local origin=$2

	if [ ! -f "${originfile}" ]; then
		if [ -z "${origin}" ]; then
			if [ "${PKG_EXT}" = "tbz" ]; then
				origin=$(pkg_info -qo "${pkg}")
			else
				origin=$(pkg query -F "${pkg}" "%o")
			fi
		fi
		echo ${origin} > "${originfile}"
	else
		read origin < "${originfile}"
	fi
	echo ${origin}
}

pkg_get_options() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local optionsfile=$(pkg_cache_dir ${pkg})/options
	local compiled_options

	if [ ! -f "${optionsfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			compiled_options=$(pkg_info -qf "${pkg}" | awk -F: '$1 == "@comment OPTIONS" {print $2}' | tr ' ' '\n' | sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
		else
			compiled_options=$(pkg query -F "${pkg}" '%Ov %Ok' | awk '$1 == "on" {print $2}' | sort | tr '\n' ' ')
		fi
		echo "${compiled_options}" > "${optionsfile}"
		echo "${compiled_options}"
		return
	fi
	# optionsfile is multi-line, no point for read< trick here
	cat "${optionsfile}"
}

pkg_cache_data() {
	[ $# -ne 2 ] && eargs pkg origin
	# Ignore errors in here
	set +e
	local pkg=$1
	local origin=$2
	local cachedir=$(pkg_cache_dir ${pkg})
	local originfile=${cachedir}/origin

	mkdir -p $(pkg_cache_dir ${pkg})
	pkg_get_options ${pkg} > /dev/null
	pkg_get_origin ${pkg} ${origin} > /dev/null
	deps_file ${pkg} > /dev/null
	set -e
}

pkg_to_pkgname() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local pkg_file=${pkg##*/}
	local pkgname=${pkg_file%.*}
	echo ${pkgname}
}

cache_dir() {
	echo ${POUDRIERE_DATA}/cache/${JAILNAME%-job-*}/${PTNAME}
}

# Return the cache dir for the given pkg
# @param string pkg $PKGDIR/All/PKGNAME.PKG_EXT
pkg_cache_dir() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local pkg_file=${pkg##*/}

	echo $(cache_dir)/${pkg_file}
}

clear_pkg_cache() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1

	rm -fr $(pkg_cache_dir ${pkg})
}

delete_pkg() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1

	# Delete the package and the depsfile since this package is being deleted,
	# which will force it to be recreated
	rm -f "${pkg}"
	clear_pkg_cache ${pkg}
}

# Deleted cached information for stale packages (manually removed)
delete_stale_pkg_cache() {
	local pkgname
	local cachedir=$(cache_dir)
	[ ! -d ${cachedir} ] && return 0
	[ -z "$(ls -A ${cachedir})" ] && return 0
	for pkg in ${cachedir}/*.${PKG_EXT}; do
		pkg_file=${pkg##*/}
		# If this package no longer exists in the PKGDIR, delete the cache.
		if [ ! -e "${PKGDIR}/All/${pkg_file}" ]; then
			clear_pkg_cache ${pkg}
		fi
	done
}

delete_old_pkgs() {
	local o v v2 compiled_options current_options
	[ ! -d ${PKGDIR}/All ] && return 0
	[ -z "$(ls -A ${PKGDIR}/All)" ] && return 0
	for pkg in ${PKGDIR}/All/*.${PKG_EXT}; do
		# Check for non-empty directory with no packages in it
		[ "${pkg}" = "${PKGDIR}/All/*.${PKG_EXT}" ] && break
		if [ "${pkg##*/}" = "repo.txz" ]; then
			msg "Removing invalid pkg repo file: ${pkg}"
			rm -f ${pkg}
			continue
		fi

		mkdir -p $(pkg_cache_dir ${pkg})

		o=$(pkg_get_origin ${pkg})
		v=${pkg##*-}
		v=${v%.*}
		if [ ! -d "${JAILMNT}/usr/ports/${o}" ]; then
			msg "${o} does not exist anymore. Deleting stale ${pkg##*/}"
			delete_pkg ${pkg}
			continue
		fi
		v2=$(cache_get_pkgname ${o})
		v2=${v2##*-}
		if [ "$v" != "$v2" ]; then
			msg "Deleting old version: ${pkg##*/}"
			delete_pkg ${pkg}
			continue
		fi

		# Check if the compiled options match the current options from make.conf and /var/db/options
		if [ -n "${CHECK_CHANGED_OPTIONS}" -a "${CHECK_CHANGED_OPTIONS}" != "no" ]; then
			current_options=$(injail make -C /usr/ports/${o} pretty-print-config | tr ' ' '\n' | sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
			compiled_options=$(pkg_get_options ${pkg})

			if [ "${compiled_options}" != "${current_options}" ]; then
				msg "Options changed, deleting: ${pkg##*/}"
				if [ "${CHECK_CHANGED_OPTIONS}" = "verbose" ]; then
					msg "Pkg: ${compiled_options}"
					msg "New: ${current_options}"
				fi
				delete_pkg ${pkg}
				continue
			fi
		fi
	done
}

next_in_queue() {
	local p
	[ ! -d ${JAILMNT}/poudriere/pool ] && err 1 "Build pool is missing"
	p=$(lockf -k -t 60 ${JAILMNT}/.lock find ${JAILMNT}/poudriere/pool -type d -depth 1 -empty -print || : | head -n 1)
	[ -n "$p" ] || return 0
	touch ${p}/.building
	# pkgname
	echo ${p##*/}
}

cache_get_pkgname() {
	[ $# -ne 1 ] && eargs origin
	local origin=$1
	local pkgname existing_origin

	pkgname=$(awk -v o=${origin} '$1 == o { print $2 }' ${MASTERMNT:-${JAILMNT}}/poudriere/var/cache/origin-pkgname)

	# Add to cache if not found.
	if [ -z "${pkgname}" ]; then
		pkgname=$(injail make -C /usr/ports/${origin} -VPKGNAME)
		# Make sure this origin did not already exist
		existing_origin=$(cache_get_origin "${pkgname}")
		[ -n "${existing_origin}" ] &&  err 1 "Duplicated origin for ${pkgname}: ${origin} AND ${existing_origin}"
		echo "${origin} ${pkgname}" >> ${MASTERMNT:-${JAILMNT}}/poudriere/var/cache/origin-pkgname
	fi
	echo ${pkgname}
}

cache_get_origin() {
	[ $# -ne 1 ] && eargs pkgname
	local pkgname=$1

	awk -v p=${pkgname} '$2 == p { print $1 }' ${MASTERMNT:-${JAILMNT}}/poudriere/var/cache/origin-pkgname
}

# Take optional pkgname to speedup lookup
compute_deps() {
	[ $# -lt 1 ] && eargs port
	[ $# -gt 2 ] && eargs port pkgnme
	local port=$1
	local pkgname="${2:-$(cache_get_pkgname ${port})}"
	local dep_pkgname dep_port
	local pkg_pooldir="${JAILMNT}/poudriere/pool/${pkgname}"
	[ -d "${pkg_pooldir}" ] && return

	mkdir "${pkg_pooldir}"
	for dep_port in `list_deps ${port}`; do
		debug "${port} depends on ${dep_port}"
		dep_pkgname=$(cache_get_pkgname ${dep_port})
		compute_deps "${dep_port}" "${dep_pkgname}"
		touch "${pkg_pooldir}/${dep_pkgname}"
	done
}

prepare_ports() {
	msg "Calculating ports order and dependencies"
	mkdir -p "${JAILMNT}/poudriere/pool" "${JAILMNT}/poudriere/var/run" "${JAILMNT}/poudriere/var/cache"
	touch "${JAILMNT}/poudriere/var/cache/origin-pkgname"

	zset stats_queued "0"
	:> ${JAILMNT}/poudriere/ports.built
	:> ${JAILMNT}/poudriere/ports.failed
	:> ${JAILMNT}/poudriere/ports.ignored
	:> ${JAILMNT}/poudriere/ports.skipped
	build_stats

	zset status "computingdeps:"
	if [ -z "${LISTPORTS}" ]; then
		if [ -n "${LISTPKGS}" ]; then
			grep -v -E '(^[[:space:]]*#|^[[:space:]]*$)' ${LISTPKGS} | while read port; do
				compute_deps "${port}"
			done
		fi
	else
		for port in ${LISTPORTS}; do
			compute_deps "${port}"
		done
	fi
	zset status "sanity:"

	if [ $SKIPSANITY -eq 0 ]; then
		msg "Sanity checking the repository"
		delete_stale_pkg_cache
		delete_old_pkgs

		while :; do
			sanity_check_pkgs && break
		done
	fi

	msg "Deleting stale symlinks"
	find -L ${PKGDIR} -type l -exec rm -vf {} +

	zset status "cleaning:"
	msg "Cleaning the build queue"
	export LOCALBASE=${MYBASE:-/usr/local}
	find ${JAILMNT}/poudriere/pool -type d -depth 1 | while read p; do
		pn=${p##*/}
		if [ -f "${PKGDIR}/All/${pn}.${PKG_EXT}" ]; then
			rm -rf ${p}
			find ${JAILMNT}/poudriere/pool -name "${pn}" -type f -delete
		fi
	done

	local nbq=0
	nbq=$(find ${JAILMNT}/poudriere/pool -type d -depth 1 | wc -l)
	zset stats_queued "${nbq##* }"

	# Minimize PARALLEL_JOBS to queue size
	if [ ${PARALLEL_JOBS} -gt ${nbq} ]; then
		PARALLEL_JOBS=${nbq##* }
	fi
}

prepare_jail() {
	if [ -z "${NO_PACKAGE_BUILDING}" ]; then
		export PACKAGE_BUILDING=yes
	fi
	export FORCE_PACKAGE=yes
	export USER=root
	export HOME=/root
	PORTSDIR=`port_get_base ${PTNAME}`/ports
	POUDRIERED=${SCRIPTPREFIX}/../../etc/poudriere.d
	[ -z "${JAILMNT}" ] && err 1 "No path of the base of the jail defined"
	[ -z "${PORTSDIR}" ] && err 1 "No ports directory defined"
	[ -z "${PKGDIR}" ] && err 1 "No package directory defined"
	[ -n "${MFSSIZE}" -a -n "${USE_TMPFS}" ] && err 1 "You can't use both tmpfs and mdmfs"

	msg "Mounting ports filesystems for ${JAILNAME}"
	do_portbuild_mounts 1

	[ ! -d ${DISTFILES_CACHE} ] && err 1 "DISTFILES_CACHE directory	does not exists. (c.f. poudriere.conf)"

	[ -f ${POUDRIERED}/make.conf ] && cat ${POUDRIERED}/make.conf >> ${JAILMNT}/etc/make.conf
	[ -f ${POUDRIERED}/${JAILNAME}-make.conf ] && cat ${POUDRIERED}/${JAILNAME}-make.conf >> ${JAILMNT}/etc/make.conf
	if [ -z "${NO_PACKAGE_BUILDING}" ]; then
		echo "PACKAGE_BUILDING=yes" >> ${JAILMNT}/etc/make.conf
	fi

	msg "Populating LOCALBASE"
	mkdir -p ${JAILMNT}/${MYBASE:-/usr/local}
	injail /usr/sbin/mtree -q -U -f /usr/ports/Templates/BSD.local.dist -d -e -p ${MYBASE:-/usr/local} >/dev/null

	WITH_PKGNG=$(injail make -f /usr/ports/Mk/bsd.port.mk -V WITH_PKGNG)
	if [ -n "${WITH_PKGNG}" ]; then
		export PKGNG=1
		export PKG_EXT="txz"
		export PKG_ADD="${MYBASE:-/usr/local}/sbin/pkg add"
		export PKG_DELETE="${MYBASE:-/usr/local}/sbin/pkg delete -y -f"
	else
		export PKGNG=0
		export PKG_ADD=pkg_add
		export PKG_DELETE=pkg_delete
		export PKG_EXT="tbz"
	fi

	export LOGS=${POUDRIERE_DATA}/logs
}

RESOLV_CONF=""
STATUS=0 # out of jail #

test -f ${SCRIPTPREFIX}/../../etc/poudriere.conf || err 1 "Unable to find ${SCRIPTPREFIX}/../../etc/poudriere.conf"
. ${SCRIPTPREFIX}/../../etc/poudriere.conf

test -z ${ZPOOL} && err 1 "ZPOOL variable is not set"

[ -z ${BASEFS} ] && err 1 "Please provide a BASEFS variable in your poudriere.conf"

trap sig_handler SIGINT SIGTERM SIGKILL
trap exit_handler EXIT
trap siginfo_handler SIGINFO

# Test if spool exists
zpool list ${ZPOOL} >/dev/null 2>&1 || err 1 "No such zpool: ${ZPOOL}"
ZVERSION=$(zpool list -H -oversion ${ZPOOL})
# Pool version has now
if [ "${ZVERSION}" = "-" ]; then
	ZVERSION=29
fi

POUDRIERE_DATA=`get_data_dir`
: ${CRONDIR="${POUDRIERE_DATA}/cron"}
: ${SVN_HOST="svn.FreeBSD.org"}
: ${GIT_URL="git://git.freebsd.org/freebsd-ports.git"}
: ${FREEBSD_HOST="ftp://${FTP_HOST:-ftp.FreeBSD.org}"}
: ${ZROOTFS:="/poudriere"}

case ${PARALLEL_JOBS} in
''|*[!0-9]*)
	PARALLEL_JOBS=$(sysctl -n hw.ncpu)
	;;
*) ;;
esac

case ${ZROOTFS} in
	/*)
		;;
	*)
		err 1 "ZROOTFS shoud start with a /"
		;;
esac
