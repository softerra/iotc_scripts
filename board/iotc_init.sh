#!/bin/sh

# RUN modes:
# - pure 'init' process, without parameters
#		For BeagleBone from uEnv.txt: cmdline=init=/opt/iotc/bin/iotc_init.sh
# - with parameters
#		- #$1 = 'test'		- test call
#		- $1 = 'local'		- switch to 'local' configuration
#		- $1 = 'production	- switch to 'production' configuration
#		- $1 = 'show'		- show current config settings
#		- * $1 is <root-dev>, $2 is <root-part-end> - called from init Raspberry Pi's init script
#			from /usr/lib/raspi-config/init_resize.sh
#			<root-dev> - rootfs device
#			<root-part-end> - last 512b sector of the rootfs
#
# When run automatically (for BBB or RPi), it assumes that iotcrafter init data (up to 512b) is placed 
# right after the last rootfs sector. The data is copied to $IOTC_DATA file.
# Then the data is taken from the file and placed to the respective configuration files:
#	- board key -> boardconfig.json
#	- wifi ssid and pass -> /etc/network/instarfaces
#	- signature	-> selects between local or production options

# Inrement the number evry time you change commit
# May be substituted by user with git revision hash
iotc_init_version=5

IOTC_SIGNATURE='iotcrafter.com'
IOTC_SIGNATURE_LOCAL='softerra.llc'
IOTC_DATA=/opt/iotc/run/iotcdata.bin
IOTC_CONNMAN=/var/lib/connman/iotcrafter_conn.config
IOTC_BOARDCONF=/opt/iotc/etc/boardconfig.json
INTERFACES=/etc/network/interfaces
CONNMAN_SERVICE=/etc/systemd/system/multi-user.target.wants/connman.service
BOARD=
# use ifup even for the system with connman
IOTC_WLAN_FORCE_IFUP=${IOTC_WLAN_FORCE_IFUP:-0}

CONF_BAK_DIR=/opt/iotc/run/conf.back
CONF_LOCAL_APT_SOURCE="http:\/\/192.168.101.103\/jenkins"
CONF_LOCAL_NODE_OTA="http:\/\/192.168.101.103\/jenkins\/"
CONF_LOCAL_SERVER="http:\/\/192.168.101.105:9000"

CONF_MODE=

INIT_OPTION=

get_board()
{
	BOARD=$(cat /proc/device-tree/model | sed "s/ /_/g" | tr -d '\000')
	echo "Board: '$BOARD', mypid=$$"
}
get_conf_mode()
{
	CONF_MODE=$([ -d "$CONF_BAK_DIR" ] && echo -n "Local" || echo -n "Production")
}

backup_item()
{
	tdir=${CONF_BAK_DIR}$(dirname $1)
	mkdir -p $tdir
	cp -Rf $1 $tdir
}

switch_config_local()
{
	if [ -d "$CONF_BAK_DIR" ]; then
		echo "$CONF_BAK_DIR dir found: seems already in local confguration mode"
		return 0
	fi

	backup_item /etc/apt/sources.list.d/iotcrafter.list
	backup_item /etc/default/iotc_updater
	backup_item /opt/iotc/etc/boardconfig.json

	sed -i 's/http.*\(\/[[:alpha:]]*\)/'$CONF_LOCAL_APT_SOURCE'\1/' /etc/apt/sources.list.d/iotcrafter.list
	sed -i 's/^SOURCE=.*$/SOURCE='${CONF_LOCAL_NODE_OTA}'/' /etc/default/iotc_updater
	sed -i 's/"server"[^"]*"[^"]*\(".*\)$/"server": "'${CONF_LOCAL_SERVER}'\1/' /opt/iotc/etc/boardconfig.json
	echo "Config switched to Local"
}

switch_config_production()
{
	if [ -d "$CONF_BAK_DIR" ]; then
		(cd $CONF_BAK_DIR;\
			cp -Rf * /;)
		rm -rf $CONF_BAK_DIR
		echo "Config switched to Production"
	fi
}

show_config()
{
	echo "Current config: ${CONF_MODE}"
	echo "iotcrafter.list: $(cat /etc/apt/sources.list.d/iotcrafter.list)"
	line=$(sed -n '/^SOURCE/ p' /etc/default/iotc_updater)
	echo "iotc_updater SOURCE: $line"
	line=$(sed -n '/"server"/ p' /opt/iotc/etc/boardconfig.json)
	echo "boardconfig.json server: $line"
}

check_commands () {
  for COMMAND in grep cut sed parted findmnt chmod tr sort head uname; do
    if ! command -v $COMMAND > /dev/null; then
      FAIL_REASON="$COMMAND not found"
      return 1
    fi
  done
  return 0
}

