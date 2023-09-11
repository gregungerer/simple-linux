#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# build-m68knommu-linux-uclibc-elf.sh -- build really simple linux for m68knommu
#
# (C) Copyright 2022-2023, Greg Ungerer (gerg@kernel.org)
#
# This script carries out a simple build of an m68k based user space
# and linux for use with the ColdFire/m5208evb qemu emulated machine.
#
# This is designed to be as absolutely simple and minimal as possible.
# Only the first stage gcc is built (that is all we really need) and
# only the busybox package to provide a very basic user space.
#
# The build starts by building binutils and a first pass minimal gcc,
# then builds uClibc-ng, busybox and finally a kernel. The resulting kernel
# can be run using qemu:
#
#  qemu-system-m68k -nographic -machine mcf5208evb -kernel linux-6.5/vmlinux
#

CPU=m68k
TARGET=m68k-linux-uclibc
FLAVOR=m68knommu-elf
BOARD=m5208evb

BINUTILS_VERSION=2.41
GCC_VERSION=13.2.0
UCLIBC_NG_VERSION=1.0.44
BUSYBOX_VERSION=1.36.1
ULDSO_VERSION=1.0.4
LINUX_VERSION=6.5

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
UCLIBC_NG_URL=http://downloads.uclibc-ng.org/releases/${UCLIBC_NG_VERSION}/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
ULDSO_URL=https://github.com/gregungerer/uldso/archive/refs/tags/v${ULDSO_VERSION}.tar.gz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz

ROOTDIR=$(pwd)
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs

NCPU=32
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

	#
	# Need to get gcc to generate _all_ the multilib variants
	# (so both MMU and non-mmu M68k and ColdFire).
	#
	sed -i 's/M68K_MLIB_CPU +=/#M68K_MLIB_CPU +=/' gcc/config/m68k/t-m68k
	sed -i 's/&& (FLAGS ~ "FL_MMU")//' gcc/config/m68k/t-linux

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

	make ARCH=${CPU} defconfig
	make ARCH=${CPU} headers_install || exit 1
	cp -a usr/include ${TOOLCHAIN}/${TARGET}/
	cd ../
}

build_uClibc()
{
	echo "BUILD: building uClibc-${UCLIBC_NG_VERSION}"
	fetch_file ${UCLIBC_NG_URL}

	tar xvJf downloads/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
	cp configs/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.config uClibc-ng-${UCLIBC_NG_VERSION}/.config
	cd uClibc-ng-${UCLIBC_NG_VERSION}

	patch -p1 < ../patches/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.patch

	TOOLCHAIN_ESCAPED=$(echo ${TOOLCHAIN}/${TARGET} | sed 's/\//\\\//g')
	sed -i "s/^KERNEL_HEADERS=.*\$/KERNEL_HEADERS=\"${TOOLCHAIN_ESCAPED}\/include\"/" .config
	sed -i "s/^RUNTIME_PREFIX=.*\$/RUNTIME_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config
	sed -i "s/^DEVEL_PREFIX=.*\$/DEVEL_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config

	make oldconfig CROSS=${TARGET}- TARGET_ARCH=${CPU} < /dev/null
	make -j${NCPU} install CROSS=${TARGET}- TARGET_ARCH=${CPU} || exit 1
	ln ${TOOLCHAIN}/${TARGET}/lib/crt1.o ${TOOLCHAIN}/${TARGET}/lib/Scrt1.o
	cd ../
}

build_uldso()
{
	echo "BUILD: building uldso-${ULDSO_VERSION}"
	fetch_file ${ULDSO_URL}

	tar xvzf downloads/v${ULDSO_VERSION}.tar.gz
	cd uldso-${ULDSO_VERSION}
	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- EXTRA_CFLAGS="-mcpu=5208 -I${TOOLCHAIN}/${TARGET}/include"
	mkdir -p ${ROOTFS}/lib
	cp uld.so.1 ${ROOTFS}/lib/ld-uClibc.so.0
	cd ../
}

build_busybox()
{
	echo "BUILD: building busybox-${BUSYBOX_VERSION}"
	fetch_file ${BUSYBOX_URL}

	tar xvjf downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
	cp configs/busybox-${BUSYBOX_VERSION}.config busybox-${BUSYBOX_VERSION}/.config
	cd busybox-${BUSYBOX_VERSION}

	sed -i 's/# CONFIG_NOMMU is not set/CONFIG_NOMMU=y/' .config
	sed -i 's/# CONFIG_PIE is not set/CONFIG_PIE=y/' .config
	sed -i 's/CONFIG_EXTRA_CFLAGS=""/CONFIG_EXTRA_CFLAGS="-mcpu=5208 -fPIC"/' .config

	make oldconfig
	make -j${NCPU} CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install
	cd ../
}

build_finalize_rootfs()
{
	echo "BUILD: finalizing rootfs"

	mkdir -p ${ROOTFS}/etc
	mkdir -p ${ROOTFS}/proc
	mkdir -p ${ROOTFS}/sys

	echo "::sysinit:/etc/rc" > ${ROOTFS}/etc/inittab
	echo "::respawn:-/bin/sh" >> ${ROOTFS}/etc/inittab

	echo "#!/bin/sh" > ${ROOTFS}/etc/rc
	echo "mount -t proc proc /proc" >> ${ROOTFS}/etc/rc
	echo "mount -t sysfs sys /sys" >> ${ROOTFS}/etc/rc
	echo "echo -e \"\\nSimple Linux\\n\\n\"" >> ${ROOTFS}/etc/rc
	chmod 755 ${ROOTFS}/etc/rc

	ln -sf /sbin/init ${ROOTFS}/init
}

build_linux()
{
	echo "BUILD: building linux-${LINUX_VERSION}"

	cd linux-${LINUX_VERSION}

	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- ${BOARD}_defconfig

	sed -i "s/# CONFIG_SYSFS is not set/CONFIG_SYSFS=y/" .config
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
	rm -rf uClibc-ng-${UCLIBC_NG_VERSION}
	rm -rf uldso-${ULDSO_VERSION}
	rm -rf busybox-${BUSYBOX_VERSION}
	rm -rf ${TOOLCHAIN}
	rm -rf ${ROOTFS}
	exit 0
fi
if [ "$#" != 0 ]
then
	echo "usage: build-m68knommu-linux-uclibc-elf.sh [clean]"
	exit 1
fi

build_binutils
build_gcc
build_linux_headers
build_uClibc
build_uldso
build_busybox
build_finalize_rootfs
build_linux

exit 0
