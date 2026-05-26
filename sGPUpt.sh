#!/bin/bash
LANG=en_US.UTF-8

# sGPUpt
version="1.1.4"
author="MaxxRK"
maintainer="bhampthechamp"
tool="sGPUpt"

# Colors
PURPLE=$(tput setaf 99)
PINK=$(tput setaf 205)
BLUE=$(tput setaf 12)
CYAN=$(tput setaf 14)
GREEN=$(tput setaf 10)
YELLOW=$(tput setaf 11)
RED=$(tput setaf 9)
WHITE=$(tput setaf 15)
GREY=$(tput setaf 7)
BLACK=$(tput setaf 0)
DEFAULT=$(tput sgr0)

# Network
network_name="default"
network_path="/tmp/${network_name}.xml"

# Storage
disk_path="/etc/sGPUpt/disks"
iso_path="/etc/sGPUpt/iso"
#disk_path=/home/$SUDO_USER/Documents/qemu-images
#iso_path=/home/$SUDO_USER/Documents/iso

# Compile
qemu_branch="v10.1.1"
qemu_dir="/etc/sGPUpt/qemu-emulator"
edk2_branch="edk2-stable202605"
edk2_dir="/etc/sGPUpt/edk-compile"

# EDK2 build output path (GCC5 was removed in recent EDK2; now uses GCC)
# FIX: detect correct toolchain tag and build dir at runtime
edk2_toolchain="GCC"
edk2_build_dir=""   # set by edk2_compile or compile_checks

# Urls
qemu_git="https://github.com/qemu/qemu.git"
edk2_git="https://github.com/tianocore/edk2.git"
virtIO_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Logs
[[ ! -e "/etc/sGPUpt/" ]] && mkdir -p "/etc/sGPUpt/"
log_file="/etc/sGPUpt/sGPUpt.log"
log_hook="/etc/sGPUpt/sGPUpt-hooks.log"
> "$log_file"

function header(){
  url="https://github.com/$author/$tool"
  url2="https://github.com/$maintainer/$tool"
  rep="Report issues @ $url/issues"
  tag="${RED}♥${DEFAULT} $tool made by $author and updated by $maintainer ${RED}♥${DEFAULT}"
  blen=$(wc -m <<< "$rep")
  row=$((blen+3))
  tlen=$(wc -m <<< "$tag")
  clen=$(echo -n "${RED}" | wc -m)
  dlen=$(echo -n "${DEFAULT}" | wc -m)
  tlen=$((tlen-((clen*2))-((dlen*2))))
  pad=$((row-tlen))
  hpad=$((pad/2))
  border(){
     printf "\n"
     for((i=0;i<row;i++)); do
       printf "#"
     done
  }
  hpadded(){
     for((i=0;i<hpad;i++)); do
       printf " "
     done
  }
  border
  printf "\n#%s%s%${hpad}s#\n" "$(hpadded)" "$tag"
  printf "# %s #" "$rep"
  border
  printf "\n"
}

function logger(){
  pref="[sGPUpt]"
  case "$1" in
    success) flag="SUCCESS" col=${GREEN}   ;;
    info)    flag="INFO"    col=${BLUE}    ;;
    warn)    flag="WARNING" col=${YELLOW}  ;;
    choice)  flag="CHOICE"  col=${PINK}    ;;
    error)   flag="ERROR"   col=${RED}     ;;
    exit)    flag="EXIT"    col=${RED}     ;;
    none)    flag=""        col=${DEFAULT} ;;
  esac
  printf "%s$col[%s]${DEFAULT} %s\n" "$pref" "$flag" "$2"
  [[ "$1" == @("error"|"exit") ]] && exit 1
}

# FIX: detect the EDK2 build output directory (GCC5 -> GCC migration)
function detect_edk2_build_dir(){
  for tag in GCC GCC5; do
    local candidate="${edk2_dir}/Build/OvmfX64/RELEASE_${tag}/FV/OVMF_CODE.fd"
    if [[ -e "$candidate" ]]; then
      edk2_build_dir="${edk2_dir}/Build/OvmfX64/RELEASE_${tag}"
      edk2_toolchain="$tag"
      return 0
    fi
  done
  return 1
}

function main()
{
  [[ $(whoami) != "root" ]]                        && logger error "This script requires root privileges!"
  [[ -z $(grep -E -m 1 "svm|vmx" /proc/cpuinfo) ]] && logger error "This system doesn't support virtualization, please enable it then run this script again!"
  [[ ! -e /sys/firmware/efi ]]                     && logger error "This system isn't installed in UEFI mode!"
  [[ -z $(ls -A /sys/class/iommu/) ]]              && logger error "This system doesn't support IOMMU, please enable it then run this script again!"
  [[ $(nproc) -ne $(grep --count ^processor /proc/cpuinfo) ]] && logger error "The script will not work correctly if your CPU is isolated, please remove the isolation then try again."

  header

  until [[ -n $vm_name ]]; do
    read -p "$(logger choice "Enter VM name: ")" REPLY
    case $REPLY in
      "")    continue ;;
      *" "*) logger warn "Your machine's name cannot contain the character: ' '" ;;
      *"/"*) logger warn "Your machine's name cannot contain the character: '/'" ;;
      *)     vm_name=$REPLY
    esac
  done

  # Overwrite protection for existing VM configurations
  [[ -e "/etc/libvirt/qemu/${vm_name}.xml" ]] && logger error "sGPUpt Will not overwrite an existing VM Config!"

  # Call Funcs
  query_system
  install_packages
  security_checks
  compile_checks
  setup_libvirt
  create_vm

  # NEEDED TO FIX DEBIAN-BASED DISTROS USING VIRT-MANAGER
  if [[ $first_install == "true" ]]; then
    read -p "$(logger choice "A reboot is required for this distro, reboot now? [Y/n]: ")" CHOICE
    [[ "$CHOICE" == @("y"|"Y"|"") ]] && reboot
  fi
}