get_variables () {
  ROOT_PART_DEV=$(findmnt / -o source -n)
  ROOT_PART_NAME=$(echo "$ROOT_PART_DEV" | cut -d "/" -f 3)
  ROOT_DEV_NAME=$(echo /sys/block/*/"${ROOT_PART_NAME}" | cut -d "/" -f 4)
  ROOT_DEV="/dev/${ROOT_DEV_NAME}"
  ROOT_PART_NUM=$(cat "/sys/block/${ROOT_DEV_NAME}/${ROOT_PART_NAME}/partition")

  ROOT_DEV_SIZE=$(cat "/sys/block/${ROOT_DEV_NAME}/size")
  TARGET_END=$((ROOT_DEV_SIZE - 1))

  PARTITION_TABLE=$(parted -m "$ROOT_DEV" unit s print | tr -d 's')

  LAST_PART_NUM=$(echo "$PARTITION_TABLE" | tail -n 1 | cut -d ":" -f 1)

  ROOT_PART_LINE=$(echo "$PARTITION_TABLE" | grep -e "^${ROOT_PART_NUM}:")
  ROOT_PART_START=$(echo "$ROOT_PART_LINE" | cut -d ":" -f 2)
  ROOT_PART_END=$(echo "$ROOT_PART_LINE" | cut -d ":" -f 3)
}

check_variables () {
  if [ "$ROOT_PART_NUM" -ne "$LAST_PART_NUM" ]; then
    FAIL_REASON="Root partition should be last partition"
    return 1
  fi

  if [ "$ROOT_PART_END" -gt "$TARGET_END" ]; then
    FAIL_REASON="Root partition runs past the end of device"
    return 1
  fi

  if [ ! -b "$ROOT_DEV" ] || [ ! -b "$ROOT_PART_DEV" ] ; then
    FAIL_REASON="Could not determine partitions"
    return 1
  fi
}

version_ge() {
  test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" = "$1";
}

enable_sysrq()
{
	echo 1 > /proc/sys/kernel/sysrq
}

reboot_board ()
{
  sync
  echo "Rebooting.."
  sleep 3
  echo b > /proc/sysrq-trigger
  exit 0
}

read_byte()
{
	read dummy dec << EOF
$(dd bs=1 count=1 if=$1 skip=$2 2>/dev/null | od -d)
EOF
	RB_BYTE=$dec
}

# uses vars:
# - RB_FILE
# - RB_START_POS
# - RB_END_POS -- points to 
# - RB_STR
read_zstring()
{
	pos=$RB_START_POS

	while [ 1 ]; do
		read_byte $RB_FILE $pos
		if [ "$RB_BYTE" = "0" -o "$RB_BYTE" = "" ]; then
			break
		fi
		pos=$((pos + 1))
	done
	RB_END_POS=$pos
	len=$((RB_END_POS - $RB_START_POS))
	if [ $len -eq 0 ]; then
		RB_STR=""
	else
		RB_STR=$(dd bs=1 count=$len if=$RB_FILE skip=$RB_START_POS 2>/dev/null| od -c -A none -w$len | tr -d ' ')
	fi
}

# $1 - ssid
# $2 - pwd
wifi_configure_ifup()
{
	echo "configure ifup for wlan0"
	#TODO: use 'wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf'
	# and wpa_passphrase to produce psk=xxx

	if ! grep -q '^iface\s*wlan0' $INTERFACES; then
		cat >> $INTERFACES <<END

allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-ssid "$1"
    wpa-psk "$2"
END
	else
		sed -i "/^iface\s*wlan0\s*/, /^\s*\$/ {
            /^iface\s*wlan0\s*/ {
                c\
iface wlan0 inet dhcp\\
\    wpa-ssid \"$1\"\\
\    wpa-psk \"$2\"
        }
        /^\s*\$/ {p}
        /^iface\s*wlan0\s*/ !{
            d
        }
    }" $INTERFACES
	fi
}

wifi_disable_connman()
{
	echo "disable conman for wlan0"
	conf=/etc/connman/main.conf

	if ! grep -q 'NetworkInterfaceBlacklist=' $conf; then
		sed -i '/^\[General\]/ a\
NetworkInterfaceBlacklist=wlan0
' $conf
	else
		if ! grep -q 'NetworkInterfaceBlacklist=.*wlan0' $conf; then
			sed -i -r '
				s/(NetworkInterfaceBlacklist=[^[:space:]]+)$/\1,wlan0/
				s/(NetworkInterfaceBlacklist=[[:space:]]*)$/\1wlan0/' $conf
		fi
	fi

	# add masking rule to prevent wlan0 rename
	ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules
}

# $* - interface names, e.g. eth wlan
if_disable_ifup()
{
	echo "disable ifup for $*"
	for devname in $*; do
		sed -r -i '
			s/^(allow.*?'${devname}'.*?)$/#\1/
			s/^(auto.*?'${devname}'.*?)$/#\1/
			/^iface '${devname}'/,/^\s*$/ {
				s/^([^#].*?)$/#\1/
			}
		' $INTERFACES
		sed -i 's/\(^[[:space:]]*[^#[:space:]].*\)/#\1/' ./${INTERFACES}.d/${devname}* 2>/dev/null || true
	done
	echo "disable ifup for $* done"
}

# $* - interface names, e.g. eth0 eth1 via separate files in interfaces.d
if_configure_ifup()
{
	echo "configure ifup for $*"
	for devname in $*; do
		cat > ${INTERFACES}.d/$devname << EOF
allow-hotplug ${devname}
iface ${devname} inet dhcp
EOF
		chmod 644 ${INTERFACES}.d/$devname
	done

	#ensure interfaces.d is included by interfaces
	sed -i 's/^#[#[:space:]]*\(source-directory[[:space:]]*\/etc\/network\/interfaces\.d\).*$/\1/' ${INTERFACES}
	if ! grep -q '^[[:space:]]*source-directory[[:space:]]*'${INTERFACES}'.d' ${INTERFACES}; then
		echo -e "\nsource-directory ${INTERFACES}.d" >> ${INTERFACES}
	fi
	echo "configure ifup for $* done"
}

# $1 - ssid
# $2 - pwd
wifi_configure_connman()
{
	echo "configure conman for wifi"
	cat > $IOTC_CONNMAN <<EOF
[service_iotcrafter_conn]
Type=wifi
Name=$1
Passphrase=$2
IPv4=dhcp
EOF
	echo "setup wifi connman connection"
}

# $1 - key (required)
setup_key()
{
	if [ "$1" = "" ]; then
		return
	fi

	sed -i 's/"key"[^"]*"[^"]*\(".*\)$/"key": "'$1'\1/' $IOTC_BOARDCONF
	echo "iotc key set up"
}

# $1 - ssid (required)
# $2 - pwd (required)
setup_network()
{
	echo "setting up network.."
	if [ "$1" = "" -o "$2" = "" ]; then
		return
	fi

	echo -n "check connman or ifup.."
	if command -v connmand > /dev/null && [ -L $CONNMAN_SERVICE ]; then
		if [ "$IOTC_WLAN_FORCE_IFUP" = "1" ]; then
			echo "connman, forced ifup for wifi"
			# == eth controlled by connman, wlan - by ifup ==
			# works on BeagleBone (BBGW) with some issues:
			# as far as device start and wlan0 is up dhclient creates correct resolv.conf
			# but connmand then overwrites it with enpty one, so connection to iotcrafter
			# may not happen until dhclient renews resolv.conf
			wifi_configure_ifup "$1" "$2"
			wifi_disable_connman
		else
			echo "connman"
			# == eth and wlan controlled by connman ==
			# works on BeagleBone with different issues:
			# - no auto reconnect eth, wlan after connection loss
			# - sometimes fail to connect via hot plugged eth, wlan
			# - sometimes fail to connect via USB-wifi plugged before device start
			wifi_configure_connman "$1" "$2"
			if_disable_ifup eth wlan
		fi
	else	# connman is not installed or disabled and thus not used
		echo "ifup"
		# == eth and wlan controlled by ifup ==
		wifi_configure_ifup "$1" "$2"
		# disable possible default config and enable via separate files
		if_disable_ifup eth
		if_configure_ifup eth0 eth1
	fi
}

save_iotc_data()
{
	skipbs=$(($2+1))
	echo "saving iotcdata.bin from $1, offs=$skipbs"
	dd if=$1 of=$IOTC_DATA bs=512 count=1 skip=$skipbs || return $?
	# clean the data beyond the fs
	echo | dd of=$1 bs=512 count=1 seek=$skipbs conv=sync
	echo "iotcdata.bin saved (from $1, skip=$skipbs)"
}

process_iotc_data()
{
	sed -i 's/"server"[^"]*"[^"]*\(".*\)$/"server": "https:\/\/ide.iotcrafter.com\1/' $IOTC_BOARDCONF

	# read data
	RB_FILE=$IOTC_DATA
	RB_START_POS=0
	RB_BYTE=
	RB_END_POS=
	RB_STR=

	sig=
	key=
	ssid=
	pwd=

	i=0
	while [ $i -lt 5 ]; do
		read_zstring
		case "$i" in
			0)
				sig="$RB_STR"
			;;
			1)
				key="$RB_STR"
			;;
			2)
				ssid="$RB_STR"
			;;
			3)
				pwd="$RB_STR"
			;;
			4)
				INIT_OPTION="$RB_STR"
			;;
		esac
		#echo "iotcdata[$i]='$RB_STR'"
		i=$((i+1))
		if [ "$RB_BYTE" = "" ]; then
			break
		fi
		RB_START_POS=$((RB_END_POS + 1))
	done

	# Verify and use/reject
	if [ "$sig" = "$IOTC_SIGNATURE" -o "$sig" = "$IOTC_SIGNATURE_LOCAL" ]; then
		echo "iotcrafter signature found"
		setup_key $key
		setup_network "$ssid" "$pwd"
		if [ "$sig" = "$IOTC_SIGNATURE_LOCAL" ]; then
			switch_config_local
		fi
	fi
	echo "iotcrafter data processed"
}

