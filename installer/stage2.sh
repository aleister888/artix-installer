#!/bin/bash -x
# shellcheck disable=SC2154

# Auto-instalador para Artix OpenRC (Parte 2)
# por aleister888 <pacoe1000@gmail.com>
# Licencia: GNU GPLv3

# Esta parte del script se ejecuta ya dentro de la instalación (chroot).

# - Pasa como variables los siguientes parámetros al siguiente script:
#   - DPI de la pantalla ($FINAL_DPI)
#   - Driver de video a usar ($GRAPHIC_DRIVER)
#   - El tipo de partición de la instalación ($ROOT_FILESYSTEM)
#   - Variables con el software opcional elegido
#     - $CHOSEN_AUDIO_PROD, $CHOSEN_LATEX, $CHOSEN_MUSIC, $CHOSEN_VIRT

pacinstall() {
	pacman -Sy --noconfirm --disable-download-timeout --needed "$@"
}

service_add() {
	rc-update add "$1" default
}

# Instalamos GRUB
install_grub() {
	local CRYPT_ID DECRYPT_ID
	CRYPT_ID=$(lsblk -nd -o UUID /dev/"$ROOT_PART_NAME")
	DECRYPT_ID=$(lsblk -n -o UUID /dev/mapper/"$CRYPT_NAME")

	# Obtenemos el nombre del dispositivo donde se aloja la partición boot
	case "$ROOT_DISK" in
	*"nvme"*)
		BOOT_DRIVE="${ROOT_DISK%p[0-9]}"
		;;
	*)
		BOOT_DRIVE="${ROOT_DISK%[0-9]}"
		;;
	esac

	# Instalar GRUB
	grub-install --target=x86_64-efi --efi-directory=/boot \
		--recheck "$BOOT_DRIVE"

	grub-install --target=x86_64-efi --efi-directory=/boot \
		--removable --recheck "$BOOT_DRIVE"

	# Si se usa encriptación, le decimos a GRUB el UUID de la partición
	# encriptada y desencriptada.
	if [ "$CRYPT_ROOT" = "true" ]; then
		echo GRUB_ENABLE_CRYPTODISK=y >>/etc/default/grub
		sed -i "s/\(^GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"/\1 cryptdevice=UUID=$CRYPT_ID:cryptroot root=UUID=$DECRYPT_ID\"/" /etc/default/grub
	fi

	# Crear el archivo de configuración
	grub-mkconfig -o /boot/grub/grub.cfg
}

# Definimos el nombre de nuestra máquina y creamos el archivo hosts
hostname_config() {
	echo "$HOSTNAME" >/etc/HOSTNAME

	# Este archivo hosts bloquea el acceso a sitios maliciosos
	curl -o /etc/hosts \
		"https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"

	cat <<-EOF | tee -a /etc/hosts
		127.0.0.1 localhost
		127.0.0.1 $HOSTNAME.localdomain $HOSTNAME
		127.0.0.1 localhost.localdomain
		127.0.0.1 local
	EOF
}

# Activar repositorios de Arch Linux
arch_support() {
	# Activar lib32
	sed -i '/#\[lib32\]/{s/^#//;n;s/^.//}' /etc/pacman.conf && pacman -Sy

	# Instalar paquetes necesarios
	pacinstall archlinux-mirrorlist archlinux-keyring artix-keyring \
		artix-archlinux-support lib32-artix-archlinux-support pacman-contrib \
		rsync lib32-elogind

	# Activar repositorios de Arch
	grep -q "^\[extra\]" /etc/pacman.conf ||
		cat <<-EOF >>/etc/pacman.conf
			[extra]
			Include = /etc/pacman.d/mirrorlist-arch

			[multilib]
			Include = /etc/pacman.d/mirrorlist-arch
		EOF

	# Actualizar cambios
	pacman -Sy --noconfirm &&
		pacman-key --populate archlinux
	pacinstall reflector

	# Escoger mirrors más rápidos de los repositorios de Arch
	reflector --verbose --fastest 10 --age 6 \
		--connection-timeout 1 --download-timeout 1 \
		--threads "$(nproc)" \
		--save /etc/pacman.d/mirrorlist-arch

	# Configurar cronie para actualizar automáticamente los mirrors de Arch
	cat <<-EOF >/etc/crontab
		SHELL=/bin/bash
		PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

		# Escoger los mejores repositorios para Arch Linux
		@hourly root ping gnu.org -c 1 && reflector --latest 10 --connection-timeout 1 --download-timeout 1 --sort rate --save /etc/pacman.d/mirrorlist-arch
	EOF
}

