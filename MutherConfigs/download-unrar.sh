#!/bin/bash
torrentdir="$TR_TORRENT_DIR/$TR_TORRENT_NAME"

cd "$torrentdir" || exit 1
for archive in ./*.rar
do
    unrar e -r -o- "$archive"
done