# Extend SD-card rootfs partition (BBB)
grow_partition()
{
	echo "Resize root partition... ${ROOT_PART_DEV}"

	echo $ROOT_PART_DEV > /resizerootfs
	sync

	sed -e 's/[[:space:]]*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | /sbin/fdisk ${ROOT_DEV}
            d                   # delete partition
            n                   # re-create
            p                   # .. primary
            $ROOT_PART_NUM      # .. with number
            $ROOT_PART_START    # specify old start sector
                                # default, extend partition to the end of disk
            a                   # toogle bootable flag
            w                   # write and exit
EOF
}

# no params
init_bb()
{
	mount / -o remount,rw
	echo "remount / rw rc=$?"

	# Beagle Bone
	if [ -f /boot/uEnv.txt ]; then
		sed -i 's/ init=\/opt\/iotc\/bin\/iotc_init.sh//' /boot/uEnv.txt
		echo "removed self from uEnv.txt"
	fi
	sync

	enable_sysrq

	if ! check_commands; then
		echo $FAIL_REASON
		reboot_board
	fi

	# main
	#get_board
	get_variables

	if ! check_variables; then
		echo $FAIL_REASON
		reboot_board
	fi

	save_iotc_data "$ROOT_DEV" "$ROOT_PART_END" || ( echo "IoTC init failed, try again.." && reboot_board )
	process_iotc_data

	sync
	echo "IOTC init done."

	if [ "$INIT_OPTION" = "001" ]; then
		if [ -f /boot/uEnv.txt ]; then
			sed -i 's/^\(cmdline.*\)$/#\1/' /boot/uEnv.txt
			sed -i 's/^#\(cmdline.*init-eMMC-flasher.*\)$/\1/' /boot/uEnv.txt
			sync
			echo "==========================================================="
			echo "eMMC flasher enabled."
			echo "The board's internal flash will be re-flashed after reboot."
			echo "==========================================================="
			#cat /boot/uEnv.txt
		fi
	else
		grow_partition
	fi

	reboot_board

	return 0
}

