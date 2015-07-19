#!/bin/sh

apply_overlay() {
  if [ -d $ASSETSDIR/$1 ]; then
    pushd $ASSETSDIR/$1 > /dev/null
      tar cf - . | (cd $BASEDIR/system; tar xfp -)
    popd > /dev/null
  fi
}

add_new_vold() {
  apply_overlay new_vold
}

add_root_survival() {
  apply_overlay root_survival
}

move_out_image() {
  if [ -f $UNZIPPED_STOCK_ROM_DIR/$1.img ]; then
    echo "Move out stock $1.img .. "
    cp $UNZIPPED_STOCK_ROM_DIR/$1.img .
  fi
}

build_recovery_from_patch() {
  RECOVERY_DIRECTORY=$1
  SYSTEM_DIRECTORY=$2

  # Move out files
  pushd $RECOVERY_DIRECTORY > /dev/null
    tar cf - . | (cd $SYSTEM_DIRECTORY; tar xfp -)
  popd > /dev/null

  # Prepare script
  grep "applypatch -b" $RECOVERY_DIRECTORY/bin/install-recovery.sh > build_recovery_pass1
  sed -e 's/applypatch/.\/applypatch/' \
      -e 's/\/system/system/g' \
      -e 's/EMMC:\/dev\/block\/by-name\/boot.*EMMC:\/dev\/block\/by-name\/recovery/boot.img recovery.img/' \
      -e 's/OSIP:\/dev\/block\/by-name\/boot.*OSIP:\/dev\/block\/by-name\/recovery/boot.img recovery.img/' \
      -e 's/ \&\&.*//' build_recovery_pass1 > build_recovery.sh

  chmod 755 build_recovery.sh
  ./build_recovery.sh > /dev/null
 
  # Clean up
  rm build_recovery_pass*
  rm build_recovery.sh
}

link_system_files() {
  UPDATER_SCRIPT=$1
  
  cat $1 | sed 's/        /symlink("toolbox", /' > link_pass1
  grep 'symlink' link_pass1 > link_pass2
  cat link_pass2 | sed -e 's/symlink(\"/symlink /' -e 's/\", \"/ /g' -e 's/\");//' -e 's/\",//' > link.sh
  
  chmod 755 link.sh
  ./link.sh

  rm link_pass*
  rm link.sh
}

symlink() {
  SOURCE=$1
  shift
  for TARGET in "$@"
  do
    TARGET=${TARGET:1}
    XPATH=${TARGET%/*}
    XFILE=${TARGET##*/}
    
    if [ ! -d $XPATH ]; then
      mkdir -p $XPATH
    fi

    pushd $XPATH > /dev/null
      ln -s $SOURCE $XFILE
    popd > /dev/null
  done
}

# makes the function available to sub-processes
export -f symlink

source scripts/setup.bash

cd work

BASEDIR=$(pwd)

SCRIPTDIR=../scripts
ASSETSDIR=../assets
UNZIPPED_STOCK_ROM_DIR=unzipped_rom

STOCK_ROM=dl_rom.zip
STOCK_OTA=dl_ota.zip

if [ ! -d system ]; then
  # Download stock ROM
  wget -c $ROM_URL -O $STOCK_ROM
  
  # Download OTA package
  if [ -n "$OTA_URL" ]; then
    wget -c $OTA_URL -O $STOCK_OTA
  fi

  echo "Extracting stock ROM .. "
  if [ -n "$ZIP_FILE" ]; then
    unzip -q $STOCK_ROM
    unzip -q $ZIP_FILE -d $UNZIPPED_STOCK_ROM_DIR
  else
    unzip -q $STOCK_ROM -d $UNZIPPED_STOCK_ROM_DIR
  fi

  echo "Move out system directory .."
  mv $UNZIPPED_STOCK_ROM_DIR/system .
  
  move_out_image boot
  move_out_image droidboot
  move_out_image recovery

  if [ -d $UNZIPPED_STOCK_ROM_DIR/recovery ]; then
    echo "Build recovery.img .. "
    build_recovery_from_patch $UNZIPPED_STOCK_ROM_DIR/recovery $BASEDIR/system
  fi
  
  echo "Link system files .. "
  link_system_files $UNZIPPED_STOCK_ROM_DIR/META-INF/com/google/android/updater-script

  echo "Clean up .. "
  if [ -n "$ZIP_FILE" ]; then
    rm -f $ZIP_FILE
  fi
  rm -rf $UNZIPPED_STOCK_ROM_DIR

  read -p 'Press any key to build system.img .. '
fi

if [ -f $STOCK_OTA ]; then
  echo "Apply OTA patch .. "
  $SCRIPTDIR/apply_ota.sh $STOCK_OTA
fi

echo "Install SuperSU .. "
$SCRIPTDIR/install_supersu.sh

# For slim down version
if [ ! -z "$SLIM_DOWN" ]; then
  echo "Remove apps listed in exclude_apps_list .. "
  $SCRIPTDIR/exclude_apps.sh
  
  echo "Enable sdcard write permission in platform.xml .. "
  $SCRIPTDIR/enable_sdcard_write.sh
  
  echo "Install Xposed .. "
  $SCRIPTDIR/install_xposed.sh
  
  echo "Add vold with ntfs support .. "
  add_new_vold
else
  echo "Add root survival program .. "
  add_root_survival
fi

# Set the right file_context file for SELinux permission
if [ -n "$FILE_CONTEXT" ]; then
  FCOPT="-S $ASSETSDIR/$FILE_CONTEXT"
  if [ ! -z "$ROOT_SURVIVAL" ] || [ ! -z "$SLIM_DOWN" ]; then
    FCOPT="$FCOPT"_fix
  fi
fi

echo "Build system.img .. "
./make_ext4fs -s -l $SYSTEM_SIZE -a system $FCOPT system.img system

echo "Finish building $VERSION .. "
if [ ! -d $VERSION ]; then
  mkdir $VERSION
fi

mv *.img $VERSION

# ZIP and md5sum
if [ -n "$SPLIT_SIZE" ]; then
  $SCRIPTDIR/prepare_upload.sh
fi
