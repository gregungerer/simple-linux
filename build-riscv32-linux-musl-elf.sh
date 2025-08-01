#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# build-riscv32-linux-musl-elf.sh -- build really simple linux for RISC-V
#
# (C) Copyright 2022-2025, Greg Ungerer (gerg@kernel.org)
#
# This script carries out a simple build of a RISC-V based (32-bit) user
# space and linux for use with the standard qemu emulated machine.
#
# This is designed to be as absolutely simple and minimal as possible.
# Only the first stage gcc is built (that is all we really need) and
# only the busybox package to provide a very basic user space.
#
# The build starts by building binutils and a first pass minimal gcc,
# then builds musl, busybox and finally a kernel. The resulting kernel
# can be run using qemu:
#
#	qemu-system-riscv32 \
#		-nographic \
#		-machine virt \
#		-bios opensbi/build/platform/generic/firmware/fw_dynamic.bin \
#		-kernel linux-6.16/arch/riscv/boot/Image
#

CPU=riscv
TARGET=riscv32-linux
FLAVOR=riscv32-elf
BOARD=qemu

BINUTILS_VERSION=2.44
GCC_VERSION=15.1.0
MUSL_VERSION=1.2.5
BUSYBOX_VERSION=1.37.0
LINUX_VERSION=6.16
OPENSBI_VERSION=v1.6

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
MUSL_URL=https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
OPENSBI_URL=https://github.com/riscv-software-src/opensbi.git

ROOTDIR=$(pwd)
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs

NCPU=$(grep -c processor /proc/cpuinfo 2> /dev/null)
[ -z "$NCPU" ] && NCPU=1

PATH=${TOOLCHAIN}/bin:${PATH}

fetch_file()
{
	URL=$1
	PACKAGE=$(basename ${URL})
	mkdir -p downloads
	if [ ! -f downloads/${PACKAGE} ]
	then
		echo "BUILD: fetching ${PACKAGE}"
		cd downloads
		wget ${URL}
		cd ../
	fi
}

build_binutils()
{
	echo "BUILD: building binutils-${BINUTILS_VERSION}"
	fetch_file ${BINUTILS_URL}

	tar xvJf downloads/binutils-${BINUTILS_VERSION}.tar.xz
	cd binutils-${BINUTILS_VERSION}
	./configure --target=${TARGET} --prefix=${TOOLCHAIN}
	make -j${NCPU} || exit 1
	make install || exit 1
	cd ../
}

build_gcc()
{
	echo "BUILD: building gcc-${GCC_VERSION}"
	fetch_file ${GCC_URL}

	tar xvJf downloads/gcc-${GCC_VERSION}.tar.xz
	cd gcc-${GCC_VERSION}

	contrib/download_prerequisites
	mkdir ${TARGET}
	cd ${TARGET}
	../configure --target=${TARGET} \
		--prefix=${TOOLCHAIN} \
		--enable-multilib \
		--disable-shared \
		--disable-libssp \
		--disable-threads \
		--disable-libmudflap \
		--disable-libgomp \
		--disable-libatomic \
		--disable-libsanitizer \
		--disable-libquadmath \
		--disable-libmpx \
		--without-headers \
		--with-system-zlib \
		--enable-languages=c
	make -j${NCPU} || exit 1
	make install || exit 1
	cd ../..
}

build_linux_headers()
{
	echo "BUILD: building linux-${LINUX_VERSION} headers"
	fetch_file ${LINUX_URL}

	tar xvJf downloads/linux-${LINUX_VERSION}.tar.xz
	cd linux-${LINUX_VERSION}
	make ARCH=${CPU} rv32_defconfig
	make ARCH=${CPU} headers_install || exit 1
	cp -a usr/include ${TOOLCHAIN}/${TARGET}/
	cd ../
}

build_musl()
{
	echo "BUILD: building musl-${MUSL_VERSION}"
	fetch_file ${MUSL_URL}

	tar xvzf downloads/musl-${MUSL_VERSION}.tar.gz
	cd musl-${MUSL_VERSION}

	./configure ARCH=${ARCH} CROSS_COMPILE=${TARGET}- --prefix=${TOOLCHAIN}/${TARGET}
	make -j${NCPU} || exit 1
	make install || exit 1
	cd ../
}

build_busybox()
{
	echo "BUILD: building busybox-${BUSYBOX_VERSION}"
	fetch_file ${BUSYBOX_URL}

	tar xvjf downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
	cp configs/busybox-${BUSYBOX_VERSION}.config busybox-${BUSYBOX_VERSION}/.config
	cd busybox-${BUSYBOX_VERSION}
	make oldconfig
	make -j${NCPU} CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install
	cd ../
}

build_finalize_rootfs()
{
	echo "BUILD: finalizing rootfs"

	mkdir -p ${ROOTFS}/etc
	mkdir -p ${ROOTFS}/lib
	mkdir -p ${ROOTFS}/proc
	mkdir -p ${ROOTFS}/sys

	cp musl-${MUSL_VERSION}/lib/libc.so ${ROOTFS}/lib/
	ln -sf /lib/libc.so ${ROOTFS}/lib/ld-linux-riscv32-ilp32d.so.1

	echo "::sysinit:/etc/rc" > ${ROOTFS}/etc/inittab
	echo "::respawn:-/bin/sh" >> ${ROOTFS}/etc/inittab

	echo "#!/bin/sh" > ${ROOTFS}/etc/rc
	echo "mount -t proc proc /proc" >> ${ROOTFS}/etc/rc
	echo "mount -t sysfs sys /sys" >> ${ROOTFS}/etc/rc
	echo "echo -e \"\\nSimple Linux\\n\\n\"" >> ${ROOTFS}/etc/rc
	chmod 755 ${ROOTFS}/etc/rc

	ln -sf /sbin/init ${ROOTFS}/init
}

build_opensbi()
{
	echo "BUILD: building opensbi firmware"

	git clone -b ${OPENSBI_VERSION} ${OPENSBI_URL}

	cd opensbi
	make -j${NCPU} PLATFORM=generic CROSS_COMPILE=${TARGET}- || exit 1
	cd ../
}

build_linux()
{
	echo "BUILD: building linux-${LINUX_VERSION}"

	cd linux-${LINUX_VERSION}

	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- rv32_defconfig

	sed -i "s/# CONFIG_BLK_DEV_INITRD is not set/CONFIG_BLK_DEV_INITRD=y/" .config
	sed -i "/CONFIG_INITRAMFS_SOURCE=/d" .config
	echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${ROOTDIR}/configs/rootfs.dev\"" >> .config
	echo "CONFIG_INITRAMFS_COMPRESSION_GZIP=y" >> .config

	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- olddefconfig < /dev/null
	make -j${NCPU} ARCH=${CPU} CROSS_COMPILE=${TARGET}- || exit 1

	cd ../
}


#
# Do the real work.
#

if [ "$1" = "clean" ]
then
	rm -rf binutils-${BINUTILS_VERSION}
	rm -rf gcc-${GCC_VERSION}
	rm -rf linux-${LINUX_VERSION}
	rm -rf musl-${MUSL_VERSION}
	rm -rf busybox-${BUSYBOX_VERSION}
	rm -rf opensbi
	rm -rf ${TOOLCHAIN}
	rm -rf ${ROOTFS}
	exit 0
fi
if [ "$#" != 0 ]
then
	echo "usage: build-riscv32-linux-musl-elf.sh [clean]"
	exit 1
fi

build_binutils
build_gcc
build_linux_headers
build_musl
build_busybox
build_finalize_rootfs
build_opensbi
build_linux

exit 0