# $1 - root_dev
# $2 - root_part_end
init_rpi()
{
	save_iotc_data "$1" "$2"
	process_iotc_data
}

# $1 - key (mandatory)
# $2 - SSID
# $3 - pwd
init_chip()
{
	setup_key $1
	setup_network "$2" "$3"
}


# START
echo "iotc_init.sh version: ${iotc_init_version}"
get_board
get_conf_mode

if [ $# -eq 0 ]; then
	# run as main script(BB, uEnv.txt: init=.../iotc_init.sh)
	if [ $$ -ne 1 ] || ! grep -q 'init=/opt/iotc/bin/iotc_init.sh' /proc/cmdline; then
		echo "Error: iotc_init.sh called as not pure init-script - params required"
		exit 1
	fi

	# BeagleBone only case
	init_bb
else
	# run as a helper(RPi, init=.../init_resize.sh -> /opt/iotc/bin/iotc_init.sh /dev/mmcblk0 123456)

	case "$1" in
		test)
			process_iotc_data
			exit 0
		;;
		local|production)
			set -e
			prev_mode=$CONF_MODE
			switch_config_$1
			get_conf_mode

			[ "$prev_mode" != "$CONF_MODE" ] && \
				echo "CONFIGURATION SWITCHED TO '$CONF_MODE'" && \
				echo "REBOOT THE BOARD IS REQUIRED!"
			exit 0
		;;
		show)
			show_config
			exit 0
		;;
	esac

	# try doing init only when N of args > 1
	if [ $# -gt 1 ]; then
		case "$BOARD" in
			"NextThing_C.H.I.P.")
				init_chip "$@"
			;;

			*)
				init_rpi "$@"
			;;
		esac
	else
		show_config
		exit 0
	fi
	echo "IOTC init done."
fi

exit 0