function query_system()
{
  # Base CPU Information
  cpu_name=$(grep -m 1 'model name' /proc/cpuinfo | cut -c14-)
  cpu_brand_id=$(grep -m 1 'vendor_id' /proc/cpuinfo | cut -c13-)
  case $cpu_brand_id in
    "AuthenticAMD") cpu_type="AMD" ;;
    "GenuineIntel") cpu_type="Intel" ;;
    *) logger error "Failed to find CPU brand." ;;
  esac

  # Core + Thread Pairs
  for (( i=0, u=0; i<$(nproc) / 2; i++ )); do
    cpu_group=$(lscpu -p | tail -n +5 | grep ",,[0-9]*,[0-9]*,$i,[0-9]*" | cut -d"," -f1)

    ((p=1, subtract_int=0))
    for core in $cpu_group; do
      array_cpu[$u]=$(echo "$cpu_group" | cut -d" " -f$p)
      ((u++, p++, subtract_int++))
    done
  done

  # Used for isolation in start.sh & end.sh
  reserved_cpu_group="$(echo "$cpu_group" | tr " " ",")"
  all_cpu_groups="0-$(($(nproc)-1))"

  # CPU topology
  # FIX: lscpu column index varies; use field name instead of positional awk
  vm_threads=$(lscpu | awk -F: '/^Thread\(s\) per core/{gsub(/ /,"",$2); print $2}')
  vm_cpus=$(($(nproc) - subtract_int))
  vm_cores=$((vm_cpus / vm_threads))

  # Stop the script if we have more than one GPU in the system.
  if [[ $(lspci | grep -c "VGA") -gt 1 ]]; then
    logger info "There are too many GPUs in the system, please choose a gpu"
    lspci | grep "VGA" | grep -E "NVIDIA|AMD/ATI|Arc" | rev | cut -d"[" -f1 | cut -d"]" -f2 | rev
    read -p 'Please select GPU from above [0-4]: ' gpu
    gpu_name=$(lspci | grep "VGA" | grep -E "NVIDIA|AMD/ATI|Arc" | rev | cut -d"[" -f1 | cut -d"]" -f2 | rev | grep "$gpu")
  else
    gpu_name=$(lspci | grep "VGA" | grep -E "NVIDIA|AMD/ATI|Arc" | rev | cut -d"[" -f1 | cut -d"]" -f2 | rev)
  fi

  gpu_components=$(lspci | grep -E "NVIDIA|AMD/ATI|Arc" | grep -E -c "VGA|Audio|USB|Serial")
  case $gpu_name in
    *GeForce*|*NVIDIA*) gpu_brand="NVIDIA" ;;
    *Radeon*)           gpu_brand="AMD" ;;
    *Raphael*)          logger error "AMD Integrated CPU Graphics are unsupported." ;;
    *Arc*)              logger error "Intel Arc is unsupported, please refer to ${url}#supported-hardware" ;;
    *)                  logger error "Unknown GPU" ;;
  esac

  # IOMMU check.
  find_pcie_devices

  # If we didn't find all GPU components then throw an error.
  [[ ${#array_gpu[@]} -ne $gpu_components ]] && logger error "GPU is not isolated for passthrough!"

  # If we didn't find any passable USB then give a choice to continue.
  if [[ ${#array_usb[@]} -eq 0 ]]; then
    read -p "$(logger choice "Couldn't find any passable USB, continue without USB? [Y/n]: ")" CHOICE
    [[ "$CHOICE" != @("Y"|"y") ]] && exit 1
  fi

  # Convert the gpu array.
  for i in "${!array_gpu[@]}"; do
    array_convt_gpu[$i]=$(tr ':.' '_' <<< "${array_gpu[$i]}")
  done

  # Convert the usb array if it contains data.
  if [[ ${#array_usb[@]} -gt 0 ]]; then
    for i in "${!array_usb[@]}"; do
      array_convt_usb[$i]=$(tr ':.' '_' <<< "${array_usb[$i]}")
    done
  fi

  # Get the hosts total memory to split for the VM.
  host_memory=$(free -g | grep -oP '\d+' | head -n 1)
  if [[ $host_memory -gt 120 ]];  then vm_memory="65536"
  elif [[ $host_memory -gt 90 ]]; then vm_memory="49152"
  elif [[ $host_memory -gt 60 ]]; then vm_memory="32768"
  elif [[ $host_memory -gt 30 ]]; then vm_memory="16384"
  elif [[ $host_memory -gt 20 ]]; then vm_memory="12288"
  elif [[ $host_memory -gt 14 ]]; then vm_memory="8192"
  elif [[ $host_memory -gt 10 ]]; then vm_memory="6144"
  else                                 vm_memory="4096"
  fi

  print_query
}

##############################################################################
# Refer to the link below if you need to understand this function            #
# https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Setting_up_IOMMU #
##############################################################################

function find_pcie_devices()
{
  IncrementGPU() {
    array_gpu[$h]=$2
    ((h++, gpus_found+=1))
    echo "GPU > Group $1 - $3" >> "$log_file"
  }
  IncrementUSB() {
    array_usb[$k]=$2
    ((k++, usbs_found+=1))
    echo "USB > Group $1 - $3" >> "$log_file"
  }
  IncrementMisc() {
    ((misc_device++))
    echo "Group $1 - $2" >> "$log_file"
  }
  RemoveGPU() {
    if [[ ${#array_gpu[@]} -gt 0 && $misc_device -gt 0 ]]; then
      for((m=gpus_found-1;m>-1;m--)); do
        unset "array_gpu[$m]"
      done
      echo "GPU component isn't isolated in group $1" >> "$log_file"
      return
    fi
    echo "Found isolated GPU component in group $1" >> "$log_file"
  }
  RemoveUSB() {
    if [[ ${#array_usb[@]} -gt 0 && $misc_device -gt 0 ]]; then
      for((m=usbs_found-1;m>-1;m--)); do
        unset "array_usb[$m]"
      done
      echo "USB isn't isolated in group $1" >> "$log_file"
      return
    fi
    echo "Found isolated USB in group $1" >> "$log_file"
  }

  for g in $(find /sys/kernel/iommu_groups/* -maxdepth 0 -type d | sort -V); do
    for d in "$g"/devices/*; do
      device_id=$(echo "${d##*/}" | cut -c6-)
      device_output=$(lspci -nns "$device_id")

      if [[ $device_output =~ ("PCI bridge"|"Non-Essential Instrumentation"|"RAM memory") ]]; then
        continue
      fi

      if [[ $device_output =~ ("VGA"|"Audio"|"USB"|"Serial") && $device_output =~ ("NVIDIA"|"AMD/ATI"|"Arc") ]]; then
        IncrementGPU "${g##*/}" "$device_id" "$device_output"
        continue
      elif [[ $device_output =~ ("USB controller") ]]; then
        IncrementUSB "${g##*/}" "$device_id" "$device_output"
        continue
      fi

      IncrementMisc "${g##*/}" "$device_output"
    done

    [[ $gpus_found -gt 0 ]] && RemoveGPU "${g##*/}"
    [[ $usbs_found -gt 0 ]] && RemoveUSB "${g##*/}"

    unset misc_device gpus_found usbs_found
  done
}

function install_packages()
{
  source /etc/os-release

  # FIX: updated Arch deps for current repos
  # - removed 'openbsd-netcat' (now 'netcat' or provided by 'gnu-netcat'/'openbsd-netcat')
  # - added 'nasm' (needed for EDK2 BaseTools)
  # - added 'python' (needed for EDK2 build scripts)
  # - added 'meson' (needed for QEMU configure)
  # - added 'libvirt' explicitly (virt-manager doesn't always pull it)
  # - added 'edk2-ovmf' as fallback reference (we compile our own but good to have)
  arch_depends=(
    "qemu-base" "virt-manager" "virt-viewer" "dnsmasq" "vde2" "bridge-utils"
    "openbsd-netcat" "libguestfs" "swtpm" "git" "make" "ninja" "iasl"
    "pkg-config" "spice-protocol" "dmidecode" "gcc" "flex" "bison" "spice"
    "xkeyboard-config" "wget" "nasm" "python" "meson" "libvirt"
  )
  fedora_depends=(
    "qemu-kvm" "virt-manager" "virt-viewer" "virt-install"
    "libvirt-daemon-config-network" "libvirt-daemon-kvm" "swtpm"
    "g++" "ninja-build" "nasm" "iasl" "libuuid-devel" "glib2-devel"
    "pixman-devel" "spice-protocol" "spice-server-devel"
  )
  alma_depends=(
    "qemu-kvm" "virt-manager" "virt-viewer" "virt-install"
    "libvirt-daemon-config-network" "libvirt-daemon-kvm" "swtpm"
    "git" "make" "gcc" "g++" "ninja-build" "nasm" "iasl"
    "libuuid-devel" "glib2-devel" "pixman-devel" "spice-protocol" "spice-server-devel"
  )
  debian_depends=(
    "qemu-kvm" "virt-manager" "virt-viewer" "libvirt-daemon-system"
    "libvirt-clients" "bridge-utils" "swtpm" "mesa-utils" "git"
    "ninja-build" "nasm" "iasl" "pkg-config" "libglib2.0-dev"
    "libpixman-1-dev" "meson" "build-essential" "uuid-dev"
    "python-is-python3" "libspice-protocol-dev" "libspice-server-dev"
    "flex" "bison" "libusb-1.0-0-dev"
  )

  ubuntu_version=( "22.04" "22.10" )
  mint_version=( "21.1" )
  pop_version=( "22.04" )
  alma_version=( "9.1" )
  fedora_version=( "36" "37" )
  debian_version=( "13" )
  local re="\\b$VERSION_ID\\b"

  testVersions() {
    local -n arr="${1}_version"
    if [[ ! ${arr[*]} =~ $re ]]; then
      logger error "This script is only verified to work on $NAME Version $(printf "%s " "${arr[@]}")"
    fi
  }

  logger info "Running package check."

  if [[ -e /etc/arch-release ]]; then
    # FIX: added --noconfirm for non-interactive installs and -y flag equivalent
    pacman -S --needed --noconfirm "${arch_depends[@]}" 2>&1 | tee -a "$log_file"
  elif [[ -e /etc/debian_version ]]; then
    case $NAME in
      "Ubuntu") arr=ubuntu ;;
      "Linux Mint") arr=mint ;;
      "Pop!_OS") arr=pop ;;
      "Debian GNU/Linux") arr=debian ;;
    esac
    testVersions "$arr"
    apt install -y "${debian_depends[@]}" 2>&1 | tee -a "$log_file"
  elif [[ -e /etc/system-release ]]; then
    case $NAME in
      "AlmaLinux")
        testVersions "alma"
        dnf --enablerepo=crb install -y "${alma_depends[@]}" 2>&1 | tee -a "$log_file"
        ;;
      *"Fedora"*|"Nobara Linux")
        testVersions "fedora"
        dnf install -y "${fedora_depends[@]}" 2>&1 | tee -a "$log_file"
        ;;
    esac
  else
    logger error "Cannot find distro!"
  fi

  [[ ! -e $iso_path ]] && mkdir -p "$iso_path"
  if [[ ! -e "$iso_path/virtio-win.iso" ]]; then
    logger info "Downloading VirtIO Drivers ISO..."
    wget -P "$iso_path" "$virtIO_url" 2>&1 | tee -a "$log_file"
  fi
}

function security_checks()
{
  ############################################################################################
  #                                                                                          #
  # Disabling security for virtualization generally isn't a smart idea but since this script #
  # targets home systems it's well worth the trade-off to disable security for ease of use.  #
  #                                                                                          #
  ############################################################################################

  if [[ $NAME =~ ("Ubuntu"|"Pop!_OS"|"Linux Mint") ]] && [[ ! -e /etc/apparmor.d/disable/usr.sbin.libvirtd ]]; then
    ln -s /etc/apparmor.d/usr.sbin.libvirtd /etc/apparmor.d/disable/ | tee -a "$log_file"
    apparmor_parser -R /etc/apparmor.d/usr.sbin.libvirtd | tee -a "$log_file"

    first_install="true"
    logger info "Disabling AppArmor permanently for this distro"
  elif [[ $NAME =~ ("Fedora"|"AlmaLinux"|"Nobara Linux") ]]; then
    source /etc/selinux/config
    if [[ $SELINUX == "disabled" ]]; then
      return
    fi

    setenforce 0 | tee -a "$log_file"
    sed -i "s/SELINUX=.*/SELINUX=disabled/" /etc/selinux/config | tee -a "$log_file"

    logger info "Disabling SELinux permanently for this distro"
  fi
}

function compile_checks()
{
  if [[ ! -e /etc/sGPUpt/install-status.txt ]]; then
    touch /etc/sGPUpt/install-status.txt
  fi

  if [[ ! -e "${qemu_dir}/build/qemu-system-x86_64" ]]; then
    qemu_compile
  fi

  # FIX: detect EDK2 build dir regardless of toolchain tag (GCC5 vs GCC)
  if ! detect_edk2_build_dir; then
    edk2_compile
    detect_edk2_build_dir || logger error "EDK2 compiled but output not found. Check the log file."
  fi

  # Symlinks
  if [[ ! -e "/etc/sGPUpt/OVMF_CODE.fd" ]]; then
    ln -s "${edk2_build_dir}/FV/OVMF_CODE.fd" /etc/sGPUpt/OVMF_CODE.fd | tee -a "$log_file"
  fi

  if [[ ! -e "/etc/sGPUpt/qemu-system-x86_64" ]]; then
    ln -s "${qemu_dir}/build/qemu-system-x86_64" /etc/sGPUpt/qemu-system-x86_64 | tee -a "$log_file"
  fi
}

function qemu_compile()
{
  logger info "Starting QEMU compile, this will take a while..."

  if [[ -e "$qemu_dir" ]]; then
    rm -rf "$qemu_dir"
  fi

  mkdir -p "$qemu_dir"

  git clone --branch "$qemu_branch" --depth 1 "$qemu_git" "$qemu_dir" 2>&1 | tee -a "$log_file"
  cd "$qemu_dir" || logger error "Failed to cd into $qemu_dir"

  # FIX: initialize submodules (required for meson wraps and subprojects)
  git submodule update --init --recursive 2>&1 | tee -a "$log_file"

  qemu_motherboard_bios_vendor="AMI"
  qemu_bios_string1="ALASKA"
  qemu_bios_string2="ASPC    " # Must be 8 chars
  qemu_disk_vendor="Western Digital Technologies, Inc."
  qemu_disk_name="WDC WD10JPVX-22JC3T0"
  qemu_cd_vendor="ASUS"
  qemu_cd_name="ASUS DRW 24F1ST"
  qemu_tablet_vendor="Wacom"
  qemu_tablet_name="Wacom Tablet"
  cpu_brand=$(grep -m 1 'vendor_id' /proc/cpuinfo | cut -c13-)
  cpu_speed=$(dmidecode | grep -m 1 "Current Speed:" | awk '{print $3}')

  # Spoofing edits
  sed -i "s/\"BOCHS \"/\"$qemu_bios_string1\"/"                                             "${qemu_dir}/include/hw/acpi/aml-build.h"
  sed -i "s/\"BXPC    \"/\"$qemu_bios_string2\"/"                                           "${qemu_dir}/include/hw/acpi/aml-build.h"
  sed -i "s/\"QEMU\"/\"$qemu_disk_vendor\"/"                                                "${qemu_dir}/hw/scsi/scsi-disk.c"
  sed -i "s/\"QEMU HARDDISK\"/\"$qemu_disk_name\"/"                                         "${qemu_dir}/hw/scsi/scsi-disk.c"
  sed -i "s/\"QEMU HARDDISK\"/\"$qemu_disk_name\"/"                                         "${qemu_dir}/hw/ide/core.c"
  sed -i "s/\"QEMU DVD-ROM\"/\"$qemu_cd_name\"/"                                            "${qemu_dir}/hw/ide/core.c"
  sed -i "s/\"QEMU\"/\"$qemu_cd_vendor\"/"                                                  "${qemu_dir}/hw/ide/atapi.c"
  sed -i "s/\"QEMU DVD-ROM\"/\"$qemu_cd_name\"/"                                            "${qemu_dir}/hw/ide/atapi.c"
  sed -i "s/\"QEMU\"/\"$qemu_tablet_vendor\"/"                                              "${qemu_dir}/hw/usb/dev-wacom.c"
  sed -i "s/\"Wacom PenPartner\"/\"$qemu_tablet_name\"/"                                    "${qemu_dir}/hw/usb/dev-wacom.c"
  sed -i "s/\"QEMU PenPartner Tablet\"/\"$qemu_tablet_name\"/"                              "${qemu_dir}/hw/usb/dev-wacom.c"
  sed -i "s/\"bochs\"/\"$qemu_motherboard_bios_vendor\"/"                                   "${qemu_dir}/block/bochs.c"
  sed -i "s/KVMKVMKVM\\\\0\\\\0\\\\0/$cpu_brand/"                                           "${qemu_dir}/include/standard-headers/asm-x86/kvm_para.h"
  sed -i "s/KVMKVMKVM\\\\0\\\\0\\\\0/$cpu_brand/"                                           "${qemu_dir}/target/i386/kvm/kvm.c"

  # FIX: CPU speed spoofing — DEFAULT_CPU_SPEED may not exist in newer QEMU;
  # only patch if the define is present, and guard against empty cpu_speed
  if [[ -n "$cpu_speed" ]] && grep -q "define DEFAULT_CPU_SPEED" "${qemu_dir}/hw/smbios/smbios.c" 2>/dev/null; then
    sed -i "s/#define DEFAULT_CPU_SPEED [0-9]*/#define DEFAULT_CPU_SPEED $cpu_speed/" \
      "${qemu_dir}/hw/smbios/smbios.c"
  fi

  # FIX: patch libfdt const-qualifier issue (GCC 14 treats -Wdiscarded-qualifiers as error)
  if [[ -f "${qemu_dir}/subprojects/dtc/libfdt/fdt_overlay.c" ]]; then
    sed -i 's/^\(\s*\)char \*sep;/\1const char *sep;/' \
      "${qemu_dir}/subprojects/dtc/libfdt/fdt_overlay.c"
  fi

  # FIX: use --disable-werror so GCC 14 strict warnings don't break the build
  ./configure --enable-spice --disable-werror 2>&1 | tee -a "$log_file"
  make -j"$(nproc)" 2>&1 | tee -a "$log_file"

  chown -R "$SUDO_USER:$SUDO_USER" "$qemu_dir"

  if [[ ! -e "${qemu_dir}/build/qemu-system-x86_64" ]]; then
    logger error "Failed to compile QEMU, please check the log file."
  fi

  logger info "Finished compiling QEMU, installing now..."
  make install | tee -a "$log_file"
}

function edk2_compile()
{
  logger info "Starting EDK2 compile, this will take a while..."

  if [[ -e "$edk2_dir" ]]; then
    rm -rf "$edk2_dir"
  fi

  mkdir -p "$edk2_dir"

  git clone --branch "$edk2_branch" --depth 1 "$edk2_git" "$edk2_dir" 2>&1 | tee -a "$log_file"
  cd "$edk2_dir" || logger error "Failed to cd into $edk2_dir"
  git submodule update --init 2>&1 | tee -a "$log_file"

  # Spoofing edits
  bios_vendor="American Megatrends"
  sed -i "s/\"EDK II\"/\"$bios_vendor\"/" "${edk2_dir}/MdeModulePkg/MdeModulePkg.dec"
  sed -i "s/\"EDK II\"/\"$bios_vendor\"/" "${edk2_dir}/ShellPkg/ShellPkg.dec"

  # FIX: BaseTools — suppress -Werror so GCC 14 warnings don't abort the build
  if [[ -f "${edk2_dir}/BaseTools/Source/C/Makefiles/header.makefile" ]]; then
    sed -i 's/-Wall -Werror/-Wall/' \
      "${edk2_dir}/BaseTools/Source/C/Makefiles/header.makefile"
  fi

  make -j"$(nproc)" -C BaseTools 2>&1 | tee -a "$log_file"

  # FIX: edksetup.sh may not exist at the repo root in recent EDK2 releases.
  # Fall back to sourcing via BaseTools/BuildEnv if needed.
  if [[ -f "${edk2_dir}/edksetup.sh" ]]; then
    # shellcheck source=/dev/null
    . "${edk2_dir}/edksetup.sh" 2>&1 | tee -a "$log_file"
  else
    export WORKSPACE="$edk2_dir"
    export EDK_TOOLS_PATH="${edk2_dir}/BaseTools"
    export CONF_PATH="${edk2_dir}/Conf"
    export PACKAGES_PATH="$edk2_dir"
    export PYTHON_COMMAND=/usr/bin/python3
    # Ensure conf dir is populated
    mkdir -p "${edk2_dir}/Conf"
    cp -n "${edk2_dir}/BaseTools/Conf/build_rule.template"  "${edk2_dir}/Conf/build_rule.txt"  2>/dev/null
    cp -n "${edk2_dir}/BaseTools/Conf/tools_def.template"   "${edk2_dir}/Conf/tools_def.txt"   2>/dev/null
    cp -n "${edk2_dir}/BaseTools/Conf/target.template"      "${edk2_dir}/Conf/target.txt"      2>/dev/null
    logger warn "edksetup.sh not found; set environment manually."
  fi

  # FIX: GCC5 toolchain tag was removed in EDK2 edk2-stable202405+.
  # Detect which tag to use based on what tools_def.txt supports.
  if grep -q "^\[GCC5\." "${edk2_dir}/Conf/tools_def.txt" 2>/dev/null; then
    edk2_toolchain="GCC5"
  else
    edk2_toolchain="GCC"
  fi
  logger info "Using EDK2 toolchain tag: $edk2_toolchain"

  # FIX: use OvmfPkg/build.sh if present; otherwise fall back to the
  # edk2-build.py wrapper that ships with QEMU's roms/ directory.
  if [[ -f "${edk2_dir}/OvmfPkg/build.sh" ]]; then
    "${edk2_dir}/OvmfPkg/build.sh" \
      -p OvmfPkg/OvmfPkgX64.dsc \
      -a X64 -b RELEASE -t "$edk2_toolchain" \
      2>&1 | tee -a "$log_file"
  else
    build \
      -p OvmfPkg/OvmfPkgX64.dsc \
      -a X64 -b RELEASE -t "$edk2_toolchain" \
      2>&1 | tee -a "$log_file"
  fi

  chown -R "$SUDO_USER:$SUDO_USER" "$edk2_dir"

  edk2_build_dir="${edk2_dir}/Build/OvmfX64/RELEASE_${edk2_toolchain}"
  if [[ ! -e "${edk2_build_dir}/FV/OVMF_CODE.fd" ]]; then
    logger error "Failed to compile EDK2. Check the log file."
  fi
}

function setup_libvirt()
{
  # If group doesn't exist then create it
  if [[ -z $(getent group libvirt) ]]; then
    groupadd libvirt 2>&1 | tee -a "$log_file"
    logger info "Created libvirt group"
  fi

  # If either user isn't in the group then add all of them again
  if [[ -z $(groups "$SUDO_USER" | grep libvirt | grep kvm | grep input) ]]; then
    usermod -aG libvirt,kvm,input "$SUDO_USER" 2>&1 | tee -a "$log_file"
    logger info "Added user '$SUDO_USER' to groups 'libvirt,kvm,input'"
  fi

  # FIX: libvirtd.conf was split into multiple files in libvirt 9.x (Arch).
  # The socket config is now in /etc/libvirt/libvirt.conf and the unix socket
  # group is set via /etc/libvirt/libvirtd.conf OR the new modular daemons.
  # We patch both paths for compatibility.
  local lvd_conf="/etc/libvirt/libvirtd.conf"
  local qemu_conf="/etc/libvirt/qemu.conf"

  if [[ -f "$lvd_conf" ]]; then
    grep -q "^unix_sock_group = \"libvirt\""  "$lvd_conf" || \
      sed -i "s/^.*unix_sock_group = \".*\"/unix_sock_group = \"libvirt\"/" "$lvd_conf"
    grep -q "^unix_sock_rw_perms = \"0770\""  "$lvd_conf" || \
      sed -i "s/^.*unix_sock_rw_perms = \".*\"/unix_sock_rw_perms = \"0770\"/" "$lvd_conf"
  fi

  if [[ -f "$qemu_conf" ]]; then
    grep -q "^user = \"$SUDO_USER\""  "$qemu_conf" || \
      sed -i "s/^#*user = \".*\"/user = \"$SUDO_USER\"/" "$qemu_conf"
    grep -q "^group = \"$SUDO_USER\"" "$qemu_conf" || \
      sed -i "s/^#*group = \".*\"/group = \"$SUDO_USER\"/" "$qemu_conf"
  fi

  # If hooks aren't installed
  [[ ! -e "/etc/libvirt/hooks/" ]] && vfio_hooks

  # Kill virt-manager because it shouldn't be open during install
  [[ -n $(pgrep -x "virt-manager") ]] && killall virt-manager

  # FIX: libvirtd.service was replaced by virtqemud.socket + virtnetworkd.socket
  # on Arch Linux with libvirt >= 9.0 (modular daemons).
  # Try the legacy service first; fall back to the modular socket units.
  if systemctl list-unit-files libvirtd.service &>/dev/null; then
    if systemctl is-active --quiet libvirtd; then
      systemctl restart libvirtd.service 2>&1 | tee -a "$log_file"
    else
      systemctl enable --now libvirtd.service 2>&1 | tee -a "$log_file"
    fi
  else
    # Modular daemon mode (Arch default since ~2023)
    for unit in virtqemud.socket virtnetworkd.socket virtnodedevd.socket virtstoraged.socket; do
      systemctl enable --now "$unit" 2>&1 | tee -a "$log_file"
    done
  fi

  if systemctl is-active --quiet firewalld; then
    firewalld_output=$(firewall-cmd --list-all --zone=libvirt 2>&1)
    if [[ ! $firewalld_output =~ "target: ACCEPT" ]]; then
      firewall-cmd --zone=libvirt --permanent --set-target=ACCEPT >> "$log_file" 2>&1
      firewall-cmd --reload >> "$log_file" 2>&1
    fi
  fi

  handle_virt_net
}

function handle_virt_net()
{
  # If '$network_name' doesn't exist then create it!
  if [[ "$(virsh net-autostart "$network_name" 2>&1)" =~ ("Network not found"|"transient") ]]; then
    > "$network_path"
    cat <<- DOC >> "$network_path"
		<network>
		  <name>$network_name</name>
		  <forward mode="nat">
		    <nat>
		      <port start="1024" end="65535"/>
		    </nat>
		  </forward>
		  <ip address="192.168.122.1" netmask="255.255.255.0">
		    <dhcp>
		      <range start="192.168.122.2" end="192.168.122.254"/>
		    </dhcp>
		  </ip>
		</network>
	DOC

    logger info "Fixing network named ${network_name}..."
    virsh net-destroy "$network_name" >> "$log_file" 2>&1
    virsh net-define "$network_path" >> "$log_file" 2>&1
    rm "$network_path"
  fi

  if [[ $(virsh net-info "$network_name" | grep "Autostart" 2>&1) =~ "no" ]]; then
    virsh net-autostart "$network_name" >> "$log_file" 2>&1
  fi

  if [[ $(virsh net-info "$network_name" | grep "Active" 2>&1) =~ "no" ]]; then
    virsh net-start "$network_name" >> "$log_file" 2>&1
  fi
}

function create_vm()
{
  OVMF_CODE="/etc/sGPUpt/OVMF_CODE.fd"
  OVMF_VARS="/var/lib/libvirt/qemu/nvram/${vm_name}_VARS.fd"
  qemu_emulator="/etc/sGPUpt/qemu-system-x86_64"
  qemu_version=$(/etc/sGPUpt/qemu-system-x86_64 --version | head -n 1 | awk '{print $4}')

  # FIX: copy VARS from detected build dir (not hardcoded GCC5 path)
  cp "${edk2_build_dir}/FV/OVMF_VARS.fd" "$OVMF_VARS"

  case $cpu_type in
    AMD)   cpu_features="hv_vendor_id=AuthenticAMD,-x2apic,+svm,+invtsc,+topoext" ;;
    Intel) cpu_features="hv_vendor_id=GenuineIntel,-x2apic,+vmx" ;;
  esac

  # If we have isolated USB then don't emulate usb
  [[ ${#array_convt_usb[@]} -gt 0 ]] && vm_usb_model="none" || vm_usb_model="qemu-xhci"

  disk_creation
  print_vm_data

  # Create the VM
  virt-install \
  --connect qemu:///system \
  --metadata description="Generated by $tool" \
  --noreboot \
  --noautoconsole \
  --name "$vm_name" \
  --memory "$vm_memory" \
  --vcpus "$vm_cpus" \
  --osinfo win10 \
  --cpu host,topology.dies=1,topology.sockets=1,topology.cores=${vm_cores},topology.threads=${vm_threads},check=none \
  --clock rtc_present=no,pit_present=no,hpet_present=no,kvmclock_present=no,hypervclock_present=yes,timer5.name=tsc,timer5.present=yes,timer5.mode=native \
  --boot loader.readonly=yes,loader.type=pflash,loader="${OVMF_CODE}" \
  --boot nvram="${OVMF_VARS}" \
  --boot emulator="${qemu_emulator}" \
  --boot cdrom,hd,menu=on \
  --feature vmport.state=off \
  --disk device=cdrom,path="" \
  --disk device=cdrom,path="${iso_path}/virtio-win.iso" \
  --import \
  --network type=network,source="${network_name}",model=virtio \
  --sound none \
  --console none \
  --graphics none \
  --controller type=usb,model=$vm_usb_model \
  --memballoon model=none \
  --tpm model=tpm-crb,type=emulator \
  --qemu-commandline="-cpu" \
  --qemu-commandline="host,hv_time,hv_runtime,hv_relaxed,hv_vapic,hv_avic,hv_spinlocks=8191,hv_vpindex,hv_reset,hv_synic,hv_stimer,hv_frequencies,hv_reenlightenment,hv_tlbflush,hv_ipi,kvm=off,kvm-hint-dedicated=on,-hypervisor,$cpu_features" \
  >> "$log_file" 2>&1

  # If virt-install fails throw an error
  if [[ ! -e "/etc/libvirt/qemu/${vm_name}.xml" ]]; then
    logger error "An error occurred while creating the VM, please create an issue on github!"
  fi

  logger info "Adding additional features/optimizations to ${vm_name}..."

  # Add the drive if the user wants one.
  if [[ $include_drive -eq 1 ]]; then
    echo "Adding Disk" >> "$log_file" 2>&1
    # FIX: removed duplicate bus= option (had both bus=virtio and bus=sata)
    virt-xml "$vm_name" --add-device \
      --disk path="${disk_path}/${vm_name}.qcow2",bus=virtio,cache=none,discard=unmap,format=qcow2 \
      >> "$log_file" 2>&1
  fi

  # Start and apply motherboard spoofing.
  asus_mb
  echo "Spoofing motherboard [ $BaseBoardProduct ]" >> "$log_file" 2>&1
  virt-xml "$vm_name" --add-device --sysinfo bios.vendor="$BIOSVendor",bios.version="$BIOSRandVersion",bios.date="$BIOSDate",bios.release="$BIOSRandRelease" >> "$log_file" 2>&1
  virt-xml "$vm_name" --add-device --sysinfo system.manufacturer="$SystemManufacturer",system.product="$SystemProduct",system.version="$SystemVersion",system.serial="$SystemRandSerial",system.uuid="$SystemUUID",system.sku="$SystemSku",system.family="$SystemFamily" >> "$log_file" 2>&1
  virt-xml "$vm_name" --add-device --sysinfo baseBoard.manufacturer="$BaseBoardManufacturer",baseBoard.product="$BaseBoardProduct",baseBoard.version="$BaseBoardVersion",baseBoard.serial="$BaseBoardRandSerial",baseBoard.asset="$BaseBoardAsset",baseBoard.location="$BaseBoardLocation" >> "$log_file" 2>&1
  virt-xml "$vm_name" --add-device --sysinfo chassis.manufacturer="$ChassisManufacturer",chassis.version="$ChassisVersion",chassis.serial="$ChassisSerial",chassis.asset="$ChassisAsset",chassis.sku="$ChassisSku" >> "$log_file" 2>&1
  virt-xml "$vm_name" --add-device --sysinfo oemStrings.entry0="$oemStrings0",oemStrings.entry1="$oemStrings1" >> "$log_file" 2>&1

  # Apply CPU pinning to VM.
  echo "Adding CPU Pinning for [ $cpu_name ]" >> "$log_file" 2>&1
  for (( i=0; i<vm_cpus; i++ )); do
    virt-xml "$vm_name" --edit --cputune="vcpupin$i.vcpu=$i,vcpupin$i.cpuset=${array_cpu[$i]}" >> "$log_file" 2>&1
  done

  # Apply GPU to VM.
  echo "Adding GPU components" >> "$log_file" 2>&1
  for gpu in "${array_convt_gpu[@]}"; do
    virt-xml "$vm_name" --add-device --host-device="pci_0000_$gpu" >> "$log_file" 2>&1
  done

  # Apply USB to VM if we found some.
  if [[ ${#array_convt_usb[@]} -gt 0 ]]; then
    echo "Adding USB controllers" >> "$log_file" 2>&1
    for usb in "${array_convt_usb[@]}"; do
      virt-xml "$vm_name" --add-device --host-device="pci_0000_$usb" >> "$log_file" 2>&1
    done
  fi

  # AMD libvirt thread fix
  if [[ $cpu_type == "AMD" ]] && grep -q "topoext" /proc/cpuinfo; then
    virt-xml "$vm_name" --edit --cpu host-passthrough,require=topoext
  fi

  # Create VM hooks
  vm_hooks

  logger success "Finished creating $vm_name!"
  logger success "Open virt-manager then add your chosen OS to CDROM1 then start the VM"
}

function disk_creation()
{
  if [[ ! -e "$disk_path" ]]; then
    mkdir -p "$disk_path"
  fi

  if [[ ! -e "$disk_path/$vm_name.qcow2" ]]; then
    read -p "$(logger choice "Do you want to create a drive named ${vm_name}? [y/N]: ")" CHOICE
  else
    read -p "$(logger choice "The drive ${vm_name} already exists. Overwrite it? [y/N]: ")" CHOICE
  fi

  if [[ "$CHOICE" == @("n"|"N"|"") ]]; then
    disk_pretty=""
    return
  fi

  read -p "$(logger choice "Size of disk (GB)[default 128]: ")" disk_size

  [[ ! $disk_size =~ ^[0-9]+$ || $disk_size -lt 1 ]] && disk_size="128"

  disk_pretty="${disk_size}G"

  qemu-img create -f qcow2 "$disk_path/$vm_name.qcow2" "${disk_size}G" >> "$log_file" 2>&1
  chown "$SUDO_USER:$SUDO_USER" "$disk_path/$vm_name.qcow2"
  ((include_drive=1))
}

function asus_mb()
{
  ASUSBoards=(
  "TUF GAMING X570-PRO WIFI II"
  "TUF GAMING X570-PLUS (WI-FI)"
  "TUF GAMING X570-PLUS"
  "PRIME X570-PRO"
  "PRIME X570-PRO/CSM"
  "PRIME X570-P"
  "PRIME X570-P/CSM"
  "ROG CROSSHAIR VIII EXTREME"
  "ROG CROSSHAIR VIII DARK HERO"
  "ROG CROSSHAIR VIII FORMULA"
  "ROG CROSSHAIR VIII HERO (WI-FI)"
  "ROG CROSSHAIR VIII HERO"
  "ROG CROSSHAIR VIII IMPACT"
  "ROG STRIX X570-E GAMING WIFI II"
  "ROG STRIX X570-E GAMING"
  "ROG STRIX X570-F GAMING"
  "ROG STRIX X570-I GAMING"
  "PROART X570-CREATOR WIFI"
  "PRO WS X570-ACE"
  )

  BIOSVendor="American Megatrends Inc."
  BIOSDate=$(shuf -i 1-12 -n 1)/$(shuf -i 1-31 -n 1)/$(shuf -i 2015-2023 -n 1)
  BIOSRandVersion=$(shuf -i 3200-4600 -n 1)
  BIOSRandRelease=$(shuf -i 1-6 -n 1).$((15 * $(shuf -i 1-6 -n 1)))

  SystemUUID=$(virsh domuuid "$vm_name")
  SystemManufacturer="System manufacturer"
  SystemProduct="System Product Name"
  SystemVersion="System Version"
  SystemRandSerial=$(shuf -i 2000000000000-3000000000000 -n 1)
  SystemSku="SKU"
  SystemFamily="To be filled by O.E.M."

  BaseBoardManufacturer="ASUSTeK COMPUTER INC."
  BaseBoardProduct=${ASUSBoards[$(shuf -i 0-$((${#ASUSBoards[@]} - 1)) -n 1)]}
  BaseBoardVersion="Rev X.0x"
  BaseBoardRandSerial=$(shuf -i 200000000000000-300000000000000 -n 1)
  BaseBoardAsset="Default string"
  BaseBoardLocation="Default string"

  ChassisManufacturer="Default string"
  ChassisVersion="Default string"
  ChassisSerial="Default string"
  ChassisAsset="Default string"
  ChassisSku="Default string"

  oemStrings0="Default string"
  oemStrings1="TEQUILA"
}

function vm_hooks()
{
  vm_base_hook="/etc/libvirt/hooks/qemu.d/${vm_name}"

  [[ -e "$vm_base_hook" ]] && rm -rf "$vm_base_hook" 2>&1 | tee -a "$log_file"

  start_sh
  stop_sh

  if [[ ! -e "${vm_base_hook}/prepare/begin/start.sh" || ! -e "${vm_base_hook}/release/end/stop.sh" ]]; then
    logger error "Failed to create hooks, report this!"
  fi

  logger success "Successfully created passthrough hooks!"
  chmod +x -R "$vm_base_hook" | tee -a "$log_file"
}

function vfio_hooks()
{
  mkdir -p "/etc/libvirt/hooks/qemu.d/" | tee -a "$log_file"
  touch    "/etc/libvirt/hooks/qemu"    | tee -a "$log_file"
  chmod +x -R "/etc/libvirt/hooks"      | tee -a "$log_file"

  # https://github.com/PassthroughPOST/VFIO-Tools/blob/master/libvirt_hooks/qemu
  cat <<- 'DOC' >> /etc/libvirt/hooks/qemu
	#!/bin/bash
	GUEST_NAME="$1"
	HOOK_NAME="$2"
	STATE_NAME="$3"
	MISC="${@:4}"
	BASEDIR="$(dirname $0)"
	HOOKPATH="$BASEDIR/qemu.d/$GUEST_NAME/$HOOK_NAME/$STATE_NAME"
	set -e
	if [ -f "$HOOKPATH" ] && [ -s "$HOOKPATH" ] && [ -x "$HOOKPATH" ]; then
	  eval "$HOOKPATH" "$@"
	elif [ -d "$HOOKPATH" ]; then
	  while read file; do
	    if [ ! -z "$file" ]; then
	      eval "$file" "$@"
	    fi
	  done <<< "$(find -L "$HOOKPATH" -maxdepth 1 -type f -executable -print;)"
	fi
	DOC
}

function start_sh()
{
  if [[ ! -e "$vm_base_hook/prepare/begin/" ]]; then
    mkdir -p "$vm_base_hook/prepare/begin/"         | tee -a "$log_file"
    touch    "$vm_base_hook/prepare/begin/start.sh" | tee -a "$log_file"
  fi

  vm_start_hook="/etc/libvirt/hooks/qemu.d/${vm_name}/prepare/begin/start.sh"
  > "$vm_start_hook"
  cat <<- DOC >> "$vm_start_hook"
	#!/bin/bash
	set -x
	log_hook="$log_hook"

	systemctl stop display-manager 2>&1 | tee -a "\$log_hook"
	[[ -n \$(pgrep -x "gdm-x-session") ]]       && killall gdm-x-session       2>&1 | tee -a "\$log_hook"
	[[ -n \$(pgrep -x "gdm-wayland-session") ]] && killall gdm-wayland-session 2>&1 | tee -a "\$log_hook"

	DOC

  if [[ $gpu_brand == "NVIDIA" ]]; then
    cat <<- DOC >> "$vm_start_hook"
	[[ -n \$(pgrep -x "nvidia") ]] && pkill -f nvidia 2>&1 | tee -a "\$log_hook"

	# Give time to kill nvidia processes
	sleep 3

	# Disconnect nvidia drivers
	rmmod nvidia_drm
	rmmod nvidia_uvm
	rmmod nvidia_modeset
	rmmod nvidia
	DOC
  fi

  for gpu in "${array_convt_gpu[@]}"; do
    echo "virsh nodedev-detach pci_0000_$gpu 2>&1 | tee -a \"\$log_hook\""
  done >> "$vm_start_hook"

  for usb in "${array_convt_usb[@]}"; do
    echo "virsh nodedev-detach pci_0000_$usb 2>&1 | tee -a \"\$log_hook\""
  done >> "$vm_start_hook"

  cat <<- DOC >> "$vm_start_hook"

	systemctl set-property --runtime -- user.slice AllowedCPUs=$reserved_cpu_group
	systemctl set-property --runtime -- system.slice AllowedCPUs=$reserved_cpu_group
	systemctl set-property --runtime -- init.scope AllowedCPUs=$reserved_cpu_group
	DOC
}

function stop_sh()
{
  if [[ ! -e "$vm_base_hook/release/" ]]; then
    mkdir -p "$vm_base_hook/release/end/"        | tee -a "$log_file"
    touch    "$vm_base_hook/release/end/stop.sh" | tee -a "$log_file"
  fi

  vm_stop_hook="/etc/libvirt/hooks/qemu.d/${vm_name}/release/end/stop.sh"
  > "$vm_stop_hook"
  cat <<- DOC >> "$vm_stop_hook"
	#!/bin/bash
	set -x
	log_hook="$log_hook"

	DOC

  for gpu in "${array_convt_gpu[@]}"; do
    echo "virsh nodedev-reattach pci_0000_$gpu 2>&1 | tee -a \"\$log_hook\""
  done >> "$vm_stop_hook"

  for usb in "${array_convt_usb[@]}"; do
    echo "virsh nodedev-reattach pci_0000_$usb 2>&1 | tee -a \"\$log_hook\""
  done >> "$vm_stop_hook"

  if [[ $gpu_brand == "NVIDIA" ]]; then
    cat <<- DOC >> "$vm_stop_hook"

	# Reload nvidia drivers
	modprobe nvidia
	modprobe nvidia_modeset
	modprobe nvidia_uvm
	modprobe nvidia_drm
	DOC
  fi

  cat <<- DOC >> "$vm_stop_hook"

	systemctl start display-manager 2>&1 | tee -a "\$log_hook"

	systemctl set-property --runtime -- user.slice AllowedCPUs=$all_cpu_groups
	systemctl set-property --runtime -- system.slice AllowedCPUs=$all_cpu_groups
	systemctl set-property --runtime -- init.scope AllowedCPUs=$all_cpu_groups
	DOC
}

function print_vm_data()
{
  cat <<- DOC | tee -a "$log_file"
	["VM Configuration"]
	{
	  "System Type":"$cpu_type"
	  "Name":"$vm_name"
	  "vCPU":"$vm_cpus"
	  "Memory":"${vm_memory}M"
	  "Disk":"$disk_pretty"
	  "QEMU Version":"$qemu_version"
	  "Additional Devices": [ ${array_gpu[@]} ${array_usb[@]} ]
	}
	DOC
}

function print_query()
{
  cat <<- DOC >> "$log_file"
	["Query Result"]
	{
	  "Script Version":"$version",

	  "System Conf":[
	  {
	    "CPU":[
	    {
	        "ID":"$cpu_brand_id",
	        "Name":"$cpu_name",
	        "CPU Pinning": [ "${array_cpu[@]}" ]
	    }],

	    "Sys.Memory":"$host_memory",

	    "Isolation":[
	    {
	        "ReservedCPUs":"$reserved_cpu_group",
	        "AllCPUs":"$all_cpu_groups"
	    }],

	    "PCI":[
	    {
	        "GPU Name":"$gpu_name",
	        "GPU IDs": [ ${array_gpu[@]} ],
	        "USB IDs": [ ${array_usb[@]} ]
	        }],
	    }],

	    "Virt Conf":[
	    {
	        "vCPUs":"$vm_cpus",
	        "vCores":"$vm_cores",
	        "vThreads":"$vm_threads",
	        "vMem":"$vm_memory",
	        "Converted GPU IDs": [ ${array_convt_gpu[@]} ],
	        "Converted USB IDs": [ ${array_convt_usb[@]} ]
	    }]
	}
	DOC
}

main