# Cambiar la codificación del sistema a español
genlocale() {
	sed -i -E 's/^#(en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen
	sed -i -E 's/^#(es_ES\.UTF-8 UTF-8)/\1/' /etc/locale.gen
	locale-gen
	echo "LANG=es_ES.UTF-8" >/etc/locale.conf
}

# Agrega módulos imprescindibles al initramfs
modules_add() {
	# Módulos a agregar
	local -r MODULES="vfat snd_hda_intel usb_storage btusb nvme"

	# Ruta de configuración de mkinitcpio
	local -r MKINITCPIO_CONF="/etc/mkinitcpio.conf"

	# Modificar la línea MODULES=
	for MODULE in $MODULES; do
		if ! grep -qE "MODULES=\(.*\b$MODULE\b.*\)" "$MKINITCPIO_CONF"; then
			sed -i -E \
				"s|MODULES=\(\s*\)|MODULES=( $MODULE )|; t; s|MODULES=\((.*)\)|MODULES=(\1$MODULE )|" \
				"$MKINITCPIO_CONF"
		fi
	done
}

##########
# SCRIPT #
##########

# Establecer la zona horaria
ln -sf "$SYSTEM_TIMEZONE" /etc/localtime
# Sincronizar reloj del hardware con la zona horaria
hwclock --systohc

# Configurar el servidor de claves y limpiar la cache
grep ubuntu /etc/pacman.d/gnupg/gpg.conf ||
	echo 'keyserver hkp://keyserver.ubuntu.com' |
	tee -a /etc/pacman.d/gnupg/gpg.conf >/dev/null
pacman -Sc --noconfirm
pacman-key --populate && pacman-key --refresh-keys

# Configurar pacman
sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

# Si se utiliza encriptación, añadir el módulo encrypt a la imagen del kernel
if [ "$CRYPT_ROOT" = "true" ]; then
	sed -i -e '/^HOOKS=/ s/block/& encrypt/' /etc/mkinitcpio.conf
fi

if echo "$(
	lspci
	lsusb
)" | grep -i bluetooth; then
	pacinstall bluez-openrc bluez-utils bluez-obex &&
		service_add bluetoothd
fi

# Instalamos grub
install_grub

# Regeneramos el initramfs
mkinitcpio -P

# Definimos el nombre de nuestra máquina y creamos el archivo hosts
hostname_config

# Activar repositorios de Arch Linux
arch_support

# Configurar la codificación del sistema
genlocale

# Agregamos módulos imprescindibles al initramfs
modules_add

# Activamos servicios
service_add NetworkManager
service_add cupsd
service_add cronie
service_add acpid
rc-update add device-mapper boot
rc-update add dmcrypt boot
rc-update add dmeventd boot

# Hacemos que la swap se utilize despúes de montar todos los discos
sed -i '/rc_need="localmount"/s/^#//g' /etc/conf.d/swap

ln -s /usr/bin/nvim /usr/local/bin/vim
ln -s /usr/bin/nvim /usr/local/bin/vi

# Configuramos sudo para stage3.sh
echo "root ALL=(ALL:ALL) ALL
%wheel ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers

# Ejecutamos la siguiente parte del script pasandole las variables
# correspondientes
su "$USERNAME" -c "
	export \
	FINAL_DPI=$FINAL_DPI \
	GRAPHIC_DRIVER=$GRAPHIC_DRIVER \
	ROOT_FILESYSTEM=$ROOT_FILESYSTEM \
	CHOSEN_AUDIO_PROD=$CHOSEN_AUDIO_PROD
	CHOSEN_LATEX=$CHOSEN_LATEX \
	CHOSEN_MUSIC=$CHOSEN_MUSIC \
	CHOSEN_VIRT=$CHOSEN_VIRT \

	cd /home/$USERNAME/.dotfiles/installer && ./stage3.sh
"
