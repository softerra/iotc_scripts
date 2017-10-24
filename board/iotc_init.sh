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
# When run atumatically (for BBB or RPi), it assumes that iotcrafter init data (up to 512b) is placed 
# right after the last rootfs sector. The data is copied to $OPROG_DATA file.
# Then the data is taken from the file and placed to the respective configuration files:
#	- board key -> boardconfig.json
#	- wifi ssid and pass -> /etc/network/instarfaces
#	- signature	-> selects between local or production options

iotc_init_version=1

OPROG_SIGNATURE='iotcrafter.com'
OPROG_SIGNATURE_LOCAL='softerra.llc'
OPROG_DATA=/opt/iotc/run/iotcdata.bin
OPROG_CONNMAN=/opt/iotc/run/iotc.connman
OPROG_BOARDCONF=/opt/iotc/etc/boardconfig.json
INTERFACES=/etc/network/interfaces
BOARD=
# use ifup even for the system with connman
OPROG_WLAN_FORCE_IFUP=1

CONF_BAK_DIR=/opt/iotc/run/conf.back
CONF_LOCAL_APT_SOURCE="http:\/\/192.168.101.103\/iotc"
CONF_LOCAL_NODE_OTA="http:\/\/192.168.101.103\/iotc-ota\/"
CONF_LOCAL_SERVER="http:\/\/192.168.101.105:9000"

CONF_MODE=

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

bb_oprog_timer_deb_postinst ()
{
  BASEVERS=4.1
  # BeagleBone stuff
    # Disable HDMI
    BBBFILE=/boot/uEnv.txt
    if [ "$BOARD" = "TI_AM335x_BeagleBone_Black" ]; then
      sed -i -e '/emmc-overlay.dtb/s/#//' $BBBFILE
    fi
    # Make loading kernel overlays on boot
    CAPEFILE=/etc/default/capemgr
    KERNVERS=`uname -r` # get kernel version
    if version_ge $KERNVERS $BASEVERS; then
      sed -i -e '/CAPE=$/s/=/=BB-ADC,am33xx_pwm,BB-PWM0,BB-PWM1,BB-PWM2,BB-W1-P8.19/' $CAPEFILE
    else
      # unexport GPIOs for old .img
      sed -i -e '/^cmdline.*cape_universal/s/quiet /quiet\n#/' $BBBFILE
      sed -i -e '/CAPE=$/s/=/=BB-ADC,BB-PWM,BB-W1-P8.19/' $CAPEFILE
    fi
}

enable_sysrq()
{
	echo 1 > /proc/sys/kernel/sysrq
}

reboot_board ()
{
  sync
  echo "Rebooting.."
#  sleep 5
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
	#TODO: use 'wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf'
	# and wpa_passphrase to produce psk=xxx

	if ! grep -q '^iface\s*wlan0' $INTERFACES; then
		echo "" >> $INTERFACES
		echo "allow-hotplug wlan0" >> $INTERFACES
		echo "iface wlan0 inet dhcp" >> $INTERFACES
		echo "    wpa-ssid \"$1\"" >> $INTERFACES
		echo "    wpa-psk \"$2\"" >> $INTERFACES
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

# $1 - ssid
# $2 - pwd
wifi_configure_connman()
{
	echo "WLAN_SSID='$1'" > $OPROG_CONNMAN
	echo "WLAN_PWD='$2'" >> $OPROG_CONNMAN
	echo "wifi credentials saved for connman"
}

# $1 - key (required)
setup_key()
{
	if [ "$1" = "" ]; then
		return
	fi

	sed -i 's/"key"[^"]*"[^"]*\(".*\)$/"key": "'$1'\1/' $OPROG_BOARDCONF
	echo "iotc key set up"
}

# $1 - ssid (required)
# $2 - pwd (required)
setup_network()
{
	if [ "$1" = "" -o "$2" = "" ]; then
		return
	fi

	if command -v connmand > /dev/null; then
		if [ "$OPROG_WLAN_FORCE_IFUP" = "1" ]; then
			wifi_configure_ifup "$1" "$2"
			wifi_disable_connman
		else
			wifi_configure_connman "$1" "$2"
		fi
	else
		wifi_configure_ifup "$1" "$2"
	fi
}

save_oprog_data()
{
	skipbs=$(($2+1)); dd if=$1 of=$OPROG_DATA bs=512 count=1 skip=$skipbs
	echo "iotcdata.bin saved"
}

process_oprog_data()
{
	sed -i 's/"server"[^"]*"[^"]*\(".*\)$/"server": "https:\/\/ide.iotcrafter.com\1/' $OPROG_BOARDCONF

	# read data
	RB_FILE=$OPROG_DATA
	RB_START_POS=0
	RB_BYTE=
	RB_END_POS=
	RB_STR=

	sig=
	key=
	ssid=
	pwd=

	i=0
	while [ $i -lt 4 ]; do
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
		esac
		i=$((i+1))
		if [ "$RB_BYTE" = "" ]; then
			break
		fi
		RB_START_POS=$((RB_END_POS + 1))
	done

	# Verify and use/reject
	if [ "$sig" = "$OPROG_SIGNATURE" -o "$sig" = "$OPROG_SIGNATURE_LOCAL" ]; then
		echo "iotcrafter signature found"
		setup_key $key
		setup_network "$ssid" "$pwd"
		if [ "$sig" = "$OPROG_SIGNATURE_LOCAL" ]; then
			switch_config_local
		fi
	fi
	echo "iotcrafter data processed"
}

# no params
init_bb ()
{
	mount / -o remount,rw
	echo "remount / rw rc=$?"

	# Beagle Bone
	if [ -f /boot/uEnv.txt ]; then
		sed -i 's/ init=\/opt\/iotc\/bin\/iotc_init.sh//' /boot/uEnv.txt
		echo "removed self from uEnv.txt"
	fi
	chmod -x /opt/iotc/bin/iotc_init.sh
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

	save_oprog_data "$ROOT_DEV" "$ROOT_PART_END"
	process_oprog_data

	if echo "$BOARD" | grep -qE '(Beagle|Pocket)Bone'; then
		bb_oprog_timer_deb_postinst
	fi

	sync
	echo "IOTC init done."
	reboot_board

	return 0
}

# $1 - root_dev
# $2 - root_part_end
init_rpi()
{
	save_oprog_data "$1" "$2"
	process_oprog_data
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
			process_oprog_data
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

	case "$BOARD" in
		"NextThing_C.H.I.P.")
			init_chip "$@"
		;;

		*)
			init_rpi "$@"
		;;
	esac
	echo "IOTC init done."
fi

exit 0
